import AppKit
import FlickCore

/// Reports trackpad page-turn gestures detected by `ImageScrollView`.
protocol PageSwipeDelegate: AnyObject {
    /// Whether a turn in `direction` is currently allowed (navigator bounds).
    func scrollView(_ scrollView: ImageScrollView, canTurn direction: SwipeTracker.Direction) -> Bool
    /// Finger-following drag offset; damped at edges by the tracker.
    func scrollView(_ scrollView: ImageScrollView, didDragBy offset: CGFloat)
    /// Gesture ended without turning — snap back.
    func scrollViewDidSettle(_ scrollView: ImageScrollView)
    /// Threshold/velocity reached — perform the turn.
    func scrollView(_ scrollView: ImageScrollView, didTrigger direction: SwipeTracker.Direction)
}

enum ZoomMode {
    case fit      // whole image inside the window
    case fill     // image covers the window, overflow cropped
    case actual   // 100% (1 image pixel = 1 point)
    case custom   // free pinch / stepped zoom
}

/// Keeps a document smaller than the viewport centered instead of pinned to
/// the top-left corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if document.frame.width < rect.width {
            rect.origin.x = (document.frame.width - rect.width) / 2
        }
        if document.frame.height < rect.height {
            rect.origin.y = (document.frame.height - rect.height) / 2
        }
        return rect
    }
}

/// Zoom/pan surface for a single image. `magnification` is implemented by
/// scaling the clip view's bounds, so "fit" math must use the clip view's
/// *frame* (real points), not its bounds (document units).
final class ImageScrollView: NSScrollView {
    private(set) var zoomMode: ZoomMode = .fit
    /// Unscaled image size (rotated), i.e. document size at magnification 1.
    private(set) var imageSize: NSSize = .zero
    /// Called whenever the effective magnification changes.
    var onMagnificationChanged: ((CGFloat) -> Void)?

    weak var pageSwipeDelegate: PageSwipeDelegate?
    private var swipeTracker = SwipeTracker()
    private var lastSwipeTriggerTime: TimeInterval = -.greatestFiniteMagnitude

    private var frameObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = CenteringClipView(frame: bounds)
        let document = ImageDocumentView(frame: .zero)
        document.wantsLayer = true // needed for the page-drag transform
        documentView = document
        hasVerticalScroller = true
        hasHorizontalScroller = true
        scrollerStyle = .overlay
        autohidesScrollers = true
        allowsMagnification = true

