import AppKit

/// Shared look for the floating overlay UI (Pixea-style): a dark blurred
/// capsule that fades in on mouse movement and fades out when idle.
class ChromeCapsule: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Bordered icon/text button for inside a capsule. SF Symbols are tried in
/// order; a plain-text title is the fallback when none resolves.
final class ChromeButton: NSButton {
    init(
        symbols: [String],
        fallbackTitle: String,
        toolTip: String,
        tag: Int = 0,
        target: AnyObject?,
        action: Selector
    ) {
        super.init(frame: .zero)
        self.tag = tag
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .smallSquare
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        contentTintColor = NSColor(white: 1, alpha: 0.9)
        self.toolTip = toolTip
        symbolNames = symbols
        self.fallbackTitle = fallbackTitle
        applyIcon()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var symbolNames: [String] = []
    private var fallbackTitle = ""

    /// Re-resolves the icon, e.g. after a state change swaps the symbol list.
    func setSymbols(_ names: [String], fallbackTitle: String) {
        symbolNames = names
        self.fallbackTitle = fallbackTitle
        applyIcon()
    }

    private func applyIcon() {
        var found: NSImage?
        for name in symbolNames {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                found = image
                break
            }
        }
        if let found {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            image = found.withSymbolConfiguration(config) ?? found
            title = ""
            imagePosition = .imageOnly
        } else {
            image = nil
            title = fallbackTitle
            font = .systemFont(ofSize: 12, weight: .medium)
            imagePosition = .noImage
        }
    }
}

/// Horizontal row of buttons inside a dark capsule. Buttons are addressed by
/// tag so the controller can swap icons (play/pause) or highlight toggles.
final class ToolbarCapsule: ChromeCapsule {
    private let stack = NSStackView()
    private var buttons: [Int: ChromeButton] = [:]
    /// Separators belong to the button that follows them, so hiding a button
    /// (e.g. play/pause on a still) doesn't leave an orphan divider behind.
    private var separators: [Int: NSBox] = [:]

    struct Item {
        let tag: Int
        let symbols: [String]
        let fallbackTitle: String
        let toolTip: String
        let action: Selector
        /// A 4pt separator is inserted before this item when true.
        let separated: Bool

        init(
            tag: Int,
            symbols: [String],
            fallbackTitle: String,
            toolTip: String,
            action: Selector,
            separated: Bool = false
        ) {
            self.tag = tag
            self.symbols = symbols
            self.fallbackTitle = fallbackTitle
            self.toolTip = toolTip
            self.action = action
            self.separated = separated
        }
    }

    init(items: [Item], target: AnyObject) {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for item in items {
            if item.separated {
                let sep = NSBox()
                sep.boxType = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(sep)
                NSLayoutConstraint.activate([
                    sep.widthAnchor.constraint(equalToConstant: 1),
                    sep.heightAnchor.constraint(equalToConstant: 16),
                ])
                separators[item.tag] = sep
            }
            let button = ChromeButton(
                symbols: item.symbols,
                fallbackTitle: item.fallbackTitle,
                toolTip: item.toolTip,
                tag: item.tag,
                target: target,
                action: item.action
            )
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 26),
                button.heightAnchor.constraint(equalToConstant: 24),
            ])
            stack.addArrangedSubview(button)
            buttons[item.tag] = button
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setSymbols(_ names: [String], fallbackTitle: String, forTag tag: Int) {
        buttons[tag]?.setSymbols(names, fallbackTitle: fallbackTitle)
    }

    /// NSStackView collapses hidden items, e.g. play/pause on stills.
    func setHidden(_ hidden: Bool, forTag tag: Int) {
        buttons[tag]?.isHidden = hidden
        separators[tag]?.isHidden = hidden
    }

    /// Accent tint marks a toggle-style button as "on" (e.g. info panel open).
    func setHighlighted(_ highlighted: Bool, forTag tag: Int) {
        buttons[tag]?.contentTintColor = highlighted
            ? .controlAccentColor
            : NSColor(white: 1, alpha: 0.9)
    }
}

/// Titlebar stand-in shown on hover: folder ▸ filename, positioned next to
/// the traffic lights like Pixea's breadcrumb.
final class TitleCapsule: ChromeCapsule {
    private let folderIcon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = 8

        folderIcon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        folderIcon.contentTintColor = NSColor(white: 1, alpha: 0.85)
        folderIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(folderIcon)

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor(white: 1, alpha: 0.92)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            folderIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            folderIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            folderIcon.widthAnchor.constraint(equalToConstant: 14),
            folderIcon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: folderIcon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(folder: String, file: String) {
        label.stringValue = folder.isEmpty ? file : "\(folder) ▸ \(file)"
    }
}

/// Bottom-left info strip: zoom / index / pixel size / file size / date,
/// Pixea-style "236% · 1/18 · 413×626 (300dpi) · 395 KB · 创建于…".
final class StatusStrip: ChromeCapsule {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = 7
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = NSColor(white: 1, alpha: 0.85)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setItems(_ items: [String]) {
        label.stringValue = items.joined(separator: "  ·  ")
        needsLayout = true
    }
}
