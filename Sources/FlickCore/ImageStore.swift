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

/// One decode result: either a still image (possibly downsampled) or a fully
/// decoded animation. `realSize` is always the source's true pixel dimensions,
/// so UI layout never depends on which decode tier was used.
public struct LoadedImage {
    public let realSize: CGSize
    public let still: CGImage?
    public let animated: AnimatedImage?

    /// True when the still was decoded below `realSize` to save memory.
    public var isDownsampled: Bool {
        guard let still else { return false }
        return still.width < Int(realSize.width) || still.height < Int(realSize.height)
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

/// NSCache needs a class; wraps the value-type payload.
private final class CachedLoadedImage {
    let value: LoadedImage
    init(_ value: LoadedImage) { self.value = value }
}

/// Decodes images off the main thread with a bounded in-memory cache.
/// Completions are delivered on the main queue.
public final class ImageStore {
    private let cache = NSCache<NSString, CachedLoadedImage>()
    private let queue = DispatchQueue(
        label: "flick.imagestore",
        qos: .userInitiated,
        attributes: .concurrent
    )
    /// In-flight prefetch loads keyed by cache key; main-thread only.
    private var prefetchTasks: [String: ImageLoadTask] = [:]

    public init(cacheCountLimit: Int = 12) {
        cache.countLimit = cacheCountLimit
        cache.totalCostLimit = 512 * 1024 * 1024 // ~512MB of pixels
    }

    private static func cacheKey(for url: URL, maxPixelSize: Int?) -> String {
        "\(url.absoluteString)#\(maxPixelSize ?? 0)"
    }

    /// Synchronous cache lookup only — never touches disk.
    public func cachedImage(for url: URL, maxPixelSize: Int? = nil) -> LoadedImage? {
        cache.object(forKey: Self.cacheKey(for: url, maxPixelSize: maxPixelSize) as NSString)?.value
    }

    /// Loads (and caches) the decoded image. `maxPixelSize` bounds the decoded
    /// still size for very large files; `nil` decodes at full resolution.
    /// Animated sources are always decoded at full resolution.
    @discardableResult
    public func load(
        _ url: URL,
        maxPixelSize: Int? = nil,
        completion: @escaping (Result<LoadedImage, ImageLoadError>) -> Void
    ) -> ImageLoadTask {
        let key = Self.cacheKey(for: url, maxPixelSize: maxPixelSize)
        if let cached = cache.object(forKey: key as NSString) {
            completion(.success(cached.value))
            return ImageLoadTask()
        }
        let task = ImageLoadTask()
        queue.async { [cache] in
            guard !task.isCancelled else { return }
            let result: Result<LoadedImage, ImageLoadError>
            do {
                let loaded = try Self.decode(url: url, maxPixelSize: maxPixelSize)
                var cost = 0
                if let still = loaded.still {
                    cost = still.bytesPerRow * still.height
                } else if let animated = loaded.animated {
                    cost = animated.frames.reduce(0) { $0 + $1.bytesPerRow * $1.height }
                }
                cache.setObject(CachedLoadedImage(loaded), forKey: key as NSString, cost: cost)
                result = .success(loaded)
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

    /// Keeps exactly `urls` prefetched (display tier): starts loads for URLs
    /// not yet cached or in-flight, cancels tasks that fell out of the window.
    /// Main-thread only.
    public func prefetch(urls: Set<URL>, maxPixelSize: Int? = nil) {
        let wanted = Set(urls.map { Self.cacheKey(for: $0, maxPixelSize: maxPixelSize) })
        for (key, task) in prefetchTasks where !wanted.contains(key) {
            task.cancel()
            prefetchTasks.removeValue(forKey: key)
        }
        var urlsByKey: [String: URL] = [:]
        for url in urls {
            urlsByKey[Self.cacheKey(for: url, maxPixelSize: maxPixelSize)] = url
        }
        for (key, url) in urlsByKey
        where cache.object(forKey: key as NSString) == nil && prefetchTasks[key] == nil {
            prefetchTasks[key] = load(url, maxPixelSize: maxPixelSize) { [weak self] _ in
                self?.prefetchTasks.removeValue(forKey: key)
            }
        }
    }

    /// Reads only the source's pixel dimensions — no decode.
    public static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    /// Decodes via ImageIO. `kCGImageSourceCreateThumbnailWithTransform` applies
    /// EXIF orientation so the returned pixels are already upright.
    /// `maxPixelSize` downsamples stills larger than that bound; `nil` = full res.
    public static func decode(url: URL, maxPixelSize: Int? = nil) throws -> LoadedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageLoadError.cannotOpen(url.path)
        }

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var realSize = CGSize.zero
        if let width = props?[kCGImagePropertyPixelWidth] as? Int,
           let height = props?[kCGImagePropertyPixelHeight] as? Int {
            realSize = CGSize(width: width, height: height)
        }

        if let animated = AnimatedImageDecoder.decode(source: source) {
            if realSize == .zero { realSize = animated.size }
            return LoadedImage(realSize: realSize, still: nil, animated: animated)
        }

        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let cap = maxPixelSize
        if let cap, realSize != .zero,
           max(realSize.width, realSize.height) > CGFloat(cap) {
            options[kCGImageSourceThumbnailMaxPixelSize] = cap
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageLoadError.cannotDecode(url.path)
        }
        if realSize == .zero {
            realSize = CGSize(width: image.width, height: image.height)
        }
        return LoadedImage(realSize: realSize, still: image, animated: nil)
    }
}
