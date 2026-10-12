import AppKit
import FlickCore

protocol ImageViewActionDelegate: AnyObject {
    func imageViewDidRequestNext(_ view: ImageView)
    func imageViewDidRequestPrevious(_ view: ImageView)
    func imageViewDidRequestFirst(_ view: ImageView)
    func imageViewDidRequestLast(_ view: ImageView)
    func imageViewDidRequestToggleFullScreen(_ view: ImageView)
    func imageViewDidRequestExitFullScreen(_ view: ImageView)
    func imageViewCanTurn(_ view: ImageView, direction: SwipeTracker.Direction) -> Bool
    func imageViewDidRequestSwipeTurn(_ view: ImageView, direction: SwipeTracker.Direction)
    func imageView(_ view: ImageView, didReceiveDroppedURLs urls: [URL])
}

/// Toolbar button tags. Kept stable so the controller can swap icons/state.
private enum ChromeTag {
    static let rotateLeft = 1
    static let rotateRight = 2
    static let fit = 3
    static let actual = 4
    static let playback = 5
    static let zoomOut = 10
    static let zoomIn = 11
    static let prev = 12
    static let next = 13
    static let open = 14
    static let filmstrip = 15
    static let info = 16
    static let fullScreen = 17
}

/// The window's content: an `ImageScrollView` canvas plus a loading spinner,
/// a centered message label (empty state / errors) and Pixea-style floating
/// chrome — titlebar breadcrumb, top tool capsule, bottom control capsule,
/// bottom-left status strip and a floating filmstrip. Chrome is hidden while
/// idle; any mouse movement reveals it briefly, hovering inside a chrome
/// region pins it, and fullscreen hides it together with the cursor.
final class ImageView: NSView {
    weak var actionDelegate: ImageViewActionDelegate?

    let scrollView = ImageScrollView()

    /// Action hooks for chrome buttons; wired by the controller.
    var onOpen: (() -> Void)?
    var onRotate: ((Int) -> Void)?             // quarter-turns delta
    var onToggleInfoPanel: (() -> Void)?
    var onToggleFilmstrip: (() -> Void)?
    var onTogglePlayback: (() -> Void)?
    var onFilmstripSelect: ((Int) -> Void)?
    /// Called whenever magnification changes — the controller uses it to
    /// decide whether a higher-resolution decode is needed.
    var onZoomChanged: (() -> Void)?

    private let spinner: NSProgressIndicator = {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .large
        indicator.isDisplayedWhenStopped = false
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

    private let messageLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 15)
        label.textColor = .secondaryLabelColor
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let infoPanel = InfoPanelView()
    private let infoPanelWidth: CGFloat = 260
    private let filmstrip = FilmstripView()
    private(set) var infoPanelVisible = false

    /// Filmstrip preference (persisted): ON = hovering the bottom edge
    /// floats the strip; OFF = it never appears (saves decode work).
    private(set) var filmstripEnabled = false
    private var filmstripTransient = false
    private var filmstripHasContent = false
    /// Delays hiding the strip after the pointer leaves the bottom zone —
    /// instant dismissal felt twitchy when the mouse overshot by a pixel.
    private var filmstripHideWorkItem: DispatchWorkItem?

    // Chrome: floating capsules + breadcrumb + status strip. IUO because the
    /// button target is `self`, which only exists after super.init.
    private let titleCapsule = TitleCapsule()
    private var topToolbar: ToolbarCapsule!
    private var bottomBar: ToolbarCapsule!
    private let statusStrip = StatusStrip()
    private var chromeVisible = false
    private var chromeHideWorkItem: DispatchWorkItem?
    private var lastMousePoint: NSPoint?

    private var statusZoomText = ""
    private var statusItems: [String] = []

