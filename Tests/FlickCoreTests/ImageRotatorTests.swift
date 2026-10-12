import CoreGraphics
import Foundation
import Testing
@testable import FlickCore

struct ImageRotatorTests {

    /// Builds a 2×1 image: left pixel red, right pixel blue.
    private func makeTwoPixelImage() throws -> CGImage {
        // RGBA bytes: red, blue
        var data = Data([255, 0, 0, 255, 0, 0, 255, 255])
        let image = data.withUnsafeMutableBytes { ptr -> CGImage? in
            CGContext(
                data: ptr.baseAddress, width: 2, height: 1,
                bitsPerComponent: 8, bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        return try #require(image)
    }

    /// Returns the RGBA components of the pixel at (x, y); rows may be padded,
    /// so stride is taken from `image.bytesPerRow`.
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let info = try #require(image.dataProvider?.data)
        let base = CFDataGetBytePtr(info)!
        let offset = y * image.bytesPerRow + x * 4
        return (base[offset], base[offset + 1], base[offset + 2])
    }

    @Test func zeroTurnsReturnsSameImage() throws {
        let image = try makeTwoPixelImage()
        let rotated = ImageRotator.rotate(image, quarterTurns: 0)
        #expect(rotated === image)
    }

    @Test func quarterTurnSwapsDimensions() throws {
        let image = try makeTwoPixelImage()
        let rotated = ImageRotator.rotate(image, quarterTurns: 1)
        #expect(rotated.width == image.height)
        #expect(rotated.height == image.width)
        let twice = ImageRotator.rotate(rotated, quarterTurns: 1)
        #expect(twice.width == image.width)
        #expect(twice.height == image.height)
    }

    @Test func clockwiseMovesLeftColumnToTop() throws {
        let rotated = ImageRotator.rotate(try makeTwoPixelImage(), quarterTurns: 1)
        // Clockwise: source left column (red) -> top row, right (blue) -> bottom.
        #expect(try pixel(rotated, x: 0, y: 0) == (255, 0, 0))
        #expect(try pixel(rotated, x: 0, y: 1) == (0, 0, 255))
    }

    @Test func counterClockwiseMovesRightColumnToTop() throws {
        let rotated = ImageRotator.rotate(try makeTwoPixelImage(), quarterTurns: 3)
        #expect(try pixel(rotated, x: 0, y: 0) == (0, 0, 255))
        #expect(try pixel(rotated, x: 0, y: 1) == (255, 0, 0))
    }

    @Test func negativeTurnsNormalize() throws {
        let image = try makeTwoPixelImage()
        let rotated = ImageRotator.rotate(image, quarterTurns: -1)
        #expect(rotated.width == image.height)
    }
}
