import AppKit
import FlickCore

/// One filmstrip cell: fixed square, thumbnail aspect-fit inside, selection
/// ring when current. Reused by the collection view; cancels its pending
/// decode on reuse.
/// Cell container that keeps the thumbnail inset — autoresizing produced
/// garbage origins under the collection view's internal layout passes.
private final class ThumbnailCellView: NSView {
    let thumbView = NSImageView()
    /// Direct click path — `didSelectItemsAt` alone can go silent when the
    /// collection view's own `selectionIndexPaths` desyncs from our index
    /// (a stale "already selected" cell produces no delegate callback).
    var onTap: (() -> Void)?
    /// Belt-and-suspenders scroll forwarding: the strip (not a cell) owns
    /// panning, so any wheel event landing on a cell climbs straight to it.
    var onScroll: ((NSEvent) -> Void)?

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
        let tap = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }

    @objc private func tapped() {
        onTap?()
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

    /// NSCollectionView consumes scrollWheel itself (trying to scroll an
    /// enclosing NSScrollView that doesn't exist), so the strip's own
    /// scrollWheel override never runs. Forward the event up the chain.
    private final class PassthroughCollectionView: NSCollectionView {
        override func scrollWheel(with event: NSEvent) {
            nextResponder?.scrollWheel(with: event)
        }
    }

    var onSelect: ((Int) -> Void)?

    private lazy var thumbnailStore = ThumbnailStore(
        maxPixelSize: Int(64 * (NSScreen.main?.backingScaleFactor ?? 2))
    )
    private let collectionView = PassthroughCollectionView()
    private var urls: [URL] = []
    private var currentIndex = -1
    private var suppressSelectCallback = false
    /// Manual horizontal pan. NSScrollView refused to stay chrome-free (its
    /// scroller subview persisted despite has*Scroller=false), so the strip
    /// slides the collection view itself — no scroller can exist at all.
    private var scrollOffset: CGFloat = 0 {
        didSet {
            let clamped = min(max(0, scrollOffset), maxOffset)
            collectionView.frame = NSRect(
                x: -clamped, y: 0,
                width: max(contentWidth, bounds.width), height: bounds.height
            )
            // One nested didSet when clamped differs; the second pass sees
            // equal values and just re-sets the frame — no recursion loop.
            if clamped != scrollOffset { scrollOffset = clamped }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.72).cgColor
        // Full-width flush band: the layer clips cells scrolled out of view
        // without needing a clip view.
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
        addSubview(collectionView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Re-run the didSet clamp so a resized strip repositions its content.
        scrollOffset += 0
    }

    /// Full laid-out width of all cells (sectionInset 6 + N*(56+4) - 4).
    var contentWidth: CGFloat {
        let cell = Self.itemSize.width + Self.spacing
        return max(0, CGFloat(urls.count) * cell - Self.spacing + 12)
    }

    private var maxOffset: CGFloat {
        max(0, contentWidth - bounds.width)
    }

    /// Pans the strip. Trackpads/Magic Mouse report pixel deltas via
    /// scrollingDelta*; wheel mice report line-unit deltas via delta*, so a
    /// notch maps to one full cell — otherwise each tick moves a few points
    /// and the strip feels frozen.
    override func scrollWheel(with event: NSEvent) {
        pan(with: event)
    }

    /// Shared pan handler so cells, the collection view, and the strip itself
    /// all feed the same path regardless of which view the event lands on.
    private func pan(with event: NSEvent) {
        let dx: CGFloat, dy: CGFloat
        if event.hasPreciseScrollingDeltas {
            dx = event.scrollingDeltaX
            dy = event.scrollingDeltaY
        } else {
            let step = Self.itemSize.width + Self.spacing
            dx = event.deltaX * step
            dy = event.deltaY * step
        }
        let delta = abs(dx) >= abs(dy) ? dx : dy
        scrollOffset -= delta
    }

    // MARK: - Content

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
        currentIndex = index
        // Re-derive every visible cell's ring from the index — updating only
        // prev/current left stale rings on reused cells whose indexPath
        // lookup fails (nil) or that changed index during a manual scroll.
        for item in collectionView.visibleItems() {
            guard let thumb = item as? ThumbnailItem else { continue }
            let itemIndex = collectionView.indexPath(for: item)?.item
            thumb.isCurrent = itemIndex == index
        }
        let path = IndexPath(item: index, section: 0)
        suppressSelectCallback = true
        // Drop any stale selection first: a lingering "already selected"
        // index makes that cell's clicks produce no didSelectItemsAt.
        collectionView.deselectAll(nil)
        collectionView.selectItems(at: [path], scrollPosition: [])
        suppressSelectCallback = false
        // Defer one run loop: layout attributes for offscreen items are only
        // guaranteed after the collection view has laid out the new selection.
        DispatchQueue.main.async { [weak self] in
            self?.centerItem(at: path)
        }
    }

    private func centerItem(at path: IndexPath) {
        guard let attributes = collectionView.layoutAttributesForItem(at: path) else { return }
        scrollOffset = attributes.frame.midX - bounds.width / 2
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
        (item.view as? ThumbnailCellView)?.onTap = { [weak self] in
            self?.onSelect?(indexPath.item)
        }
        (item.view as? ThumbnailCellView)?.onScroll = { [weak self] event in
            self?.pan(with: event)
        }
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
        // Don't set currentIndex here — the controller's setCurrentIndex
        // (via onSelect) recalibrates all rings, and pre-setting it would
        // trip the index-equality guard and skip that update.
        onSelect?(index)
    }
}