    private var mouseTrackingArea: NSTrackingArea?
    private var isFullScreen = false
    private var cursorIsHidden = false
    private var cursorHideWorkItem: DispatchWorkItem?
    private var animator: PageTurnAnimator?
    /// True while the placeholder message is showing (no image loaded).
    private(set) var showsPlaceholder = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        topToolbar = ToolbarCapsule(items: [
            .init(tag: ChromeTag.rotateLeft, symbols: ["rotate.left"],
                  fallbackTitle: "左转", toolTip: "逆时针旋转", action: #selector(chromeRotateLeft)),
            .init(tag: ChromeTag.rotateRight, symbols: ["rotate.right"],
                  fallbackTitle: "右转", toolTip: "顺时针旋转", action: #selector(chromeRotateRight)),
            .init(tag: ChromeTag.fit, symbols: ["aspectratio"],
                  fallbackTitle: "适应", toolTip: "适应窗口", action: #selector(chromeFit)),
            .init(tag: ChromeTag.actual, symbols: ["1.magnifyingglass"],
                  fallbackTitle: "1x", toolTip: "实际大小", action: #selector(chromeActual)),
            .init(tag: ChromeTag.playback, symbols: ["pause.fill"],
                  fallbackTitle: "停", toolTip: "暂停动画", action: #selector(chromePlayback),
                  separated: true),
        ], target: self)
        topToolbar.setHidden(true, forTag: ChromeTag.playback)

        bottomBar = ToolbarCapsule(items: [
            .init(tag: ChromeTag.zoomOut, symbols: ["minus.magnifyingglass"],
                  fallbackTitle: "−", toolTip: "缩小", action: #selector(chromeZoomOut)),
            .init(tag: ChromeTag.zoomIn, symbols: ["plus.magnifyingglass"],
                  fallbackTitle: "+", toolTip: "放大", action: #selector(chromeZoomIn)),
            .init(tag: ChromeTag.prev, symbols: ["chevron.left"],
                  fallbackTitle: "←", toolTip: "上一张", action: #selector(chromePrev),
                  separated: true),
            .init(tag: ChromeTag.next, symbols: ["chevron.right"],
                  fallbackTitle: "→", toolTip: "下一张", action: #selector(chromeNext)),
            .init(tag: ChromeTag.open, symbols: ["folder"],
                  fallbackTitle: "打开", toolTip: "打开…", action: #selector(chromeOpen),
                  separated: true),
            .init(tag: ChromeTag.filmstrip, symbols: ["film"],
                  fallbackTitle: "缩略图", toolTip: "缩略图条", action: #selector(chromeFilmstrip)),
            .init(tag: ChromeTag.info, symbols: ["info"],
                  fallbackTitle: "i", toolTip: "信息面板", action: #selector(chromeInfo)),
            .init(tag: ChromeTag.fullScreen, symbols: ["arrow.up.left.and.arrow.down.right"],
                  fallbackTitle: "全屏", toolTip: "全屏", action: #selector(chromeFullScreen),
                  separated: true),
        ], target: self)

        scrollView.frame = bounds
        scrollView.onMagnificationChanged = { [weak self] magnification in
            self?.statusZoomText = "\(Int((magnification * 100).rounded()))%"
            self?.pushStatus()
            self?.onZoomChanged?()
        }
        addSubview(scrollView)

        filmstrip.isHidden = true
        filmstrip.onSelect = { [weak self] index in
            self?.onFilmstripSelect?(index)
        }
        addSubview(filmstrip)

        infoPanel.isHidden = true
        infoPanel.onClose = { [weak self] in
            self?.onToggleInfoPanel?()
        }
        addSubview(infoPanel)

        for capsule in [titleCapsule, topToolbar!, bottomBar!, statusStrip] {
            capsule.alphaValue = 0
            addSubview(capsule)
        }

        addSubview(spinner)
        addSubview(messageLabel)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        animator = PageTurnAnimator(hostView: self, scrollView: scrollView)
        scrollView.pageSwipeDelegate = self

        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    /// Everything floats: the scroll view fills the window edge-to-edge
    /// (under the transparent titlebar), the info panel and filmstrip hover
    /// over the image instead of taking layout space.
    override func layout() {
        super.layout()
        scrollView.frame = bounds

        // The strip exists only while the pointer is in the bottom zone and
        /// the preference allows hover reveal.
        let stripShown = filmstripEnabled && filmstripTransient && filmstripHasContent

        // Bottom cluster stacks like Pixea: status strip hugs the bottom-left
        // corner, the control capsule sits just above it, and the filmstrip
        // floats above the capsule.
        statusStrip.isHidden = statusZoomText.isEmpty && statusIndexText.isEmpty
            && statusItems.isEmpty
        statusStrip.frame = NSRect(
            x: 10,
            y: 8,
            width: min(statusStrip.fittingSize.width, bounds.width - 20),
            height: 22
        )
        let bottomSize = bottomBar.fittingSize
        bottomBar.frame = NSRect(
            x: (bounds.width - bottomSize.width) / 2,
            y: statusStrip.frame.maxY + 8,
            width: bottomSize.width,
            height: bottomSize.height
        )
        // Full-width band flush against the window edges, above the capsule.
        filmstrip.frame = NSRect(
            x: 0,
            y: bottomBar.frame.maxY + 8,
            width: bounds.width,
            height: FilmstripView.height
        )
        filmstrip.isHidden = !stripShown
        if stripShown {
            filmstrip.ensureLoaded()
        }

        infoPanel.frame = NSRect(
            x: bounds.width - infoPanelWidth - 8,
            y: 8,
            width: infoPanelWidth,
            height: bounds.height - 16
        )

        let topSize = topToolbar.fittingSize
        topToolbar.frame = NSRect(
            x: (bounds.width - topSize.width) / 2,
            y: bounds.height - topSize.height - 8,
            width: topSize.width,
            height: topSize.height
        )
        // Breadcrumb shares the titlebar row with the traffic lights; on
        // narrow windows it shrinks, then hides rather than collide with
        // the top toolbar.
        let maxBreadcrumb = topToolbar.frame.minX - 88
        let breadcrumbWidth = min(titleCapsule.fittingSize.width, maxBreadcrumb)
        if breadcrumbWidth < 48 || breadcrumbText.isEmpty {
            titleCapsule.isHidden = true
        } else {
            titleCapsule.isHidden = false
            titleCapsule.frame = NSRect(
                x: 76,
                y: bounds.height - 32,
                width: breadcrumbWidth,
                height: 24
            )
        }
    }

    // MARK: - Chrome visibility

    /// All always-on-hover chrome except the filmstrip (it has its own
    /// enabled/transient logic) and the info panel (toggled state).
    private var chromeViews: [NSView] {
        [titleCapsule, topToolbar, bottomBar, statusStrip]
    }

    private func setChrome(alpha: CGFloat) {
        // Placeholder state has no capsules at all; traffic lights stay
        // visible at all times (per user preference over Pixea's hover-only).
        let target = showsPlaceholder ? 0 : alpha
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            for view in chromeViews {
                view.animator().alphaValue = target
            }
        }
    }

    /// Reveal chrome and (re)start the idle countdown unless the pointer is
    /// resting inside a chrome region.
    func showChrome() {
        if !chromeVisible {
            chromeVisible = true
            setChrome(alpha: 1)
        }
        if let point = lastMousePoint, isInsideChrome(point) {
            chromeHideWorkItem?.cancel()
        } else {
            scheduleChromeHide()
        }
    }

    private func scheduleChromeHide(delay: TimeInterval = 1.8) {
        chromeHideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.hideChrome()
        }
        chromeHideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func hideChrome() {
        // Never pull the UI out from under the pointer.
        if let point = lastMousePoint, isInsideChrome(point) {
            scheduleChromeHide()
            return
        }
        chromeHideWorkItem?.cancel()
        guard chromeVisible || filmstripTransient else { return }
        chromeVisible = false
        setChrome(alpha: 0)
        filmstripHideWorkItem?.cancel()
        filmstripHideWorkItem = nil
        filmstripTransient = false
        needsLayout = true
    }

    /// Bottom edge height where hovering floats the strip / pins chrome.
    private var bottomHotZone: CGFloat {
        filmstripTransient ? filmstrip.frame.maxY + 16 : bottomBar.frame.maxY + 14
    }

    /// Regions where the pointer pins chrome visible: every capsule, the
    /// titlebar row (traffic lights), and the filmstrip hover zone.
    private func isInsideChrome(_ point: NSPoint) -> Bool {
        if point.y > bounds.height - 40 { return true }        // titlebar row
        if point.y < bottomHotZone { return true }             // bottom cluster
        for view in chromeViews where !view.isHidden && view.alphaValue > 0 {
            if view.frame.contains(point) { return true }
        }
        return false
    }

    // MARK: - Info panel / status strip / breadcrumb

    func setInfoPanelVisible(_ visible: Bool) {
        infoPanelVisible = visible
        syncInfoPanelHidden()
        bottomBar.setHighlighted(visible, forTag: ChromeTag.info)
        needsLayout = true
    }

    /// Panel only exists over an actual image — never on the placeholder.
    private func syncInfoPanelHidden() {
        infoPanel.isHidden = !infoPanelVisible || showsPlaceholder
    }

    func updateInfoPanel(metadata: ImageMetadata?) {
        infoPanel.update(metadata: metadata)
        guard let metadata else {
            statusItems = []
            pushStatus()
            return
        }
        var items: [String] = []
        if let dims = metadata.pixelSizeText {
            items.append(metadata.dpiText.map { "\(dims) (\($0))" } ?? dims)
        }
        if let size = metadata.fileSizeText { items.append(size) }
        if let date = metadata.createdText { items.append(date) }
        statusItems = items
        pushStatus()
    }

    /// Status-strip index column ("3 / 12").
    func setStatusIndex(_ index: Int, total: Int) {
        statusIndexText = total > 0 ? "\(index + 1)/\(total)" : ""
        pushStatus()
    }

    /// Dims the prev/next capsule buttons at the first/last image.
    func setNavBounds(canPrevious: Bool, canNext: Bool) {
        bottomBar.setEnabled(canPrevious, forTag: ChromeTag.prev)
        bottomBar.setEnabled(canNext, forTag: ChromeTag.next)
    }

    private var statusIndexText = ""

    private func pushStatus() {
        statusStrip.setItems([statusZoomText, statusIndexText]
            .filter { !$0.isEmpty } + statusItems)
        statusStrip.isHidden = statusZoomText.isEmpty && statusIndexText.isEmpty
            && statusItems.isEmpty
        needsLayout = true
    }

    /// Breadcrumb next to the traffic lights: "folder ▸ file.png".
    /// Hidden entirely when no file is loaded.
    func setTitleInfo(folder: String, file: String) {
        breadcrumbText = file
        titleCapsule.setTitle(folder: folder, file: file)
        needsLayout = true
    }

    // MARK: - Filmstrip

    func setFilmstripEnabled(_ enabled: Bool) {
        filmstripEnabled = enabled
        if !enabled {
            filmstripHideWorkItem?.cancel()
            filmstripHideWorkItem = nil
            filmstripTransient = false
        }
        bottomBar.setHighlighted(enabled, forTag: ChromeTag.filmstrip)
        needsLayout = true
    }

    func setFilmstripFiles(_ urls: [URL]) {
        filmstripHasContent = urls.count > 1
        filmstrip.setFiles(urls)
        needsLayout = true
    }

    func setFilmstripIndex(_ index: Int) {
        filmstrip.setCurrentIndex(index)
    }

    func cachedFilmstripThumbnail(for index: Int) -> CGImage? {
        filmstrip.cachedThumbnail(for: index)
    }

    /// Bottom-edge hover reveals the strip when the preference is off;
    /// bottom-bar button toggles the persisted preference instead.
    func toggleFilmstripPreference() {
        onToggleFilmstrip?()
    }

    // MARK: - Content

    func setImage(_ image: CGImage?, displaySize: NSSize) {
        showsPlaceholder = false
        syncInfoPanelHidden()
        messageLabel.isHidden = true
        setLoading(false)
        animator?.finishImmediately()
        scrollView.setImage(image, displaySize: displaySize)
        setPlaybackVisible(false)
        showChrome()
    }

    func setAnimated(_ animated: AnimatedImage, displaySize: NSSize, quarterTurns: Int) {
        showsPlaceholder = false
        syncInfoPanelHidden()
        messageLabel.isHidden = true
        setLoading(false)
        animator?.finishImmediately()
        scrollView.setAnimatedContent(
            animated, displaySize: displaySize, quarterTurns: quarterTurns
        )
        setPlaybackVisible(true)
        showChrome()
    }

    func updateAnimatedRotation(quarterTurns: Int, displaySize: NSSize) {
        scrollView.updateAnimatedRotation(
            quarterTurns: quarterTurns, displaySize: displaySize
        )
    }

    func updateImage(_ image: CGImage, displaySize: NSSize) {
        scrollView.updateImage(image, displaySize: displaySize)
    }

    /// Swaps in higher-resolution pixels without changing layout.
    func upgradeStill(_ image: CGImage) {
        scrollView.upgradeStill(image)
    }

    /// Placeholder text shown when there is no image (empty state or error).
    func setMessage(_ message: String) {
        showsPlaceholder = true
        syncInfoPanelHidden()
        setLoading(false)
        scrollView.setImage(nil, displaySize: .zero)
        statusZoomText = ""
        statusIndexText = ""
        statusItems = []
        pushStatus()
        messageLabel.stringValue = message
        messageLabel.isHidden = false
    }

    private var breadcrumbText = ""

    func setLoading(_ loading: Bool) {
        messageLabel.isHidden = true
        if loading {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    func setBackgroundColor(_ color: NSColor) {
        layer?.backgroundColor = color.cgColor
        scrollView.backgroundColor = color
    }

    private func setPlaybackVisible(_ visible: Bool) {
        topToolbar.setHidden(!visible, forTag: ChromeTag.playback)
        if visible { updatePlaybackIcon() }
    }

    private func updatePlaybackIcon() {
        let paused = scrollView.isAnimationPaused
        topToolbar.setSymbols(
            paused ? ["play.fill"] : ["pause.fill"],
            fallbackTitle: paused ? "播" : "停",
            forTag: ChromeTag.playback
        )
        topToolbar.setHidden(false, forTag: ChromeTag.playback)
    }

    // MARK: - Page-turn animation

    /// Runs the slide transition for a committed swipe. Called before the real
    /// image is swapped in underneath the overlay.
    func commitPageTurn(
        direction: SwipeTracker.Direction,
        outgoing: CGImage?,
        incoming: CGImage?
    ) {
        animator?.commit(
            direction: direction,
            outgoing: outgoing,
            incoming: incoming,
            fittedRect: { imageSize in
                Self.aspectFitRect(imageSize: imageSize, in: scrollView.bounds)
            }
        )
    }

    /// Aspect-fit rect of `imageSize` centered inside `rect` (same math the
    /// scroll view's fit mode produces).
    static func aspectFitRect(imageSize: NSSize, in rect: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Full screen

    func setFullScreen(_ fullScreen: Bool) {
        isFullScreen = fullScreen
        filmstripTransient = false
        filmstripHideWorkItem?.cancel()
        filmstripHideWorkItem = nil
        cursorHideWorkItem?.cancel()
        if fullScreen {
            scheduleCursorHide()
        } else if cursorIsHidden {
            cursorIsHidden = false
            NSCursor.unhide()
        }
        showChrome()
        needsLayout = true
    }

    private func scheduleCursorHide() {
        cursorHideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard self?.isFullScreen == true, self?.cursorIsHidden == false else { return }
            self?.cursorIsHidden = true
            NSCursor.hide()
            self?.hideChrome()
        }
        cursorHideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = mouseTrackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        mouseTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        lastMousePoint = convert(event.locationInWindow, from: nil)
        if isFullScreen {
            if cursorIsHidden {
                cursorIsHidden = false
                NSCursor.unhide()
            }
            scheduleCursorHide()
        }
        // Hover near the bottom edge floats the strip — but only when the
        /// preference is ON; off means never (saves decode work). Hiding is
        /// delayed so briefly overshooting the zone doesn't yank it away.
        if let point = lastMousePoint {
            let inZone = filmstripEnabled && filmstripHasContent
                && point.y < (filmstripTransient ? filmstrip.frame.maxY + 16 : 160)
            if inZone {
                filmstripHideWorkItem?.cancel()
                if !filmstripTransient {
                    filmstripTransient = true
                    needsLayout = true
                }
            } else if filmstripTransient, filmstripHideWorkItem == nil {
                let item = DispatchWorkItem { [weak self] in
                    self?.filmstripHideWorkItem = nil
                    self?.filmstripTransient = false
                    self?.needsLayout = true
                }
                filmstripHideWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: item)
            }
        }
        showChrome()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        lastMousePoint = nil
        // Pointer left the window — pull the chrome promptly.
        scheduleChromeHide(delay: 0.2)
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Arrow/function keys carry .function/.numericPad in modifierFlags;
        // only look at the command-style modifiers.
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let shift = mods.contains(.shift)
        // Bare keys only; ⌘ shortcuts are handled by the menu.
        guard mods.isSubset(of: [.shift]) else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 123: // Left arrow
            actionDelegate?.imageViewDidRequestPrevious(self)
        case 124: // Right arrow
            actionDelegate?.imageViewDidRequestNext(self)
        case 115: // Home
            actionDelegate?.imageViewDidRequestFirst(self)
        case 119: // End
            actionDelegate?.imageViewDidRequestLast(self)
        case 49: // Space
            if shift {
                actionDelegate?.imageViewDidRequestPrevious(self)
            } else {
                actionDelegate?.imageViewDidRequestNext(self)
            }
        case 3 where event.charactersIgnoringModifiers == "f" && !shift: // F
            actionDelegate?.imageViewDidRequestToggleFullScreen(self)
        case 53: // Escape
            actionDelegate?.imageViewDidRequestExitFullScreen(self)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Empty-state double-click (Photoshop-style open)

    override func mouseDown(with event: NSEvent) {
        if showsPlaceholder, event.clickCount == 2 {
            onOpen?()
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: - Chrome button actions

    @objc private func chromeRotateLeft() { onRotate?(-1) }
    @objc private func chromeRotateRight() { onRotate?(1) }
    @objc private func chromeFit() { scrollView.zoomToFit() }
    @objc private func chromeActual() { scrollView.zoomToActual() }
    @objc private func chromePlayback() {
        onTogglePlayback?()
        updatePlaybackIcon()
    }
    @objc private func chromeZoomOut() { scrollView.zoomOut() }
    @objc private func chromeZoomIn() { scrollView.zoomIn() }
    @objc private func chromePrev() { actionDelegate?.imageViewDidRequestPrevious(self) }
    @objc private func chromeNext() { actionDelegate?.imageViewDidRequestNext(self) }
    @objc private func chromeOpen() { onOpen?() }
    @objc private func chromeFilmstrip() { onToggleFilmstrip?() }
    @objc private func chromeInfo() { onToggleInfoPanel?() }
    @objc private func chromeFullScreen() {
        actionDelegate?.imageViewDidRequestToggleFullScreen(self)
    }

    // MARK: - Drag & Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedURLs(sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = draggedURLs(sender), !urls.isEmpty else { return false }
        actionDelegate?.imageView(self, didReceiveDroppedURLs: urls)
        return true
    }

    private func draggedURLs(_ info: NSDraggingInfo) -> [URL]? {
        info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
    }
}

extension ImageView: PageSwipeDelegate {
    func scrollView(_ scrollView: ImageScrollView, canTurn direction: SwipeTracker.Direction) -> Bool {
        actionDelegate?.imageViewCanTurn(self, direction: direction) ?? false
    }

    func scrollView(_ scrollView: ImageScrollView, didDragBy offset: CGFloat) {
        animator?.drag(by: offset)
    }

    func scrollViewDidSettle(_ scrollView: ImageScrollView) {
        animator?.cancel()
    }

    func scrollView(_ scrollView: ImageScrollView, didTrigger direction: SwipeTracker.Direction) {
        actionDelegate?.imageViewDidRequestSwipeTurn(self, direction: direction)
    }
}
