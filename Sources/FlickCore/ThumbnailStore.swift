import CoreGraphics
import Foundation
import ImageIO

/// Handle for an in-flight thumbnail request; cancelling is cheap and drops
/// only this caller's callback (other waiters for the same URL survive).
public final class ThumbnailRequest {
    fileprivate let id = UUID()
    fileprivate let url: URL
    fileprivate weak var store: ThumbnailStore?

    fileprivate init(url: URL, store: ThumbnailStore) {
        self.url = url
        self.store = store
    }

    public func cancel() {
        store?.cancel(url: url, requestID: id)
    }
}

private final class ThumbnailBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Generates filmstrip thumbnails via `CGImageSourceCreateThumbnailAtIndex`,
/// capped at `maxPixelSize`. At most `concurrency` decodes run at once; results
/// are memory-cached and completions always fire on the main queue.
public final class ThumbnailStore {
    private let maxPixelSize: Int
    private let cache = NSCache<NSURL, ThumbnailBox>()
    private let queue = OperationQueue()
    private let lock = NSLock()
    /// Per-URL waiters; the first request creates the decode operation.
    private var pending: [URL: [(id: UUID, done: (CGImage?) -> Void)]] = [:]
    private var operations: [URL: Operation] = [:]

    public init(maxPixelSize: Int = 160, concurrency: Int = 4, cacheCountLimit: Int = 600) {
        self.maxPixelSize = maxPixelSize
        queue.maxConcurrentOperationCount = concurrency
        queue.qualityOfService = .userInitiated
        cache.countLimit = cacheCountLimit
        cache.totalCostLimit = 96 * 1024 * 1024 // ~96MB of tiny pixels
    }

    /// Async thumbnail lookup; `nil` on decode failure. Call on any thread.
    @discardableResult
    public func request(_ url: URL, completion: @escaping (CGImage?) -> Void) -> ThumbnailRequest {
        let token = ThumbnailRequest(url: url, store: self)

        if let cached = cache.object(forKey: url as NSURL) {
            DispatchQueue.main.async { completion(cached.image) }
            return token
        }

        lock.lock()
        if pending[url] != nil {
            pending[url]?.append((token.id, completion))
            lock.unlock()
            return token
        }
        pending[url] = [(token.id, completion)]
        let operation = BlockOperation { [weak self] in
            guard let self else { return }
            let image = Self.decode(url: url, maxPixelSize: self.maxPixelSize)
            self.finish(url: url, image: image)
        }
        operations[url] = operation
        queue.addOperation(operation)
        lock.unlock()
        return token
    }

    /// Synchronous cache lookup — for callers that want to avoid a flicker
    /// when the thumbnail is already warm.
    public func cachedThumbnail(for url: URL) -> CGImage? {
        cache.object(forKey: url as NSURL)?.image
    }

    fileprivate func cancel(url: URL, requestID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        pending[url]?.removeAll { $0.id == requestID }
        if pending[url]?.isEmpty == true {
            pending.removeValue(forKey: url)
            operations[url]?.cancel()
            operations.removeValue(forKey: url)
        }
    }

    private func finish(url: URL, image: CGImage?) {
        lock.lock()
        operations.removeValue(forKey: url)
        let callbacks = pending.removeValue(forKey: url) ?? []
        lock.unlock()
        if let image {
            cache.setObject(
                ThumbnailBox(image), forKey: url as NSURL,
                cost: image.bytesPerRow * image.height
            )
        }
        DispatchQueue.main.async {
            callbacks.forEach { $0.done(image) }
        }
    }

    /// Downsampled decode of the first frame; EXIF orientation applied.
    public static func decode(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
