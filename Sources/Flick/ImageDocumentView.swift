import AppKit
import FlickCore

/// Draws the image at Retina resolution inside the scroll view.
/// Stills are drawn directly; animated images play via a `CAKeyframeAnimation`
/// on a dedicated layer (GPU-side playback, unaffected by zoom/rotation).
final class ImageDocumentView: NSView {
    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    /// Double-click with the click point in document coordinates.
    var onDoubleClick: ((NSPoint) -> Void)?
    /// Whether the image currently overflows the viewport (drag = pan).
    var canPanProvider: (() -> Bool)?
    /// Clip-view origin at drag start, in document coordinates.
    var panOriginProvider: (() -> NSPoint)?
    /// Called during a pan drag with start/current points in doc coords.
    var onPanDrag: ((_ from: NSPoint, _ startOrigin: NSPoint, _ to: NSPoint) -> Void)?

    private var panning = false
    private var panStartDoc = NSPoint.zero
    private var panStartOrigin = NSPoint.zero
    /// Dragging a fitted image (no titlebar in immersive mode) moves the
    /// window, matching Pixea. `performDrag` must only fire once per drag.
    private var windowDragArmed = false

    private var animationLayer: CALayer?
    private var animationQuarterTurns = 0
    private(set) var isAnimationPaused = false
    private(set) var animatedImage: AnimatedImage?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Animated content

    /// Displays an animated image. `displaySize` is the doc-view size (already
    /// rotated dims); the animation layer is rotated via transform so frames
    /// never need per-pixel rotation work.
    func setAnimated(_ animated: AnimatedImage, quarterTurns: Int) {
        animatedImage = animated
        image = nil
        isAnimationPaused = false
        animationQuarterTurns = quarterTurns

        let layer = CALayer()
        layer.bounds = CGRect(origin: .zero, size: animated.size)
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true

        let frames = CAKeyframeAnimation(keyPath: "contents")
        frames.values = animated.frames
        frames.keyTimes = animated.keyTimes
        frames.duration = animated.duration
        frames.repeatCount = .infinity
        frames.calculationMode = .discrete
        frames.isRemovedOnCompletion = false
        layer.add(frames, forKey: "flick.frames")

        animationLayer?.removeFromSuperlayer()
        animationLayer = layer
        self.layer?.addSublayer(layer)
        applyAnimationTransform()
    }

    /// Re-applies rotation to the animation layer (doc bounds are already the
    /// rotated dims — the layer fills them after its transform).
    func setAnimatedRotation(_ quarterTurns: Int) {
        animationQuarterTurns = quarterTurns
        applyAnimationTransform()
    }

    private func applyAnimationTransform() {
        guard let layer = animationLayer else { return }
        layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let angle: CGFloat
        switch ((animationQuarterTurns % 4) + 4) % 4 {
        case 1: angle = -.pi / 2
        case 2: angle = .pi
        case 3: angle = .pi / 2
        default: angle = 0
        }
        layer.setAffineTransform(CGAffineTransform(rotationAngle: angle))
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyAnimationTransform()
        CATransaction.commit()
    }

    /// Toggles pause; returns the new paused state.
    @discardableResult
    func toggleAnimationPause() -> Bool {
        guard let layer = animationLayer else { return false }
        if isAnimationPaused {
            let pausedTime = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        } else {
            layer.timeOffset = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
        }
        isAnimationPaused.toggle()
        return isAnimationPaused
    }

    func clearAnimated() {
        animationLayer?.removeFromSuperlayer()
        animationLayer = nil
        animatedImage = nil
        isAnimationPaused = false
    }

    // MARK: - Drawing (stills only)

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let image else {
            return
        }
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
    }

    // MARK: - Mouse: double-click zoom, drag-to-pan, drag-to-move-window

    override func resetCursorRects() {
        super.resetCursorRects()
        if canPanProvider?() == true {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            onDoubleClick?(point)
            return
        }
        if canPanProvider?() == true {
            panning = true
            panStartDoc = point
            panStartOrigin = panOriginProvider?() ?? .zero
            NSCursor.closedHand.push()
        } else {
            // Never pannable: arm the window drag for this gesture instead.
            windowDragArmed = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if panning {
            onPanDrag?(panStartDoc, panStartOrigin, convert(event.locationInWindow, from: nil))
        } else if windowDragArmed {
            windowDragArmed = false
            window?.performDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if panning {
            panning = false
            NSCursor.pop()
        }
        windowDragArmed = false
    }
}
