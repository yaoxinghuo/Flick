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
    private let infoPanel = InfoPanelView()
    private let infoPanelWidth: CGFloat = 260
    private let filmstrip = FilmstripView()
    private(set) var infoPanelVisible = false

    /// User's filmstrip preference (persisted by the controller). In full
    /// screen the strip hides and only floats up on bottom-edge hover.
    private(set) var filmstripEnabled = false
    private var filmstripTransient = false
    private var filmstripHideWorkItem: DispatchWorkItem?

    var onFilmstripSelect: ((Int) -> Void)?

    /// Called whenever magnification changes — the controller uses it to
    /// decide whether a higher-resolution decode is needed.
    var onZoomChanged: (() -> Void)?

    private var mouseTrackingArea: NSTrackingArea?
    private var isFullScreen = false
    private var cursorIsHidden = false
    private var cursorHideWorkItem: DispatchWorkItem?
    private var animator: PageTurnAnimator?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        scrollView.frame = bounds
        scrollView.onMagnificationChanged = { [weak self] magnification in
            self?.zoomHUD.show(text: "\(Int((magnification * 100).rounded()))%")
            self?.onZoomChanged?()
        }
        addSubview(scrollView)

        infoPanel.isHidden = true
        addSubview(infoPanel)

        filmstrip.isHidden = true
        filmstrip.onSelect = { [weak self] index in
            self?.onFilmstripSelect?(index)
        }
        addSubview(filmstrip)

        addSubview(spinner)
        addSubview(messageLabel)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        addSubview(zoomHUD)

        animator = PageTurnAnimator(hostView: self, scrollView: scrollView)
        scrollView.pageSwipeDelegate = self

        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    /// Sidebar layout: scroll view takes the space left of the info panel and
    /// above the filmstrip. In full screen the strip floats over the content
    /// instead of shrinking it, so hover reveal doesn't refit the image.
    override func layout() {
        super.layout()
        let panelWidth = infoPanelVisible ? infoPanelWidth : 0
        let stripVisible = filmstripEnabled && (!isFullScreen || filmstripTransient)
        let floating = isFullScreen
        let stripHeight = stripVisible ? FilmstripView.height : 0

        scrollView.frame = NSRect(
            x: 0, y: floating ? 0 : stripHeight,
            width: bounds.width - panelWidth,
            height: bounds.height - (floating ? 0 : stripHeight)
        )
        infoPanel.frame = NSRect(
            x: bounds.width - panelWidth, y: 0,
            width: panelWidth, height: bounds.height
        )
        filmstrip.frame = NSRect(
            x: 0, y: 0,
            width: bounds.width - panelWidth, height: stripHeight
        )
        filmstrip.isHidden = stripHeight == 0
        if stripHeight > 0 {
            filmstrip.ensureLoaded()
        }
        // Keep the HUD pinned to the scroll view's right edge, above the strip.
        zoomHUD.frame.origin = NSPoint(
            x: scrollView.frame.maxX - zoomHUD.frame.width - 12,
            y: scrollView.frame.minY + 12
        )
    }

    // MARK: - Info panel

    func setInfoPanelVisible(_ visible: Bool) {
        infoPanelVisible = visible
        infoPanel.isHidden = !visible
        needsLayout = true
    }

    func updateInfoPanel(metadata: ImageMetadata?) {
        infoPanel.update(metadata: metadata)
    }

    // MARK: - Filmstrip

    func setFilmstripEnabled(_ enabled: Bool) {
        filmstripEnabled = enabled
        if !enabled { filmstripTransient = false }
        needsLayout = true
    }

    func setFilmstripFiles(_ urls: [URL]) {
        filmstrip.setFiles(urls)
    }

    func setFilmstripIndex(_ index: Int) {
        filmstrip.setCurrentIndex(index)
    }

    func cachedFilmstripThumbnail(for index: Int) -> CGImage? {
        filmstrip.cachedThumbnail(for: index)
    }

    // MARK: - Content

    func setImage(_ image: CGImage?, displaySize: NSSize) {
        messageLabel.isHidden = true
        setLoading(false)
        animator?.finishImmediately()
        scrollView.setImage(image, displaySize: displaySize)
    }

    func setAnimated(_ animated: AnimatedImage, displaySize: NSSize, quarterTurns: Int) {
        messageLabel.isHidden = true
        setLoading(false)
        animator?.finishImmediately()
        scrollView.setAnimatedContent(
            animated, displaySize: displaySize, quarterTurns: quarterTurns
        )
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
        setLoading(false)
        scrollView.setImage(nil, displaySize: .zero)
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
        needsLayout = true
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
        updateFilmstripHover(mouseY: event.locationInWindow.y)
    }

    /// Bottom-edge hover reveals the filmstrip in full screen. Hysteresis on
    /// the hide threshold keeps it from flickering at the boundary.
    private func updateFilmstripHover(mouseY: CGFloat) {
        guard filmstripEnabled else { return }
        if !filmstripTransient, mouseY < 44 {
            filmstripHideWorkItem?.cancel()
            filmstripTransient = true
            needsLayout = true
        } else if filmstripTransient, mouseY > FilmstripView.height + 24 {
            filmstripHideWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.filmstripTransient = false
                self?.needsLayout = true
            }
            filmstripHideWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
        } else {
            filmstripHideWorkItem?.cancel()
        }
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
