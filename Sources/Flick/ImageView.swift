import AppKit

protocol ImageViewActionDelegate: AnyObject {
    func imageViewDidRequestNext(_ view: ImageView)
    func imageViewDidRequestPrevious(_ view: ImageView)
    func imageViewDidRequestFirst(_ view: ImageView)
    func imageViewDidRequestLast(_ view: ImageView)
    func imageView(_ view: ImageView, didReceiveDroppedURLs urls: [URL])
}

/// The single-image canvas. Draws the current `CGImage` aspect-fit on a dark
/// background, plus placeholder/help text. Handles keyboard navigation and
/// file dropping. Zoom/pan arrive via `NSScrollView` in a later milestone, so
/// this view stays deliberately simple.
final class ImageView: NSView {
    weak var actionDelegate: ImageViewActionDelegate?

    private(set) var image: CGImage?
    private var message: String?
    private var loading = false

    private let spinner: NSProgressIndicator = {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .large
        indicator.isDisplayedWhenStopped = false
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Content

    func setImage(_ image: CGImage?) {
        self.image = image
        self.message = nil
        setLoading(false)
        needsDisplay = true
    }

    /// Placeholder text shown when there is no image (empty state or error).
    func setMessage(_ message: String) {
        self.image = nil
        self.message = message
        setLoading(false)
        needsDisplay = true
    }

    func setLoading(_ loading: Bool) {
        self.loading = loading
        if loading {
            self.message = nil
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
        dirtyRect.fill()

        if let image {
            let rect = aspectFitRect(
                imageSize: NSSize(width: image.width, height: image.height),
                in: bounds
            )
            NSGraphicsContext.current?.imageInterpolation = .high
            NSGraphicsContext.current?.cgContext.draw(image, in: rect)
        } else if let message, !loading {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = (message as NSString).size(withAttributes: attributes)
            let origin = NSPoint(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2
            )
            (message as NSString).draw(at: origin, withAttributes: attributes)
        }
    }

    private func aspectFitRect(imageSize: NSSize, in rect: NSRect) -> NSRect {
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

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
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
