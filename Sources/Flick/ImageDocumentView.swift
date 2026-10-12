import AppKit

/// The zoomable canvas inside `ImageScrollView`. `bounds` is the image's pixel
/// space; the scroll view scales it through magnification. Handles
/// double-click zoom toggling and click-drag panning.
final class ImageDocumentView: NSView {
    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    private var panStartDocPoint: NSPoint?
    private var panStartOrigin: NSPoint?
    private var isPanning = false

    private var scrollView: ImageScrollView? {
        enclosingScrollView as? ImageScrollView
    }

    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.cgContext.draw(image, in: bounds)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            scrollView?.toggleSmartZoom(at: convert(event.locationInWindow, from: nil))
            return
        }
        guard let scrollView, scrollView.canPan else {
            super.mouseDown(with: event)
            return
        }
        isPanning = true
        panStartDocPoint = convert(event.locationInWindow, from: nil)
        panStartOrigin = scrollView.documentVisibleRect.origin
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPanning, let scrollView,
              let start = panStartDocPoint, let origin = panStartOrigin else {
            super.mouseDragged(with: event)
            return
        }
        scrollView.dragPan(
            from: start,
            startOrigin: origin,
            to: convert(event.locationInWindow, from: nil)
        )
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning {
            isPanning = false
            NSCursor.pop()
        }
        super.mouseUp(with: event)
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        super.resetCursorRects()
        if scrollView?.canPan == true {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}
