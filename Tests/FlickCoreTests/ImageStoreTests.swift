import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import FlickCore

struct ImageStoreTests {

    /// Generates a small PNG on the fly (no binary fixtures committed).
    private func makePNG(size: Int = 64) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flick-test-\(UUID().uuidString).png")
        let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let image = try #require(context?.makeImage())
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ) else {
            Issue.record("could not create image destination")
            throw NSError(domain: "test", code: 1)
        }
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func decodesGeneratedPNG() throws {
        let url = try makePNG(size: 48)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try ImageStore.decode(url: url)
        #expect(image.width == 48)
        #expect(image.height == 48)
    }

    @Test func downsamplesWhenMaxPixelSizeGiven() throws {
        let url = try makePNG(size: 400)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try ImageStore.decode(url: url, maxPixelSize: 100)
        #expect(max(image.width, image.height) <= 100)
    }

    @Test func missingFileThrows() {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).png")
        #expect(throws: ImageLoadError.self) {
            try ImageStore.decode(url: url)
        }
    }

    @Test func corruptFileThrowsDecodeError() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flick-corrupt-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0xDE, 0xAD]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ImageLoadError.self) {
            try ImageStore.decode(url: url)
        }
    }
}