        contentView.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: contentView,
            queue: .main
        ) { [weak self] _ in
            self?.clipViewDidResize()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let frameObserver {
            NotificationCenter.default.removeObserver(frameObserver)
        }
    }

    private var document: ImageDocumentView {
        documentView as! ImageDocumentView
    }

    // MARK: - Magnification model

    private var clipSize: NSSize { contentView.frame.size }

    var fitMagnification: CGFloat {
        magnification(fitting: .fit)
    }

    var fillMagnification: CGFloat {
        magnification(fitting: .fill)
    }

    private func magnification(fitting mode: ZoomMode) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        let clip = clipSize
        guard clip.width > 0, clip.height > 0 else { return 1 }
        let width = clip.width / imageSize.width
        let height = clip.height / imageSize.height
        return mode == .fill ? max(width, height) : min(width, height)
    }

    /// Whether the magnified image overflows the viewport (drag-pan allowed).
    /// Both sides are in document coordinates: the visible rect is the clip
    /// view's bounds (scaled by magnification), the document's bounds are the
    /// unscaled image size.
    var canPan: Bool {
        let visible = documentVisibleRect.size
        let doc = document.bounds.size
        return visible.width < doc.width - 0.5 || visible.height < doc.height - 0.5
    }

    private func updateMagnificationRange() {
        let fit = fitMagnification
        minMagnification = max(fit * 0.25, 0.01)
        // At least 8x absolute, so huge images can still be inspected at 100%+.
        maxMagnification = max(fit * 32, 8)
    }

    /// Replaces the displayed image and resets to fit.
    /// `displaySize` is the *real* image size (rotated), which may be larger
    /// than the decoded `image` when a downsampled tier is shown — the doc
    /// view stretches it, and a higher-res tier can be swapped in via
    /// `upgradeStill` without touching layout.
    func setImage(_ image: CGImage?, displaySize: NSSize) {
        imageSize = displaySize
        document.clearAnimated()
        document.image = image
        document.layer?.transform = CATransform3DIdentity
        document.frame = NSRect(origin: .zero, size: displaySize)
        zoomMode = .fit
        updateMagnificationRange()
        magnification = fitMagnification
        scrollToTopLeft()
        notify()
    }

    /// Displays an animated image; doc bounds = `displaySize` (rotated dims),
    /// the animation layer handles rotation via its own transform.
    func setAnimatedContent(
        _ animated: AnimatedImage,
        displaySize: NSSize,
        quarterTurns: Int
    ) {
        imageSize = displaySize
        document.setAnimated(animated, quarterTurns: quarterTurns)
        document.layer?.transform = CATransform3DIdentity
        document.frame = NSRect(origin: .zero, size: displaySize)
        zoomMode = .fit
        updateMagnificationRange()
        magnification = fitMagnification
        scrollToTopLeft()
        notify()
    }

    /// Rotation change while animated: doc bounds swap w/h on odd turns,
    /// the animation layer just re-transforms — zero pixel work.
    func updateAnimatedRotation(quarterTurns: Int, displaySize: NSSize) {
        imageSize = displaySize
        document.setAnimatedRotation(quarterTurns)
        document.frame = NSRect(origin: .zero, size: displaySize)
        updateMagnificationRange()
        applyModeMagnification()
        scrollToTopLeft()
        notify()
    }

    /// New pixels, same logical image (e.g. after rotation). Keeps the mode.
    func updateImage(_ image: CGImage, displaySize: NSSize) {
        imageSize = displaySize
        document.image = image
        document.frame = NSRect(origin: .zero, size: displaySize)
        updateMagnificationRange()
        switch zoomMode {
        case .fit, .fill:
            applyModeMagnification()
        default:
            magnification = min(max(magnification, minMagnification), maxMagnification)
        }
        scrollToTopLeft()
        notify()
    }

    /// Swaps in higher-resolution pixels for the same still — doc bounds
    /// stay identical, so the only visible change is sharper content.
    func upgradeStill(_ image: CGImage) {
        document.image = image
        document.layer?.transform = CATransform3DIdentity
    }

    // MARK: - Animation playback

    var hasAnimatedContent: Bool { document.animatedImage != nil }
    var isAnimationPaused: Bool { document.isAnimationPaused }

    @discardableResult
    func toggleAnimationPause() -> Bool {
        document.toggleAnimationPause()
    }

    private func scrollToTopLeft() {
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }

    private func clipViewDidResize() {
        guard imageSize != .zero else { return }
        updateMagnificationRange()
        if zoomMode == .fit || zoomMode == .fill {
            applyModeMagnification()
        } else {
            magnification = min(max(magnification, minMagnification), maxMagnification)
        }
        notify()
    }

    private func applyModeMagnification() {
        magnification = zoomMode == .fill ? fillMagnification : fitMagnification
    }

    // MARK: - Zoom actions

    func zoomToFit() {
        zoomMode = .fit
        updateMagnificationRange()
        applyModeMagnification()
        notify()
    }

    func zoomToFill() {
        zoomMode = .fill
        updateMagnificationRange()
        applyModeMagnification()
        notify()
    }

    func zoomToActual() {
        zoom(to: 1.0, anchoredAt: visibleCenter)
        zoomMode = .actual
    }

    func zoomIn() {
        zoom(to: magnification * 1.25, anchoredAt: visibleCenter)
    }

    func zoomOut() {
        zoom(to: magnification / 1.25, anchoredAt: visibleCenter)
    }

    /// Double-click / two-finger double-tap: fit ↔ 100% at the pointer.
    /// `docPoint` is in documentView coordinates.
    func toggleSmartZoom(atDocPoint docPoint: NSPoint) {
        let atFit = abs(magnification - fitMagnification) < fitMagnification * 0.02
        zoom(to: atFit ? 1.0 : fitMagnification, anchoredAt: docPoint)
        zoomMode = atFit ? .actual : .fit
    }

    private var visibleCenter: NSPoint {
        let rect = documentVisibleRect
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    /// Sets magnification while keeping `docPoint` at the same on-screen
    /// position (its fractional offset inside the viewport is preserved).
    private func zoom(to target: CGFloat, anchoredAt docPoint: NSPoint) {
        guard imageSize != .zero else { return }
        let clamped = min(max(target, minMagnification), maxMagnification)
        let before = documentVisibleRect
        let fraction = NSPoint(
            x: (docPoint.x - before.origin.x) / before.width,
            y: (docPoint.y - before.origin.y) / before.height
        )
        magnification = clamped
        let after = documentVisibleRect
        contentView.scroll(to: NSPoint(
            x: docPoint.x - fraction.x * after.width,
            y: docPoint.y - fraction.y * after.height
        ))
        reflectScrolledClipView(contentView)
        zoomMode = .custom
        notify()
    }

    // MARK: - Gestures

    /// Native pinch zoom: anchored under the cursor by AppKit.
    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        zoomMode = .custom
        notify()
    }

    override func smartMagnify(with event: NSEvent) {
        toggleSmartZoom(atDocPoint: document.convert(event.locationInWindow, from: nil))
    }

    // MARK: - Page-turn gestures

    /// Route: trackpad two-finger swipes drive the page tracker only while the
    /// image cannot be panned on either axis; anything else (mouse wheel,
    /// momentum, zoomed-in content) is regular scrolling.
    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else {
            super.scrollWheel(with: event)
            return
        }
        guard !canPan else {
            swipeTracker.reset()
            super.scrollWheel(with: event)
            return
        }

        swipeTracker.viewportWidth = Double(contentView.frame.width)
        swipeTracker.canGoNext = pageSwipeDelegate?.scrollView(self, canTurn: .next) ?? false
        swipeTracker.canGoPrevious = pageSwipeDelegate?.scrollView(self, canTurn: .previous) ?? false

        guard let trackerEvent = Self.trackerEvent(from: event) else { return }
        switch swipeTracker.handle(trackerEvent) {
        case .none:
            break
        case .drag(let offset):
            pageSwipeDelegate?.scrollView(self, didDragBy: CGFloat(offset))
        case .trigger(let direction):
            lastSwipeTriggerTime = event.timestamp
            pageSwipeDelegate?.scrollView(self, didTrigger: direction)
        case .settle:
            pageSwipeDelegate?.scrollViewDidSettle(self)
        }
    }

    /// Fallback path for swipes delivered as `swipe(with:)` (e.g. three-finger
    /// or differently-configured trackpads). Deduplicated against the tracker
    /// so the same gesture can't turn twice.
    override func swipe(with event: NSEvent) {
        guard !canPan,
              swipeTracker.state == .idle,
              event.timestamp - lastSwipeTriggerTime > 0.6 else {
            return
        }
        if event.deltaX < -0.3 {
            lastSwipeTriggerTime = event.timestamp
            pageSwipeDelegate?.scrollView(self, didTrigger: .next)
        } else if event.deltaX > 0.3 {
            lastSwipeTriggerTime = event.timestamp
            pageSwipeDelegate?.scrollView(self, didTrigger: .previous)
        }
    }

    private static func trackerEvent(from event: NSEvent) -> SwipeTracker.Event? {
        let phase = event.phase
        if phase.contains(.began) {
            return .began
        } else if phase.contains(.changed) {
            return .changed(
                dx: Double(event.scrollingDeltaX),
                dy: Double(event.scrollingDeltaY),
                at: event.timestamp
            )
        } else if phase.contains(.ended) {
            return .ended(at: event.timestamp)
        } else if phase.contains(.cancelled) {
            return .cancelled
        }
        return nil
    }

    // MARK: - Panning (mouse drag)

    /// Scrolls so the document point stays under the pointer during a drag.
    /// `scroll(to:)` runs edge constraints so the image can't be dragged out.
    func dragPan(from startDocPoint: NSPoint, startOrigin: NSPoint, to currentDocPoint: NSPoint) {
        contentView.scroll(to: NSPoint(
            x: startOrigin.x - (currentDocPoint.x - startDocPoint.x),
            y: startOrigin.y - (currentDocPoint.y - startDocPoint.y)
        ))
        reflectScrolledClipView(contentView)
    }

    private func notify() {
        onMagnificationChanged?(magnification)
    }
}
