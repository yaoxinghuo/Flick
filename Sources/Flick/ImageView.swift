import AppKit

protocol ImageViewActionDelegate: AnyObject {
    func imageViewDidRequestNext(_ view: ImageView)
    func imageViewDidRequestPrevious(_ view: ImageView)
    func imageViewDidRequestFirst(_ view: ImageView)
    func imageViewDidRequestLast(_ view: ImageView)
    func imageViewDidRequestToggleFullScreen(_ view: ImageView)
    func imageViewDidRequestExitFullScreen(_ view: ImageView)
    func imageView(_ view: ImageView, didReceiveDroppedURLs urls: [URL])
}

/// The window's content: an `ImageScrollView` canvas plus a loading spinner,
/// a centered message label (empty state / errors) and a zoom HUD. Handles
/// keyboard navigation, file dropping and cursor auto-hide in full screen.
final class ImageView: NSView {
    weak var actionDelegate: ImageViewActionDelegate?

    let scrollView = ImageScrollView()

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

    private let zoomHUD = ZoomHUDView()

    private var mouseTrackingArea: NSTrackingArea?
    private var isFullScreen = false
    private var cursorIsHidden = false
    private var cursorHideWorkItem: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.onMagnificationChanged = { [weak self] magnification in
            self?.zoomHUD.show(text: "\(Int((magnification * 100).rounded()))%")
        }
        addSubview(scrollView)

        addSubview(spinner)
        addSubview(messageLabel)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        zoomHUD.autoresizingMask = [.minXMargin, .maxYMargin]
        addSubview(zoomHUD)

        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Content

    func setImage(_ image: CGImage?) {
        messageLabel.isHidden = true
        setLoading(false)
        scrollView.setImage(image)
    }

    func updateImage(_ image: CGImage) {
        scrollView.updateImage(image)
    }

    /// Placeholder text shown when there is no image (empty state or error).
    func setMessage(_ message: String) {
        setLoading(false)
        scrollView.setImage(nil)
        zoomHUD.hideImmediately()
        messageLabel.stringValue = message
        messageLabel.isHidden = false
    }

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

    // MARK: - Full screen

    func setFullScreen(_ fullScreen: Bool) {
        isFullScreen = fullScreen
        cursorHideWorkItem?.cancel()
        if fullScreen {
            scheduleCursorHide()
        } else if cursorIsHidden {
            cursorIsHidden = false
            NSCursor.unhide()
        }
    }

    private func scheduleCursorHide() {
        cursorHideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard self?.isFullScreen == true, self?.cursorIsHidden == false else { return }
            self?.cursorIsHidden = true
            NSCursor.hide()
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
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        mouseTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard isFullScreen else { return }
        if cursorIsHidden {
            cursorIsHidden = false
            NSCursor.unhide()
        }
        scheduleCursorHide()
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
