import AppKit
import FlickCore

/// Visual layer for page turns. The navigation state in the controller always
/// advances synchronously; this object only decorates the swap, so rapid
/// consecutive swipes can never leave the screen blank or mid-transition.
final class PageTurnAnimator {
    private weak var hostView: NSView?       // container overlay is added to
    private weak var scrollView: ImageScrollView?
    private var overlay: NSView?
    private var currentOffset: CGFloat = 0

    init(hostView: NSView, scrollView: ImageScrollView) {
        self.hostView = hostView
        self.scrollView = scrollView
    }

    private var documentLayer: CALayer? {
        scrollView?.documentView?.layer
    }

    /// Moves the live document with the finger (damped at edges by the tracker).
    func drag(by offset: CGFloat) {
        currentOffset = offset
        documentLayer?.transform = CATransform3DMakeTranslation(offset, 0, 0)
    }

    /// Slides the outgoing image fully off and the incoming one in.
    /// `incoming`/`outgoing` are the already-rotated display images.
    /// `fittedRect` maps an image size onto the viewport's aspect-fit rect.
    func commit(
        direction: SwipeTracker.Direction,
        outgoing: CGImage?,
        incoming: CGImage?,
        fittedRect: (NSSize) -> NSRect
    ) {
        finishImmediately()
        guard let hostView, let scrollView else { return }

        let width = scrollView.bounds.width
        let sign: CGFloat = direction == .next ? -1 : 1   // next slides left

        let overlayView = NSView(frame: scrollView.frame)
        overlayView.wantsLayer = true
        overlayView.layer?.masksToBounds = true
        overlayView.autoresizingMask = [.width, .height]
        hostView.addSubview(overlayView, positioned: .above, relativeTo: scrollView)
        overlay = overlayView

        let offset = currentOffset
        var outLayer: CALayer?
        if let outgoing {
            let layer = makeImageLayer(
                outgoing,
                in: fittedRect(NSSize(width: outgoing.width, height: outgoing.height))
            )
            layer.position.x += offset
            overlayView.layer?.addSublayer(layer)
            outLayer = layer
        }
        var inLayer: CALayer?
        if let incoming {
            let layer = makeImageLayer(
                incoming,
                in: fittedRect(NSSize(width: incoming.width, height: incoming.height))
            )
            layer.position.x += offset - sign * width
            overlayView.layer?.addSublayer(layer)
            inLayer = layer
        }

        // From here on the real document is reset; the overlay takes over.
        setDocumentOffset(0)

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setCompletionBlock { [weak self] in
            self?.overlay?.removeFromSuperview()
            self?.overlay = nil
        }
        outLayer?.position.x += sign * width
        inLayer?.position.x += sign * width
        CATransaction.commit()
    }

    /// Gesture ended without a turn — spring the document back to rest.
    func cancel() {
        finishOverlay()
        guard currentOffset != 0 else { return }
        currentOffset = 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        documentLayer?.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    /// Removes all animation state immediately (new image set, rapid re-swipe).
    func finishImmediately() {
        finishOverlay()
        setDocumentOffset(0)
    }

    private func finishOverlay() {
        overlay?.removeFromSuperview()
        overlay = nil
    }

    private func setDocumentOffset(_ offset: CGFloat) {
        currentOffset = offset
        documentLayer?.transform = offset == 0
            ? CATransform3DIdentity
            : CATransform3DMakeTranslation(offset, 0, 0)
    }

    private func makeImageLayer(_ image: CGImage, in rect: NSRect) -> CALayer {
        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resize
        layer.frame = rect
        return layer
    }
}
