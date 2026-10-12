import AppKit
import FlickCore

/// One filmstrip cell: fixed square, thumbnail aspect-fit inside, selection
/// ring when current. Reused by the collection view; cancels its pending
/// decode on reuse.
private final class ThumbnailItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("flick.thumbnail")

    private let thumbView = NSImageView()
    private var request: ThumbnailRequest?
    private var generation = 0

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 4
        view = container

        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.imageAlignment = .alignCenter
        thumbView.frame = view.bounds.insetBy(dx: 4, dy: 4)
        thumbView.autoresizingMask = [.width, .height]
        view.addSubview(thumbView)
        updateHighlight()
    }

    override var isSelected: Bool {
        didSet { updateHighlight() }
    }

    private func updateHighlight() {
        view.layer?.borderWidth = isSelected ? 2 : 0
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            : nil
    }

    func configure(url: URL, store: ThumbnailStore, cached: CGImage?) {
        request?.cancel()
        generation += 1
        let gen = generation
        thumbView.image = cached.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        guard cached == nil else { return }
        request = store.request(url) { [weak self] image in
            guard let self, self.generation == gen else { return }
            self.thumbView.image = image.map {
                NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        request?.cancel()
        request = nil
        thumbView.image = nil
    }
}

/// Bottom filmstrip: a horizontal `NSCollectionView` of thumbnails. The
/// current image stays selected and centered; clicks and arrow-driven
/// selection report through `onSelect`.
final class FilmstripView: NSView {
    static let height: CGFloat = 92
    private static let itemSize = NSSize(width: 80, height: 80)

    var onSelect: ((Int) -> Void)?

    private lazy var thumbnailStore = ThumbnailStore(
        maxPixelSize: Int(160 * (NSScreen.main?.backingScaleFactor ?? 2))
    )
    private let collectionView = NSCollectionView()
    private var scroll: NSScrollView!
    private var urls: [URL] = []
    private var currentIndex = -1
    private var suppressSelectCallback = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.35).cgColor

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = Self.itemSize
        layout.minimumInteritemSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)

        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsEmptySelection = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(ThumbnailItem.self, forItemWithIdentifier: ThumbnailItem.identifier)

        let scroll = NSScrollView()
        scroll.documentView = collectionView
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        scroll.frame = bounds
        addSubview(scroll)
        self.scroll = scroll
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Content

    func setFiles(_ newURLs: [URL]) {
        urls = newURLs
        currentIndex = -1
        collectionView.reloadData()
    }

    /// Highlights `index` and scrolls it to the strip's horizontal center.
    func setCurrentIndex(_ index: Int) {
        guard index >= 0, index < urls.count, index != currentIndex else { return }
        currentIndex = index
        let path = IndexPath(item: index, section: 0)
        suppressSelectCallback = true
        collectionView.selectItems(at: [path], scrollPosition: [])
        suppressSelectCallback = false
        // Defer one run loop: layout attributes for offscreen items are only
        // guaranteed after the collection view has laid out the new selection.
        DispatchQueue.main.async { [weak self] in
            self?.centerItem(at: path)
        }
    }

    private func centerItem(at path: IndexPath) {
        guard let attributes = collectionView.layoutAttributesForItem(at: path),
              let clip = scroll?.contentView else { return }
        let centered = NSPoint(
            x: max(0, attributes.frame.midX - clip.frame.width / 2),
            y: 0
        )
        clip.scroll(to: centered)
        scroll.reflectScrolledClipView(clip)
    }

    /// Thumbnail for the page-turn animation overlay (synchronous cache only).
    func cachedThumbnail(for index: Int) -> CGImage? {
        guard index >= 0, index < urls.count else { return nil }
        return thumbnailStore.cachedThumbnail(for: urls[index])
    }
}

extension FilmstripView: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        urls.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: ThumbnailItem.identifier, for: indexPath
        )
        let url = urls[indexPath.item]
        (item as? ThumbnailItem)?.configure(
            url: url,
            store: thumbnailStore,
            cached: thumbnailStore.cachedThumbnail(for: url)
        )
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !suppressSelectCallback,
              let index = indexPaths.first?.item else { return }
        currentIndex = index
        onSelect?(index)
    }
}
