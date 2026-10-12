import AppKit
import FlickCore

/// Owns the single browser window: resolves what to show (folder vs. ad-hoc
/// list), drives `ImageNavigator`, loads images through `ImageStore` and keeps
/// the UI (title, canvas, menus) in sync.
final class MainWindowController: NSWindowController {
    private let imageView = ImageView()
    private let store = ImageStore()

    private var files: [ImageFile] = []
    private var navigator = ImageNavigator()
    private var sortOrder = ImageSortOrder()
    /// The folder currently being browsed. `nil` when the list is an ad-hoc
    /// selection of files (multi-file drag / open-panel multi-select).
    private var currentFolder: URL?
    private var loadTask: ImageLoadTask?
    /// On-demand full-resolution load for downsampled stills.
    private var hiResTask: ImageLoadTask?
    private var hiResLoaded = false
    /// Quarter-turns clockwise applied to the displayed image (view-only).
    private var rotation = 0
    /// Decoded image (display tier) before rotation; re-rendered on rotate.
    private var baseImage: CGImage?
    /// True while the current file is an animated image (GIF/APNG/WebP).
    private var isAnimatedContent = false
    /// Source's true pixel dimensions (layout space of the doc view).
    private var currentRealSize: CGSize = .zero
    private var metadataRequestURL: URL?
    private var infoPanelVisible = UserDefaults.standard.bool(forKey: "infoPanelVisible")
    /// Filmstrip defaults to off: hovering the bottom edge reveals it
    /// transiently, the toggle pins it on.
    private var filmstripEnabled: Bool = {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "filmstripEnabled") as? Bool ?? false
    }()
    private var backgroundStyle = BackgroundStyle.load() {
        didSet { backgroundStyle.save() }
    }
    private var keepRotationOnChange =
        UserDefaults.standard.bool(forKey: "keepRotationOnChange")
    private var wrapAround = UserDefaults.standard.bool(forKey: "wrapAround") {
        didSet {
            UserDefaults.standard.set(wrapAround, forKey: "wrapAround")
            navigator.wrapsAround = wrapAround
        }
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = Flick.appName
        // Immersive look: content runs under an invisible titlebar; the
        // traffic lights only appear while chrome is revealed on hover.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 400, height: 300)
        window.center()
        super.init(window: window)

        window.delegate = self
        window.contentView = imageView
        imageView.actionDelegate = self
        imageView.setBackgroundColor(backgroundStyle.color)
        imageView.setInfoPanelVisible(infoPanelVisible)
        imageView.onZoomChanged = { [weak self] in
            self?.considerHighResLoad()
        }
        imageView.setFilmstripEnabled(filmstripEnabled)
        imageView.onFilmstripSelect = { [weak self] index in
            self?.goTo(index)
        }
        imageView.onOpen = { [weak self] in self?.openDocument(nil) }
        imageView.onRotate = { [weak self] delta in self?.rotate(by: delta) }
        imageView.onToggleInfoPanel = { [weak self] in self?.toggleInfoPanel(nil) }
        imageView.onToggleFilmstrip = { [weak self] in self?.toggleFilmstrip(nil) }
        imageView.onTogglePlayback = { [weak self] in self?.toggleAnimationPlayback(nil) }
        window.makeFirstResponder(imageView)
        imageView.setMessage("打开图片或文件夹开始浏览（⌘O），双击空白处或拖入图片")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Opening

    /// Entry point for every open path: open panel, drag & drop, Finder,
    /// command line.
    func open(urls: [URL]) {
        var folders: [URL] = []
        var regularFiles: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }
            if isDirectory.boolValue {
                folders.append(url)
            } else {
                regularFiles.append(url)
            }
        }

        if let folder = folders.first {
            openFolder(folder, selecting: nil)
        } else if regularFiles.count == 1, let file = regularFiles.first {
            openFolder(file.deletingLastPathComponent(), selecting: file)
        } else if !regularFiles.isEmpty {
            openFileList(regularFiles)
        } else {
            showPlaceholder("无法打开：文件不存在")
        }
    }

    private func openFolder(_ folder: URL, selecting file: URL?) {
        guard let scanned = ImageFileScanner.scan(folder: folder), !scanned.isEmpty else {
            showPlaceholder("文件夹中没有可识别的图片：\(folder.lastPathComponent)")
            return
        }
        files = ImageFileScanner.sorted(scanned, by: sortOrder)
        currentFolder = folder
        imageView.setFilmstripFiles(files.map(\.url))
        let target = file?.standardizedFileURL
        let index = target.flatMap { t in
            files.firstIndex { $0.url.standardizedFileURL == t }
        } ?? 0
        navigator.reset(count: files.count, index: index)
        navigator.wrapsAround = wrapAround
        showCurrent()
    }

    private func openFileList(_ urls: [URL]) {
        let images = urls.filter { ImageFileScanner.isImageFile($0) }.map { ImageFile(url: $0) }
        guard !images.isEmpty else {
            showPlaceholder("所选文件中没有可识别的图片")
            return
        }
        files = ImageFileScanner.sorted(images, by: sortOrder)
        currentFolder = nil
        imageView.setFilmstripFiles(files.map(\.url))
        navigator.reset(count: files.count, index: 0)
        navigator.wrapsAround = wrapAround
        showCurrent()
    }

    private func showPlaceholder(_ text: String) {
        files = []
        navigator.reset(count: 0)
        currentFolder = nil
        loadTask?.cancel()
        hiResTask?.cancel()
        baseImage = nil
        isAnimatedContent = false
        imageView.setMessage(text)
        imageView.updateInfoPanel(metadata: nil)
        imageView.setTitleInfo(folder: "", file: "")
        imageView.setStatusIndex(-1, total: 0)
        imageView.setFilmstripFiles([])
        window?.title = Flick.appName
        window?.representedURL = nil
    }

    // MARK: - Current image

    private var currentFile: ImageFile? {
        guard navigator.index >= 0, navigator.index < files.count else { return nil }
        return files[navigator.index]
    }

    /// Display-tier decode cap: enough for fit display on any screen,
    /// full-res loads on demand when the user zooms past it.
    private static let displayCap = 4096

    private func showCurrent() {
        loadTask?.cancel()
        loadTask = nil
        hiResTask?.cancel()
        hiResTask = nil
        hiResLoaded = false

        guard let file = currentFile else {
            baseImage = nil
            isAnimatedContent = false
            imageView.setMessage("没有图片")
            imageView.updateInfoPanel(metadata: nil)
            imageView.setTitleInfo(folder: "", file: "")
            imageView.setStatusIndex(-1, total: 0)
            window?.title = Flick.appName
            window?.representedURL = nil
            return
        }

        if !keepRotationOnChange {
            rotation = 0
        }

        window?.title = "\(file.fileName) — \(navigator.index + 1) / \(files.count)"
        window?.representedURL = file.url
        imageView.setTitleInfo(
            folder: file.url.deletingLastPathComponent().lastPathComponent,
            file: file.fileName
        )
        imageView.setStatusIndex(navigator.index, total: files.count)
        prefetchNeighbors()
        loadMetadata()
        imageView.setFilmstripIndex(navigator.index)

        if let cached = store.cachedImage(for: file.url, maxPixelSize: Self.displayCap) {
            present(loaded: cached)
            return
        }

        imageView.setLoading(true)
        let url = file.url
        loadTask = store.load(url, maxPixelSize: Self.displayCap) { [weak self] result in
            // A newer navigation may have superseded this load.
            guard let self, self.currentFile?.url == url else { return }
            switch result {
            case .success(let loaded):
                self.present(loaded: loaded)
            case .failure(let error):
                self.baseImage = nil
                self.isAnimatedContent = false
                self.imageView.setMessage(error.message)
            }
        }
    }

    /// Routes a decoded payload to the right presentation path.
    private func present(loaded: LoadedImage) {
        currentRealSize = loaded.realSize
        if let animated = loaded.animated {
            isAnimatedContent = true
            baseImage = nil
            hiResLoaded = true // animations always decode at full resolution
            imageView.setAnimated(
                animated,
                displaySize: displaySize(of: loaded.realSize),
                quarterTurns: rotation
            )
            fitWindowToImage()
        } else if let still = loaded.still {
            isAnimatedContent = false
            baseImage = still
            hiResLoaded = !loaded.isDownsampled
            imageView.setImage(
                displayImage(from: still),
                displaySize: displaySize(of: loaded.realSize)
            )
            fitWindowToImage()
            considerHighResLoad()
        }
    }

    /// Sizes the window to the image (Pixea-style): big images shrink to the
    /// screen's visible area, small ones grow only up to a usable minimum.
    /// No-op in full screen or when nothing is loaded.
    private func fitWindowToImage() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let imageSize = displaySize(of: currentRealSize)
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }

        let maxW = visible.width * 0.92
        let maxH = visible.height * 0.92
        let minW: CGFloat = 340
        let minH: CGFloat = 240

        let shrink = min(maxW / imageSize.width, maxH / imageSize.height)
        let growToMin = max(minW / imageSize.width, minH / imageSize.height)
        var scale = min(shrink, 1)
        if scale == 1, growToMin > 1 {
            scale = min(growToMin, shrink)
        }
        var newSize = NSSize(
            width: (imageSize.width * scale).rounded(),
            height: (imageSize.height * scale).rounded()
        )
        // Pathological aspect ratios still get a usable window.
        newSize.width = max(240, min(newSize.width, maxW))
        newSize.height = max(160, min(newSize.height, maxH))

        let old = window.frame
        // Same size → nothing to do (flipping through same-format images).
        guard abs(old.width - newSize.width) > 0.5
                || abs(old.height - newSize.height) > 0.5 else { return }

        var origin = NSPoint(
            x: old.midX - newSize.width / 2,
            y: old.midY - newSize.height / 2
        )
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - newSize.width - 8))
        origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - newSize.height - 8))
        window.setFrame(
            NSRect(origin: origin, size: newSize),
            display: true,
            animate: true
        )
    }

    /// Rotated view size: odd quarter-turns swap width/height.
    private func displaySize(of realSize: CGSize) -> NSSize {
        rotation % 2 == 1
            ? NSSize(width: realSize.height, height: realSize.width)
            : NSSize(width: realSize.width, height: realSize.height)
    }

    /// When the zoom demands more detail than the display tier supplies,
    /// decode the full-resolution image and swap it in place.
    private func considerHighResLoad() {
        guard !hiResLoaded, hiResTask == nil, !isAnimatedContent,
              let url = currentFile?.url,
              let decoded = baseImage,
              currentRealSize.width > 0 else { return }
        let scale = window?.screen?.backingScaleFactor ?? 2
        let mag = imageView.scrollView.magnification
        // Screen needs realW × mag × scale pixels across the doc width;
        // the decoded tier supplies only its own width.
        let demand = currentRealSize.width * mag * scale
        guard demand > CGFloat(decoded.width) * 0.98 else { return }
        hiResTask = store.load(url, maxPixelSize: nil) { [weak self] result in
            guard let self else { return }
            self.hiResTask = nil
            guard case .success(let loaded) = result,
                  self.currentFile?.url == url,
                  let still = loaded.still else { return }
            self.baseImage = still
            self.hiResLoaded = true
            self.imageView.upgradeStill(self.displayImage(from: still))
        }
    }

    private func displayImage(from base: CGImage) -> CGImage {
        ImageRotator.rotate(base, quarterTurns: rotation)
    }

    /// Keeps the immediate neighbours warm so stepping feels instant; loads
    /// falling out of the ±2 window are cancelled.
    private func prefetchNeighbors() {
        var urls = Set<URL>()
        for offset in [-2, -1, 1, 2] {
            let i = navigator.index + offset
            guard i >= 0, i < files.count else { continue }
            urls.insert(files[i].url)
        }
        store.prefetch(urls: urls, maxPixelSize: Self.displayCap)
    }

    private func applySortOrder() {
        guard !files.isEmpty, let current = currentFile else { return }
        files = ImageFileScanner.sorted(files, by: sortOrder)
        let index = files.firstIndex(of: current) ?? 0
        navigator.reset(count: files.count, index: index)
        // Same file, new position: only the counter in the title changes.
        window?.title = "\(current.fileName) — \(index + 1) / \(files.count)"
    }

    // MARK: - Menu actions

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.open(urls: panel.urls)
        }
    }

    @objc func previousImage(_ sender: Any?) { goPrevious() }
    @objc func nextImage(_ sender: Any?) { goNext() }
    @objc func firstImage(_ sender: Any?) { goFirst() }
    @objc func lastImage(_ sender: Any?) { goLast() }

    // MARK: Zoom / rotate / fullscreen / background

    @objc func zoomIn(_ sender: Any?) { imageView.scrollView.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { imageView.scrollView.zoomOut() }
    @objc func zoomToFit(_ sender: Any?) { imageView.scrollView.zoomToFit() }
    @objc func zoomToActualSize(_ sender: Any?) { imageView.scrollView.zoomToActual() }
    @objc func zoomToFill(_ sender: Any?) { imageView.scrollView.zoomToFill() }

    @objc func rotateRight(_ sender: Any?) { rotate(by: 1) }
    @objc func rotateLeft(_ sender: Any?) { rotate(by: -1) }

    private func rotate(by quarterTurns: Int) {
        if isAnimatedContent {
            rotation = (rotation + quarterTurns + 4) % 4
            imageView.updateAnimatedRotation(
                quarterTurns: rotation,
                displaySize: displaySize(of: currentRealSize)
            )
        } else {
            guard let base = baseImage else { return }
            rotation = (rotation + quarterTurns + 4) % 4
            imageView.updateImage(
                displayImage(from: base),
                displaySize: displaySize(of: currentRealSize)
            )
        }
        // Rotated aspect no longer matches the window — refit.
        fitWindowToImage()
    }

    // MARK: - Animation / info panel

    @objc func toggleAnimationPlayback(_ sender: Any?) {
        imageView.scrollView.toggleAnimationPause()
    }

    @objc func toggleInfoPanel(_ sender: Any?) {
        infoPanelVisible.toggle()
        UserDefaults.standard.set(infoPanelVisible, forKey: "infoPanelVisible")
        imageView.setInfoPanelVisible(infoPanelVisible)
        loadMetadata()
    }

    @objc func toggleFilmstrip(_ sender: Any?) {
        filmstripEnabled.toggle()
        UserDefaults.standard.set(filmstripEnabled, forKey: "filmstripEnabled")
        imageView.setFilmstripEnabled(filmstripEnabled)
    }

    /// Metadata feeds both the info panel and the status strip, so it loads
    /// off the main thread for every image, panel open or not.
    private func loadMetadata() {
        let url = currentFile?.url
        metadataRequestURL = url
        guard let url else {
            imageView.updateInfoPanel(metadata: nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let metadata = ImageMetadataReader.read(url: url)
            DispatchQueue.main.async {
                guard self?.metadataRequestURL == url else { return }
                self?.imageView.updateInfoPanel(metadata: metadata)
            }
        }
    }

    @objc func toggleKeepRotation(_ sender: NSMenuItem) {
        keepRotationOnChange.toggle()
        UserDefaults.standard.set(keepRotationOnChange, forKey: "keepRotationOnChange")
    }

    @objc func toggleWrapAround(_ sender: NSMenuItem) {
        wrapAround.toggle()
    }

    @objc func toggleFullScreen(_ sender: Any?) {
        window?.toggleFullScreen(nil)
    }

    @objc func setBackground(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = BackgroundStyle(rawValue: raw) else { return }
        backgroundStyle = style
        imageView.setBackgroundColor(style.color)
    }

    @objc func setSortKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let key = ImageSortKey(rawValue: raw), key != sortOrder.key else { return }
        sortOrder.key = key
        applySortOrder()
    }

    @objc func setSortAscending(_ sender: NSMenuItem) {
        guard let ascending = sender.representedObject as? Bool,
              ascending != sortOrder.ascending else { return }
        sortOrder.ascending = ascending
        applySortOrder()
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let file = currentFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    @objc func copyImage(_ sender: Any?) {
        guard let file = currentFile else { return }
        if let image = NSImage(contentsOf: file.url) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
    }

    @objc func copyFilePath(_ sender: Any?) {
        guard let file = currentFile else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.url.path, forType: .string)
    }

    @objc func showHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "\(Flick.appName) 使用帮助"
        alert.informativeText = """
        打开：⌘O 选择图片或文件夹，或直接拖拽到窗口 / Dock 图标
        翻页：← / →、空格（下一张）、⇧空格（上一张）、Home / End，或双指水平滑动
        缩放：⌘+ / ⌘-、⌘0 适应、⌘1 实际大小、⌘2 填满、捏合、双击
        旋转：⌘R 顺时针、⇧⌘R 逆时针；全屏：F 或 ⌃⌘F
        动图：P 暂停 / 继续；信息面板：⌘I；缩略图条：T
        排序：显示菜单 > 排序方式
        打开单张图片时自动浏览其所在文件夹的所有图片。
        """
        alert.runModal()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(nextImage(_:)):
            return navigator.canGoNext
        case #selector(previousImage(_:)):
            return navigator.canGoPrevious
        case #selector(firstImage(_:)), #selector(lastImage(_:)):
            return !navigator.isEmpty
        case #selector(setSortKey(_:)):
            menuItem.state = (menuItem.representedObject as? String) == sortOrder.key.rawValue ? .on : .off
            return true
        case #selector(setSortAscending(_:)):
            menuItem.state = (menuItem.representedObject as? Bool) == sortOrder.ascending ? .on : .off
            return true
        case #selector(revealInFinder(_:)), #selector(copyImage(_:)), #selector(copyFilePath(_:)):
            return currentFile != nil
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)),
             #selector(zoomToFit(_:)), #selector(zoomToActualSize(_:)),
             #selector(zoomToFill(_:)),
             #selector(rotateRight(_:)), #selector(rotateLeft(_:)):
            return baseImage != nil || isAnimatedContent
        case #selector(toggleAnimationPlayback(_:)):
            menuItem.title = imageView.scrollView.isAnimationPaused ? "播放动画" : "暂停动画"
            return isAnimatedContent
        case #selector(toggleInfoPanel(_:)):
            menuItem.state = infoPanelVisible ? .on : .off
            return true
        case #selector(toggleFilmstrip(_:)):
            menuItem.state = filmstripEnabled ? .on : .off
            return true
        case #selector(toggleKeepRotation(_:)):
            menuItem.state = keepRotationOnChange ? .on : .off
            return true
        case #selector(toggleWrapAround(_:)):
            menuItem.state = wrapAround ? .on : .off
            return true
        case #selector(setBackground(_:)):
            menuItem.state = (menuItem.representedObject as? String) == backgroundStyle.rawValue ? .on : .off
            return true
        case #selector(toggleFullScreen(_:)):
            let fullScreen = window?.styleMask.contains(.fullScreen) == true
            menuItem.title = fullScreen ? "退出全屏" : "进入全屏"
            return true
        default:
            return true
        }
    }

    // MARK: - Navigation

    private func goNext() {
        if navigator.goNext() { showCurrent() }
    }

    private func goPrevious() {
        if navigator.goPrevious() { showCurrent() }
    }

    private func goFirst() {
        if navigator.goFirst() { showCurrent() }
    }

    private func goLast() {
        if navigator.goLast() { showCurrent() }
    }

    private func goTo(_ index: Int) {
        if navigator.goTo(index) { showCurrent() }
    }

    // MARK: - Swipe page turns

    /// Animated turn triggered by the trackpad swipe tracker. The navigator
    /// advances synchronously (so rapid swipes stay consistent); the slide
    /// animation is drawn on top of the swap.
    private func turnPage(_ direction: SwipeTracker.Direction) {
        let outgoing = baseImage.map(displayImage(from:))
        let moved = direction == .next ? navigator.goNext() : navigator.goPrevious()
        guard moved else {
            // Shouldn't happen — the tracker already suppresses disallowed
            // turns — but snap back defensively.
            imageView.scrollViewDidSettle(imageView.scrollView)
            return
        }
        let incoming = currentFile
            .flatMap { store.cachedImage(for: $0.url, maxPixelSize: Self.displayCap) }
            .flatMap { $0.still ?? $0.animated?.frames.first }
            .map(displayImage(from:))
        imageView.commitPageTurn(direction: direction, outgoing: outgoing, incoming: incoming)
        showCurrent()
    }
}

