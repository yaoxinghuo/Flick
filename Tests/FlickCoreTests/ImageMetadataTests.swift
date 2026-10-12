import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import FlickCore

struct ImageMetadataTests {

    /// Writes a small JPEG carrying EXIF/TIFF/GPS dictionaries — no fixtures.
    private func makeJPEGWithMetadata() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flick-exif-\(UUID().uuidString).jpg")
        let context = CGContext(
            data: nil, width: 64, height: 48,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        let image = try #require(context?.makeImage())
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        ) else {
            Issue.record("could not create jpeg destination")
            throw NSError(domain: "test", code: 1)
        }
        let properties = [
            kCGImagePropertyPixelWidth: 64,
            kCGImagePropertyPixelHeight: 48,
            kCGImagePropertyDPIWidth: 300.0,
            kCGImagePropertyDPIHeight: 300.0,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Canon",
                kCGImagePropertyTIFFModel: "EOS R5",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "RF 35mm F1.8",
                kCGImagePropertyExifFocalLength: 35.0,
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifExposureTime: 0.004,
                kCGImagePropertyExifISOSpeedRatings: [200],
                kCGImagePropertyExifDateTimeOriginal: "2024:01:02 10:30:00",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 31.2304,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 121.4737,
                kCGImagePropertyGPSLongitudeRef: "E",
            ],
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func allFields(_ metadata: ImageMetadata) -> [ImageMetadata.Field] {
        metadata.sections.flatMap { $0.fields }
    }

    @Test func fileSectionAlwaysPresent() throws {
        let url = try makeJPEGWithMetadata()
        defer { try? FileManager.default.removeItem(at: url) }
        let metadata = ImageMetadataReader.read(url: url)
        let fileSection = metadata.sections.first { $0.title == "文件" }
        let fields = fileSection?.fields.map { $0.label } ?? []
        #expect(fields.contains("文件名"))
        #expect(fields.contains("完整路径"))
        #expect(fields.contains("大小"))
        #expect(fields.contains("创建时间"))
        #expect(fields.contains("修改时间"))
    }

    @Test func imageSectionReadsDimensionsAndDPI() throws {
        let url = try makeJPEGWithMetadata()
        defer { try? FileManager.default.removeItem(at: url) }
        let fields = allFields(ImageMetadataReader.read(url: url))
        #expect(fields.contains { $0.label == "尺寸" && $0.value.contains("64 × 48") })
        #expect(fields.contains { $0.label == "DPI" && $0.value.contains("300") })
        #expect(fields.contains { $0.label == "格式" })
    }

    @Test func exifSectionReadsCameraAndExposure() throws {
        let url = try makeJPEGWithMetadata()
        defer { try? FileManager.default.removeItem(at: url) }
        let fields = allFields(ImageMetadataReader.read(url: url))
        #expect(fields.contains { $0.label == "相机" && $0.value == "Canon EOS R5" })
        #expect(fields.contains { $0.label == "镜头" && $0.value.contains("35mm") })
        #expect(fields.contains { $0.label == "焦距" && $0.value == "35 mm" })
        #expect(fields.contains { $0.label == "光圈" && $0.value == "f/2.8" })
        #expect(fields.contains { $0.label == "快门" && $0.value == "1/250 秒" })
        #expect(fields.contains { $0.label == "ISO" && $0.value == "200" })
        #expect(fields.contains { $0.label == "拍摄时间" })
        #expect(fields.contains { $0.label == "GPS" && $0.value.contains("31.2304° N") })
    }

    @Test func missingEXIFOmitsSection() throws {
        // Plain PNG without any EXIF — section must be absent, not "N/A".
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flick-plain-\(UUID().uuidString).png")
        let context = CGContext(
            data: nil, width: 8, height: 8,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        let image = try #require(context?.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = ImageMetadataReader.read(url: url)
        #expect(metadata.sections.allSatisfy { $0.title != "拍摄信息" })
    }
}
