import AppKit
import PeekCore

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

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Peek.appName
        window.minSize = NSSize(width: 400, height: 300)
        window.center()
        super.init(window: window)

        window.contentView = imageView
        imageView.actionDelegate = self
        window.makeFirstResponder(imageView)
        imageView.setMessage("打开图片或文件夹开始浏览（⌘O），或将图片拖入窗口")
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
        let target = file?.standardizedFileURL
        let index = target.flatMap { t in
            files.firstIndex { $0.url.standardizedFileURL == t }
        } ?? 0
        navigator.reset(count: files.count, index: index)
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
        navigator.reset(count: files.count, index: 0)
        showCurrent()
    }

    private func showPlaceholder(_ text: String) {
        files = []
        navigator.reset(count: 0)
        currentFolder = nil
        loadTask?.cancel()
        imageView.setMessage(text)
        window?.title = Peek.appName
        window?.representedURL = nil
    }

    // MARK: - Current image

    private var currentFile: ImageFile? {
        guard navigator.index >= 0, navigator.index < files.count else { return nil }
        return files[navigator.index]
    }

    private func showCurrent() {
        loadTask?.cancel()
        loadTask = nil

        guard let file = currentFile else {
            imageView.setMessage("没有图片")
            window?.title = Peek.appName
            window?.representedURL = nil
            return
        }

        window?.title = "\(file.fileName) — \(navigator.index + 1) / \(files.count)"
        window?.representedURL = file.url
        prefetchNeighbors()

        if let cached = store.cachedImage(for: file.url) {
            imageView.setImage(cached)
            return
        }

        imageView.setLoading(true)
        let url = file.url
        loadTask = store.load(url) { [weak self] result in
            // A newer navigation may have superseded this load.
            guard let self, self.currentFile?.url == url else { return }
            switch result {
            case .success(let image):
                self.imageView.setImage(image)
            case .failure(let error):
                self.imageView.setMessage(error.message)
            }
        }
    }

    /// Keeps the immediate neighbours warm so stepping feels instant.
    private func prefetchNeighbors() {
        for offset in [-2, -1, 1, 2] {
            let i = navigator.index + offset
            guard i >= 0, i < files.count else { continue }
            store.prefetch(files[i].url)
        }
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
        alert.messageText = "\(Peek.appName) 使用帮助"
        alert.informativeText = """
        打开：⌘O 选择图片或文件夹，或直接拖拽到窗口 / Dock 图标
        翻页：← / →、空格（下一张）、⇧空格（上一张）、Home / End
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
}

extension MainWindowController: ImageViewActionDelegate {
    func imageViewDidRequestNext(_ view: ImageView) { goNext() }
    func imageViewDidRequestPrevious(_ view: ImageView) { goPrevious() }
    func imageViewDidRequestFirst(_ view: ImageView) { goFirst() }
    func imageViewDidRequestLast(_ view: ImageView) { goLast() }
    func imageView(_ view: ImageView, didReceiveDroppedURLs urls: [URL]) {
        open(urls: urls)
    }
}
