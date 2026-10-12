import CoreGraphics
import Foundation
import ImageIO

public enum ImageLoadError: Error, Equatable {
    case cannotOpen(String)   // file path
    case cannotDecode(String) // file path

    public var message: String {
        switch self {
        case .cannotOpen(let path): return "无法打开文件：\(path)"
        case .cannotDecode(let path): return "无法解码图片：\(path)"
        }
    }
}

/// Handle for an in-flight load; `cancel()` is cheap and safe to call repeatedly.
public final class ImageLoadTask {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Decodes images off the main thread with a bounded in-memory cache.
/// Completions are delivered on the main queue.
public final class ImageStore {
    private let cache = NSCache<NSURL, CGImage>()
    private let queue = DispatchQueue(
        label: "flick.imagestore",
        qos: .userInitiated,
        attributes: .concurrent
    )
    /// In-flight prefetch loads keyed by URL; main-thread only.
    private var prefetchTasks: [URL: ImageLoadTask] = [:]

    public init(cacheCountLimit: Int = 12) {
        cache.countLimit = cacheCountLimit
        cache.totalCostLimit = 512 * 1024 * 1024 // ~512MB of pixels
    }

    /// Synchronous cache lookup only — never touches disk.
    public func cachedImage(for url: URL) -> CGImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Loads (and caches) the decoded image. `maxPixelSize` bounds the decoded
    /// size for very large files; `nil` decodes at full resolution.
    @discardableResult
    public func load(
        _ url: URL,
        maxPixelSize: Int? = nil,
        completion: @escaping (Result<CGImage, ImageLoadError>) -> Void
    ) -> ImageLoadTask {
        if let cached = cachedImage(for: url) {
            completion(.success(cached))
            return ImageLoadTask()
        }
        let task = ImageLoadTask()
        queue.async { [cache] in
            guard !task.isCancelled else { return }
            let result: Result<CGImage, ImageLoadError>
            do {
                let image = try Self.decode(url: url, maxPixelSize: maxPixelSize)
                cache.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
                result = .success(image)
            } catch let error as ImageLoadError {
                result = .failure(error)
            } catch {
                result = .failure(.cannotDecode(url.path))
            }
            DispatchQueue.main.async {
                guard !task.isCancelled else { return }
                completion(result)
            }
        }
        return task
    }

    /// Keeps exactly `urls` prefetched: starts loads for URLs not yet cached
    /// or in-flight, and cancels tasks for URLs that fell out of the window.
    /// Main-thread only.
    public func prefetch(urls: Set<URL>) {
        for (url, task) in prefetchTasks where !urls.contains(url) {
            task.cancel()
            prefetchTasks.removeValue(forKey: url)
        }
        for url in urls where cachedImage(for: url) == nil && prefetchTasks[url] == nil {
            prefetchTasks[url] = load(url) { [weak self] _ in
                self?.prefetchTasks.removeValue(forKey: url)
            }
        }
    }

    /// Decodes via ImageIO. `kCGImageSourceCreateThumbnailWithTransform` applies
    /// EXIF orientation so the returned pixels are already upright.
    public static func decode(url: URL, maxPixelSize: Int? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageLoadError.cannotOpen(url.path)
        }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxPixelSize {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageLoadError.cannotDecode(url.path)
        }
        return image
    }
}
