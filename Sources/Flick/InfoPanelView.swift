import AppKit
import FlickCore

/// Floating inspector panel on the right edge showing file + image + EXIF
/// metadata. Text is selectable/copyable; missing fields are simply absent.
final class InfoPanelView: NSVisualEffectView {
    private let textView: NSTextView
    /// Wired by the container to the controller's close action.
    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

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

        scroll.documentView = text
        self.textView = text

        super.init(frame: frameRect)
        material = .sidebar
        blendingMode = .behindWindow
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L10n.s("Close", "关闭"))!,
            target: self,
            action: #selector(closeTapped)
        )
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = L10n.s("Close Info Panel", "关闭信息面板")
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // 1pt separator on the leading edge
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeTapped() {
        onClose?()
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

        for (index, section) in metadata.sections.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            result.append(NSAttributedString(
                string: section.title + "\n",
                attributes: [.font: titleFont, .foregroundColor: valueColor]
            ))
            for field in section.fields {
                result.append(NSAttributedString(
                    string: field.label + "\n",
                    attributes: [.font: labelFont, .foregroundColor: labelColor]
                ))
                result.append(NSAttributedString(
                    string: field.value + "\n",
                    attributes: [.font: valueFont, .foregroundColor: valueColor]
                ))
                result.append(NSAttributedString(string: "\n"))
            }
        }
        textView.textStorage?.setAttributedString(result)
        textView.scrollToBeginningOfDocument(nil)
    }
}
