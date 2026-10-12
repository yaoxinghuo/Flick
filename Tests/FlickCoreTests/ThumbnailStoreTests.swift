import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import FlickCore

struct ThumbnailStoreTests {

    private func makePNG(width: Int = 200, height: Int = 100) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flick-thumb-\(UUID().uuidString).png")
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context?.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func decodeCapsLongestSideAndKeepsAspect() throws {
        let url = try makePNG(width: 200, height: 100)
        defer { try? FileManager.default.removeItem(at: url) }
        let thumb = try #require(ThumbnailStore.decode(url: url, maxPixelSize: 50))
        #expect(thumb.width == 50)
        #expect(thumb.height == 25)
    }

    @Test func asyncRequestDeliversThumbnail() async throws {
        let url = try makePNG()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ThumbnailStore(maxPixelSize: 64)
        let image = await withCheckedContinuation { continuation in
            store.request(url) { continuation.resume(returning: $0) }
        }
        #expect(image != nil)
        #expect(max(image?.width ?? 0, image?.height ?? 0) <= 64)
    }

    @Test func cachedThumbnailServesSecondLookup() async throws {
        let url = try makePNG()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ThumbnailStore(maxPixelSize: 64)
        _ = await withCheckedContinuation { continuation in
            store.request(url) { continuation.resume(returning: $0) }
        }
        #expect(store.cachedThumbnail(for: url) != nil)
    }

    @Test func cancelledRequestDoesNotDeliver() async throws {
        let url = try makePNG()
        defer { try? FileManager.default.removeItem(at: url) }
        // Same-URL requests share one decode; cancelling one token drops only
        // its own callback, so this never races the decode itself.
        let store = ThumbnailStore(maxPixelSize: 64)
        var delivered = false
        let token = store.request(url) { _ in delivered = true }
        token.cancel()
        _ = await withCheckedContinuation { continuation in
            store.request(url) { _ in continuation.resume() }
        }
        #expect(delivered == false)
    }

    @Test func corruptFileYieldsNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flick-badthumb-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0xDE, 0xAD]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ThumbnailStore.decode(url: url, maxPixelSize: 64) == nil)
    }
}
