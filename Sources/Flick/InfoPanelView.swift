import AppKit
import FlickCore

/// Floating inspector panel on the right edge showing file + image + EXIF
/// metadata. Text is selectable/copyable; missing fields are simply absent.
final class InfoPanelView: NSVisualEffectView {
    private let textView: NSTextView
    private let scroll = NSScrollView()
    private let closeButton = NSButton()
    private let dragStrip = PanelDragStrip()
    private let separator = NSBox()
    /// Wired by the container to the controller's close action.
    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) {
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = .zero
        text.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineFragmentPadding = 4

        self.textView = text

        super.init(frame: frameRect)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = text
        material = .sidebar
        // .withinWindow blends with the image beneath the floating panel
        // (.behindWindow would blend with the desktop behind the app), and
        // a slight alpha keeps it translucent instead of fully opaque.
        blendingMode = .withinWindow
        alphaValue = 0.92
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L10n.s("Close", "关闭"))
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = L10n.s("Close Info Panel", "关闭信息面板")

        // Everything is positioned in layout(), not Auto Layout: a
        // constraint-based subtree lets NSWindow's layout engine auto-fit
        // the panel window to the (near-empty) intrinsic content size,
        // collapsing its height.
        separator.boxType = .separator
        addSubview(scroll)
        addSubview(dragStrip)
        addSubview(separator)
        addSubview(closeButton)  // topmost
        placeSubviews()
    }

    // resizeSubviews (not layout()) is the hook guaranteed to run on every
    // frame change for a constraint-free, autoresizing subtree.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        placeSubviews()
    }

    private func placeSubviews() {
        scroll.frame = bounds
        // Drag strip hugs the top edge; its rightmost 30pt is carved out for
        // the close button so it can never swallow the button's clicks.
        dragStrip.frame = NSRect(x: 0, y: bounds.height - 26,
                                 width: bounds.width - 30, height: 26)
        separator.frame = NSRect(x: 0, y: 0, width: 1, height: bounds.height)
        closeButton.frame = NSRect(x: bounds.width - 24, y: bounds.height - 24,
                                   width: 18, height: 18)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeTapped() {
        onClose?()
    }

    /// Transparent strip that hands its mouse events to the panel's drag
    /// mechanism (`performDrag` re-enters normal window moving) — the
    /// selectable text view would otherwise swallow drags.
    private final class PanelDragStrip: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        override var mouseDownCanMoveWindow: Bool { true }
    }

    func update(metadata: ImageMetadata?) {
        guard let metadata else {
            textView.string = ""
            return
        }
        let result = NSMutableAttributedString()
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let labelFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let valueFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let labelColor = NSColor.secondaryLabelColor
        let valueColor = NSColor.labelColor

        // Field runs sit one indent level under their section title so the
        // heading/body hierarchy reads at a glance.
        let fieldStyle = NSMutableParagraphStyle()
        fieldStyle.headIndent = 10
        fieldStyle.firstLineHeadIndent = 10

        for (index, section) in metadata.sections.enumerated() {
            // Section titles get extra headroom via paragraph spacing rather
            // than counting newlines — blank-line height would depend on
            // whichever font the run inherited.
            let titleStyle = NSMutableParagraphStyle()
            titleStyle.paragraphSpacingBefore = index > 0 ? 18 : 0
            titleStyle.paragraphSpacing = 4
            result.append(NSAttributedString(
                string: section.title + "\n",
                attributes: [
                    .font: titleFont,
                    .foregroundColor: valueColor,
                    .paragraphStyle: titleStyle,
                ]
            ))
            for field in section.fields {
                result.append(NSAttributedString(
                    string: field.label + "\n",
                    attributes: [
                        .font: labelFont,
                        .foregroundColor: labelColor,
                        .paragraphStyle: fieldStyle,
                    ]
                ))
                result.append(NSAttributedString(
                    string: field.value + "\n",
                    attributes: [
                        .font: valueFont,
                        .foregroundColor: valueColor,
                        .paragraphStyle: fieldStyle,
                    ]
                ))
                result.append(NSAttributedString(
                    string: "\n",
                    attributes: [.paragraphStyle: fieldStyle]
                ))
            }
        }
        textView.textStorage?.setAttributedString(result)
        textView.scrollToBeginningOfDocument(nil)
    }
}
