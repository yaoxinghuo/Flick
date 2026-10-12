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
        let loaded = try ImageStore.decode(url: url)
        #expect(loaded.still?.width == 48)
        #expect(loaded.still?.height == 48)
        #expect(loaded.realSize == CGSize(width: 48, height: 48))
        #expect(loaded.animated == nil)
        #expect(loaded.isDownsampled == false)
    }

    @Test func downsamplesWhenMaxPixelSizeGiven() throws {
        let url = try makePNG(size: 400)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try ImageStore.decode(url: url, maxPixelSize: 100)
        let still = try #require(loaded.still)
        #expect(max(still.width, still.height) <= 100)
        #expect(loaded.realSize == CGSize(width: 400, height: 400))
        #expect(loaded.isDownsampled == true)
    }

    /// Generates a 2-frame animated GIF (frames drawn as distinct colors).
    private func makeGIF(frames: Int = 2, size: Int = 16, delay: Double = 0.1) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flick-test-\(UUID().uuidString).gif")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "com.compuserve.gif" as CFString, frames, nil
        ) else {
            Issue.record("could not create gif destination")
            throw NSError(domain: "test", code: 1)
        }
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
            ],
        ] as CFDictionary
        for index in 0..<frames {
            let context = CGContext(
                data: nil, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
            context?.setFillColor(
                red: CGFloat(index) / max(CGFloat(frames - 1), 1),
                green: 0, blue: 0, alpha: 1
            )
            context?.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let image = try #require(context?.makeImage())
            CGImageDestinationAddImage(destination, image, frameProperties)
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func decodesAnimatedGIF() throws {
        let url = try makeGIF(frames: 3, delay: 0.15)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try ImageStore.decode(url: url)
        let animated = try #require(loaded.animated)
        #expect(animated.frameCount == 3)
        #expect(loaded.still == nil)
        for delay in animated.delays {
            #expect(delay == 0.15)
        }
        #expect(abs(animated.duration - 0.45) < 0.01)
        #expect(animated.keyTimes.last?.doubleValue == 1.0)
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
