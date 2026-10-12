import AppKit

/// Small translucent capsule showing the current zoom level. Appears on every
/// zoom change, then fades out after a short delay.
final class ZoomHUDView: NSView {
    private var text = ""
    private var hideWorkItem: DispatchWorkItem?

    private let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private let horizontalPadding: CGFloat = 10
    private let verticalPadding: CGFloat = 5

    init() {
        super.init(frame: .zero)
        alphaValue = 0
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Updates the displayed text and restarts the auto-hide countdown.
    func show(text: String) {
        self.text = text
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        frame.size = NSSize(
            width: textSize.width + horizontalPadding * 2,
            height: textSize.height + verticalPadding * 2
        )
        // Anchor to the bottom-right corner of the superview.
        if let superview {
            frame.origin = NSPoint(
                x: superview.bounds.width - frame.width - 12,
                y: 12
            )
        }
        needsDisplay = true

        hideWorkItem?.cancel()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
        let item = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                self?.animator().alphaValue = 0
            }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    /// Stops the HUD from auto-hiding (image unloaded etc.).
    func hideImmediately() {
        hideWorkItem?.cancel()
        alphaValue = 0
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.55).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(white: 1, alpha: 0.9),
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: bounds.midX - textSize.width / 2, y: bounds.midY - textSize.height / 2),
            withAttributes: attributes
        )
    }
}
