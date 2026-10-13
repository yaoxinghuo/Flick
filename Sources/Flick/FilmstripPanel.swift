import AppKit
import FlickCore

/// Floating filmstrip: a child `NSPanel` pinned to the bottom center of the
/// screen — Pixea-style. Being a separate window means the strip never moves
/// when the image window resizes, so consecutive thumbnails stay clickable.
final class FilmstripPanel: NSPanel {
    static let height: CGFloat = 68
    static let margin: CGFloat = 8

    let strip = FilmstripView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        // Strip clicks select images; the panel itself never becomes key.
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        collectionBehavior = [.fullScreenAuxiliary]
        isReleasedWhenClosed = false
        // Explicit initial frame: NSView() starts at .zero and autoresizing
        // never grows it, leaving an invisible 0×0 strip.
        strip.frame = NSRect(x: 0, y: 0, width: 400, height: Self.height)
        strip.autoresizingMask = [.width, .height]
        strip.layer?.cornerRadius = 10
        contentView = NSView(frame: strip.frame)
        contentView?.addSubview(strip)
    }

    /// Pill width hugs the content but caps at 60% of the screen — wider
    /// reads as a bar, not a panel, and buries the current item's context.
    /// Overflow scrolls horizontally inside the strip.
    func idealWidth(for screen: NSScreen) -> CGFloat {
        min(max(strip.contentWidth, 240), screen.visibleFrame.width * 0.6)
    }
}
