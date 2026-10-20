import AppKit
import FlickCore

/// Custom NSPrintInfo dictionary keys for the image-print options shown in
/// the panel's "Flick" accessory section. They're read back by ImagePrintView
/// at draw time, so changes apply to both preview and the printed output.
enum PrintSettingKey {
    static let autoRotate = "FlickAutoRotate" as NSString
    static let scaleMode = "FlickScaleMode" as NSString
    static let scalePercent = "FlickScalePercent" as NSString
    static let copiesPerPage = "FlickCopiesPerPage" as NSString
}

/// How the image is sized on the page. Raw values are stored in the print
/// info dictionary.
enum PrintScaleMode: Int {
    case percent = 0     // scale % of the image's natural size
    case fit = 1         // aspect-fit inside the cell ("Print Entire Image")
    case fill = 2        // aspect-fill the cell ("Fill Entire Paper")
}

/// Single-page print renderer. The panel drives pagination through
/// knowsPageRange/rectForPage, and draw() reads the option dictionary so the
/// built-in preview and the real output stay identical.
final class ImagePrintView: NSView {
    let image: NSImage

    init(image: NSImage) {
        self.image = image
        // Frame just needs to cover any paper's printable area; rectForPage
        // returns the real page rect per paper size/orientation change.
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: 4000, height: 4000)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: 1)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        NSPrintOperation.current?.printInfo.imageablePageBounds ?? bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let info = NSPrintOperation.current?.printInfo else { return }
        let dict = info.printSettings
        let autoRotate = (dict.object(forKey: PrintSettingKey.autoRotate) as? Bool) ?? true
        let mode = PrintScaleMode(rawValue: (dict.object(forKey: PrintSettingKey.scaleMode) as? Int) ?? 1) ?? .fit
        let percent = (dict.object(forKey: PrintSettingKey.scalePercent) as? Double) ?? 100
        let copies = max(1, (dict.object(forKey: PrintSettingKey.copiesPerPage) as? Int) ?? 1)

        let page = rectForPage(1)
        NSColor.white.setFill()
        page.fill()

        for cell in gridCells(count: copies, in: page) {
            drawImage(in: cell, autoRotate: autoRotate, mode: mode, percent: percent)
        }
    }

    /// Splits the page into cells that maximize cell area for `count` copies.
    private func gridCells(count: Int, in page: NSRect) -> [NSRect] {
        guard count > 1 else { return [page] }
        // Pick the column count that yields the largest cells for this page's
        // aspect ratio (e.g. 2 copies stack vertically on a portrait page).
        var bestCols = 1, bestArea: CGFloat = 0
        for cols in 1...count {
            let rows = Int(ceil(Double(count) / Double(cols)))
            let area = (page.width / CGFloat(cols)) * (page.height / CGFloat(rows))
            if area > bestArea { bestArea = area; bestCols = cols }
        }
        let rows = Int(ceil(Double(count) / Double(bestCols)))
        let w = page.width / CGFloat(bestCols), h = page.height / CGFloat(rows)
        return (0..<count).map { i in
            NSRect(x: page.minX + CGFloat(i % bestCols) * w,
                   y: page.maxY - CGFloat(i / bestCols + 1) * h,
                   width: w, height: h)
        }
    }

    private func drawImage(in cell: NSRect, autoRotate: Bool, mode: PrintScaleMode, percent: Double) {
        // Preview-style auto-rotate: turn the image 90° when its orientation
        // opposes the cell's so it fills more of the space.
        let img = autoRotate
            && (image.size.width > image.size.height) != (cell.width > cell.height)
            ? image.rotated90() : image
        let iw = img.size.width, ih = img.size.height
        let destSize: NSSize
        switch mode {
        case .percent:
            destSize = NSSize(width: iw * percent / 100, height: ih * percent / 100)
        case .fit:
            let s = min(cell.width / iw, cell.height / ih)
            destSize = NSSize(width: iw * s, height: ih * s)
        case .fill:
            let s = max(cell.width / iw, cell.height / ih)
            destSize = NSSize(width: iw * s, height: ih * s)
        }
        let dest = NSRect(x: cell.midX - destSize.width / 2,
                          y: cell.midY - destSize.height / 2,
                          width: destSize.width, height: destSize.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSBezierPath(rect: cell).addClip() // fill/percent modes can overflow
        img.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Accessory controller supplying the "Flick" section of the print panel —
/// the same controls Preview.app exposes: Auto Rotate, Scale %, Scale to Fit
/// (Print Entire Image / Fill Entire Paper), and Copies per page. Settings
/// live in the print info's dictionary, which the panel hands us as
/// representedObject.
final class PrintAccessoryController: NSViewController, NSPrintPanelAccessorizing {

    // KVO-visible so the panel refreshes its built-in preview on changes.
    @objc dynamic var autoRotate = true { didSet { store(PrintSettingKey.autoRotate, autoRotate) } }
    @objc dynamic var scaleMode = PrintScaleMode.fit.rawValue { didSet { store(PrintSettingKey.scaleMode, scaleMode) } }
    @objc dynamic var scalePercent = 100.0 { didSet { store(PrintSettingKey.scalePercent, scalePercent) } }
    @objc dynamic var copiesPerPage = 1 { didSet { store(PrintSettingKey.copiesPerPage, copiesPerPage) } }

    private var printInfo: NSPrintInfo? { representedObject as? NSPrintInfo }

    private var autoRotateButton: NSButton!
    private var scaleRadio: NSButton!
    private var percentField: NSTextField!
    private var fitRadio: NSButton!
    private var entireRadio: NSButton!
    private var fillRadio: NSButton!
    private var copiesPopup: NSPopUpButton!

    private func store(_ key: NSString, _ value: Any) {
        printInfo?.printSettings.setObject(value, forKey: key)
    }

    override var representedObject: Any? {
        didSet {
            guard let dict = printInfo?.printSettings else { return }
            // Restore previously chosen values (e.g. panel re-opened).
            if let v = dict.object(forKey: PrintSettingKey.autoRotate) as? Bool { autoRotate = v }
            if let v = dict.object(forKey: PrintSettingKey.scaleMode) as? Int { scaleMode = v }
            if let v = dict.object(forKey: PrintSettingKey.scalePercent) as? Double { scalePercent = v }
            if let v = dict.object(forKey: PrintSettingKey.copiesPerPage) as? Int { copiesPerPage = v }
            if isViewLoaded { syncControls() }
        }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 148))

        autoRotateButton = NSButton(checkboxWithTitle: L10n.s("Auto Rotate", "自动旋转"),
                                    target: self, action: #selector(toggleAutoRotate))
        autoRotateButton.frame = NSRect(x: 16, y: 122, width: 220, height: 20)

        scaleRadio = NSButton(radioButtonWithTitle: L10n.s("Scale:", "缩放："),
                              target: self, action: #selector(chooseScalePercent))
        scaleRadio.frame = NSRect(x: 16, y: 94, width: 100, height: 20)
        percentField = NSTextField(frame: NSRect(x: 118, y: 94, width: 54, height: 21))
        percentField.target = self
        percentField.action = #selector(percentChanged)
        percentField.formatter = percentFormatter()
        let percentLabel = label("%", frame: NSRect(x: 176, y: 96, width: 20, height: 17))

        fitRadio = NSButton(radioButtonWithTitle: L10n.s("Scale to Fit:", "适应纸张："),
                            target: self, action: #selector(chooseFit))
        fitRadio.frame = NSRect(x: 16, y: 66, width: 116, height: 20)
        entireRadio = NSButton(radioButtonWithTitle: L10n.s("Print Entire Image", "打印完整图像"),
                               target: self, action: #selector(chooseEntire))
        entireRadio.frame = NSRect(x: 250, y: 68, width: 200, height: 18)
        fillRadio = NSButton(radioButtonWithTitle: L10n.s("Fill Entire Paper", "填满整张纸"),
                             target: self, action: #selector(chooseFill))
        fillRadio.frame = NSRect(x: 250, y: 48, width: 200, height: 18)

        let copiesLabel = label(L10n.s("Copies per page:", "每页份数："),
                                frame: NSRect(x: 16, y: 18, width: 130, height: 17),
                                alignment: .left)
        copiesPopup = NSPopUpButton(frame: NSRect(x: 140, y: 14, width: 76, height: 24), pullsDown: false)
        copiesPopup.addItems(withTitles: ["1", "2", "4", "6", "9", "16"])
        copiesPopup.target = self
        copiesPopup.action = #selector(copiesChanged)

        for v in [autoRotateButton!, scaleRadio!, percentField!, percentLabel, fitRadio!,
                  entireRadio!, fillRadio!, copiesLabel, copiesPopup!] {
            root.addSubview(v)
        }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let dict = printInfo?.printSettings {
            // Seeded by the print call site once per operation.
            if let v = dict.object(forKey: PrintSettingKey.autoRotate) as? Bool { autoRotate = v }
            if let v = dict.object(forKey: PrintSettingKey.scaleMode) as? Int { scaleMode = v }
            if let v = dict.object(forKey: PrintSettingKey.scalePercent) as? Double { scalePercent = v }
            if let v = dict.object(forKey: PrintSettingKey.copiesPerPage) as? Int { copiesPerPage = v }
        }
        syncControls()
    }

    private func label(_ text: String, frame: NSRect, alignment: NSTextAlignment = .right) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.frame = frame
        f.alignment = alignment
        f.font = .systemFont(ofSize: NSFont.systemFontSize)
        return f
    }

    private func percentFormatter() -> NumberFormatter {
        let fmt = NumberFormatter()
        fmt.minimum = 1
        fmt.maximum = 10000
        return fmt
    }

    private func syncControls() {
        autoRotateButton.state = autoRotate ? .on : .off
        scaleRadio.state = scaleMode == PrintScaleMode.percent.rawValue ? .on : .off
        fitRadio.state = scaleMode != PrintScaleMode.percent.rawValue ? .on : .off
        entireRadio.state = scaleMode == PrintScaleMode.fit.rawValue ? .on : .off
        fillRadio.state = scaleMode == PrintScaleMode.fill.rawValue ? .on : .off
        percentField.stringValue = "\(Int(scalePercent))"
        percentField.isEnabled = scaleMode == PrintScaleMode.percent.rawValue
        entireRadio.isEnabled = scaleMode != PrintScaleMode.percent.rawValue
        fillRadio.isEnabled = scaleMode != PrintScaleMode.percent.rawValue
        copiesPopup.selectItem(withTitle: "\(copiesPerPage)")
    }

    @objc private func toggleAutoRotate(_ sender: NSButton) {
        autoRotate = sender.state == .on
        syncControls()
    }

    @objc private func chooseScalePercent(_ sender: NSButton) {
        scaleMode = PrintScaleMode.percent.rawValue
        if let v = percentFormatter().number(from: percentField.stringValue)?.doubleValue {
            scalePercent = v
        }
        syncControls()
    }

    @objc private func percentChanged(_ sender: NSTextField) {
        if let v = percentFormatter().number(from: sender.stringValue)?.doubleValue {
            scalePercent = v
            scaleMode = PrintScaleMode.percent.rawValue // editing implies percent mode
        }
        syncControls()
    }

    @objc private func chooseFit(_ sender: NSButton) {
        scaleMode = PrintScaleMode.fit.rawValue
        syncControls()
    }

    @objc private func chooseEntire(_ sender: NSButton) {
        scaleMode = PrintScaleMode.fit.rawValue
        syncControls()
    }

    @objc private func chooseFill(_ sender: NSButton) {
        scaleMode = PrintScaleMode.fill.rawValue
        syncControls()
    }

    @objc private func copiesChanged(_ sender: NSPopUpButton) {
        copiesPerPage = Int(sender.titleOfSelectedItem ?? "1") ?? 1
        syncControls()
    }

    // MARK: - NSPrintPanelAccessorizing

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        let scaleDesc: String
        switch PrintScaleMode(rawValue: scaleMode) {
        case .percent?: scaleDesc = "\(Int(scalePercent))%"
        case .fit?: scaleDesc = L10n.s("Print Entire Image", "打印完整图像")
        case .fill?, nil: scaleDesc = L10n.s("Fill Entire Paper", "填满整张纸")
        }
        return [
            [.itemName: L10n.s("Auto Rotate", "自动旋转"),
             .itemDescription: autoRotate ? L10n.s("On", "开") : L10n.s("Off", "关")],
            [.itemName: L10n.s("Scale", "缩放"), .itemDescription: scaleDesc],
            [.itemName: L10n.s("Copies per page", "每页份数"),
             .itemDescription: "\(copiesPerPage)"],
        ]
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> {
        ["autoRotate", "scaleMode", "scalePercent", "copiesPerPage"]
    }
}
