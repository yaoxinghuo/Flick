import AppKit
import FlickCore

/// One filmstrip cell: fixed square, thumbnail aspect-fit inside, selection
/// ring when current. Reused by the collection view; cancels its pending
/// decode on reuse.
/// Cell container that keeps the thumbnail inset — autoresizing produced
/// garbage origins under the collection view's internal layout passes.
private final class ThumbnailCellView: NSView {
    let thumbView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        // NSImageView defaults to isEditable=true: it draws a gray-blue bezel
        // with no image (looked like "every cell highlighted") and swallows
        // clicks meant for the collection view. Must be disabled.
        thumbView.isEditable = false
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.imageAlignment = .alignCenter
        addSubview(thumbView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        thumbView.frame = bounds.insetBy(dx: 4, dy: 4)
    }
}

private final class ThumbnailItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("flick.thumbnail")

    private var thumbView: NSImageView {
        (view as? ThumbnailCellView)!.thumbView
    }
    private var request: ThumbnailRequest?
    private var generation = 0

    /// The selection ring is driven by our own `isCurrent` flag, not the
    /// collection view's `isSelected` — reused cells kept a stale highlight
    /// (two rings visible) because `isSelected` isn't reliably reset on
    /// dequeue.
    var isCurrent = false {
        didSet { updateHighlight() }
    }

    /// NSCollectionView instantiates items via `init()` and never calls
    /// `loadView` for class-registered items — build the view eagerly here.
    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        view = ThumbnailCellView()
        updateHighlight()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateHighlight() {
        view.layer?.borderWidth = isCurrent ? 2 : 0
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.backgroundColor = isCurrent
            ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            : nil
    }

    func configure(url: URL, isCurrent: Bool, store: ThumbnailStore, cached: CGImage?) {
        self.isCurrent = isCurrent
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
        isCurrent = false
        thumbView.image = nil
    }
}

/// Floating filmstrip capsule: a horizontal `NSCollectionView` of thumbnails
/// centered above the bottom bar. The current image stays selected and
/// centered; clicks and arrow-driven selection report through `onSelect`.
final class FilmstripView: NSView {
    static let height: CGFloat = 68
    private static let itemSize = NSSize(width: 56, height: 56)
    private static let spacing: CGFloat = 4

    var onSelect: ((Int) -> Void)?

    private lazy var thumbnailStore = ThumbnailStore(
        maxPixelSize: Int(64 * (NSScreen.main?.backingScaleFactor ?? 2))
    )
    private let collectionView = NSCollectionView()
    private var scroll: NSScrollView!
    private var urls: [URL] = []
    private var currentIndex = -1
    private var suppressSelectCallback = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.72).cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = Self.itemSize
        layout.minimumInteritemSpacing = Self.spacing
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
        // Scrollable but chrome-free — both scrollers off, overlay style as
        // a belt so nothing ever draws a track on the capsule.
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
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

    /// Width the strip wants for `maxWidth`: enough for all cells, clamped so
    /// narrow windows show fewer (scrollable) instead of overflowing.
    func preferredWidth(maxWidth: CGFloat) -> CGFloat {
        let cell = Self.itemSize.width + Self.spacing
        let content = CGFloat(urls.count) * cell + 12 - Self.spacing
        return max(min(content, maxWidth), min(2 * cell + 12, maxWidth))
    }

    func setFiles(_ newURLs: [URL]) {
        urls = newURLs
        currentIndex = -1
        collectionView.reloadData()
    }

    /// `reloadData` run while the strip was hidden/zero-sized can leave the
    /// collection view without items. Called once it becomes visible so the
    /// first open doesn't show an empty strip.
    func ensureLoaded() {
        guard !urls.isEmpty, collectionView.visibleItems().isEmpty else { return }
        collectionView.reloadData()
        let index = currentIndex
        currentIndex = -1
        setCurrentIndex(index)
    }

    /// Highlights `index` and scrolls it to the strip's horizontal center.
    /// The ring is a data flag on each item, so offscreen cells get it at
    /// dequeue and visible ones update in place.
    func setCurrentIndex(_ index: Int) {
        guard index >= 0, index < urls.count, index != currentIndex else { return }
        let previous = currentIndex
        currentIndex = index
        for item in collectionView.visibleItems() {
            guard let thumb = item as? ThumbnailItem,
                  let itemIndex = collectionView.indexPath(for: item)?.item,
                  itemIndex == index || itemIndex == previous else { continue }
            thumb.isCurrent = itemIndex == index
        }
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
            isCurrent: indexPath.item == currentIndex,
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