extension MainWindowController: ImageViewActionDelegate {
    func imageViewDidRequestNext(_ view: ImageView) { goNext() }
    func imageViewDidRequestPrevious(_ view: ImageView) { goPrevious() }
    func imageViewDidRequestFirst(_ view: ImageView) { goFirst() }
    func imageViewDidRequestLast(_ view: ImageView) { goLast() }

    func imageViewCanTurn(_ view: ImageView, direction: SwipeTracker.Direction) -> Bool {
        direction == .next ? navigator.canGoNext : navigator.canGoPrevious
    }

    func imageViewDidRequestSwipeTurn(_ view: ImageView, direction: SwipeTracker.Direction) {
        turnPage(direction)
    }

    func imageViewDidRequestToggleFullScreen(_ view: ImageView) {
        window?.toggleFullScreen(nil)
    }

    func imageViewDidRequestExitFullScreen(_ view: ImageView) {
        if window?.styleMask.contains(.fullScreen) == true {
            window?.toggleFullScreen(nil)
        }
    }

    func imageView(_ view: ImageView, didReceiveDroppedURLs urls: [URL]) {
        open(urls: urls)
    }
}

extension MainWindowController: NSWindowDelegate {
    func windowDidEnterFullScreen(_ notification: Notification) {
        imageView.setFullScreen(true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        imageView.setFullScreen(false)
    }
}
