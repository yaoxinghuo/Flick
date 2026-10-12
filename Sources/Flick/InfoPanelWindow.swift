import AppKit
import FlickCore

/// Floating inspector: a child `NSPanel` that docks to the right
/// of the image window when there's room, else overlays its right edge.
/// Draggable by its background, non-activating so it never steals focus,
/// and `fullScreenAuxiliary` lets it ride into the parent's fullscreen space.
final class InfoPanelWindow: NSPanel {
    static let width: CGFloat = 280

    let content = InfoPanelView(
        frame: NSRect(x: 0, y: 0, width: InfoPanelWindow.width, height: 420)
    )

    /// Wired by the controller to the toggle action.
    var onClose: (() -> Void)? {
        get { content.onClose }
        set { content.onClose = newValue }
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        // Panels hide by default when the app loses focus — the inspector
        // should stay up while the user clicks around other apps.
        hidesOnDeactivate = false
        // Clicking text may take key for selection; panel never activates app.
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        collectionBehavior = [.fullScreenAuxiliary]
        isReleasedWhenClosed = false
        // Container contentView keeps autoresizing simple; the panel content
        // fills it edge to edge.
        content.autoresizingMask = [.width, .height]
        content.frame = NSRect(x: 0, y: 0, width: Self.width, height: 420)
        contentView = NSView(frame: content.frame)
        contentView?.addSubview(content)
    }
}
