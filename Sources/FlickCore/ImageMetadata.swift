import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Grouped, already-formatted metadata for the info panel. Missing values are
/// omitted entirely rather than shown as placeholders.
public struct ImageMetadata: Equatable {
    public struct Field: Equatable {
        public let label: String
        public let value: String
        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public struct Section: Equatable {
        public let title: String
        public let fields: [Field]
        public init(_ title: String, _ fields: [Field]) {
            self.title = title
            self.fields = fields
        }
    }

    public let sections: [Section]

    /// Compact values for the status strip (nil when unavailable).
    public let pixelSizeText: String?   // "413 × 626"
    public let dpiText: String?         // "300dpi"
    public let fileSizeText: String?    // "395 KB"
    public let createdText: String?     // localized date

    public init(
        sections: [Section],
        pixelSizeText: String? = nil,
        dpiText: String? = nil,
        fileSizeText: String? = nil,
        createdText: String? = nil
    ) {
        self.sections = sections
        self.pixelSizeText = pixelSizeText
        self.dpiText = dpiText
        self.fileSizeText = fileSizeText
        self.createdText = createdText
    }
}

/// Reads file attributes + ImageIO properties + EXIF/TIFF/GPS dictionaries.
/// Pure data extraction, no UI — safe to call off the main thread.
public enum ImageMetadataReader {

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    public static func read(url: URL) -> ImageMetadata {
        var sections: [ImageMetadata.Section] = []

        if let file = fileSection(url: url) {
            sections.append(file)
        }
        if let image = imageSection(url: url) {
            sections.append(image)
        }
        if let exif = exifSection(url: url) {
            sections.append(exif)
        }
        return ImageMetadata(
            sections: sections,
            pixelSizeText: pixelSizeText(url: url),
            dpiText: dpiText(url: url),
            fileSizeText: fileSizeText(url: url),
            createdText: createdText(url: url)
        )
    }

    // MARK: - Status-strip values

    private static func imageProperties(url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }

    private static func pixelSizeText(url: URL) -> String? {
        guard let props = imageProperties(url: url),
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(w) × \(h)"
    }

    private static func dpiText(url: URL) -> String? {
        guard let props = imageProperties(url: url),
              let dpi = props[kCGImagePropertyDPIWidth] as? Double else { return nil }
        return "\(Int(dpi))dpi"
    }

    private static func fileSizeText(url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private static let compactDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static func createdText(url: URL) -> String? {
        guard let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else {
            return nil
        }
        return L10n.s("Created ", "创建于 ") + compactDateFormatter.string(from: date)
    }

    // MARK: - File section

    private static func fileSection(url: URL) -> ImageMetadata.Section? {
        let values = try? url.resourceValues(forKeys: [
            .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        ])
        var fields: [ImageMetadata.Field] = [
            .init(L10n.s("Name", "文件名"), url.lastPathComponent),
            .init(L10n.s("Path", "完整路径"), url.path),
        ]
        if let size = values?.fileSize {
            fields.append(.init(L10n.s("Size", "大小"), ByteCountFormatter.string(
                fromByteCount: Int64(size), countStyle: .file
            )))
        }
        if let created = values?.creationDate {
            fields.append(.init(L10n.s("Created", "创建时间"), dateFormatter.string(from: created)))
        }
        if let modified = values?.contentModificationDate {
            fields.append(.init(L10n.s("Modified", "修改时间"), dateFormatter.string(from: modified)))
        }
        return .init(L10n.s("File", "文件"), fields)
    }

    // MARK: - Image section

    private static func imageSection(url: URL) -> ImageMetadata.Section? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        var fields: [ImageMetadata.Field] = []

        if let type = CGImageSourceGetType(source) as? String {
            let name = UTType(type)?.localizedDescription ?? type
            fields.append(.init(L10n.s("Format", "格式"), name))
        }
        if let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int {
            fields.append(.init(L10n.s("Dimensions", "尺寸"), "\(w) × \(h)" + L10n.s(" px", " 像素")))
        }
        if let depth = props[kCGImagePropertyDepth] as? Int {
            fields.append(.init(L10n.s("Bit Depth", "位深"), "\(depth)" + L10n.s("-bit", " 位")))
        }
        if let model = props[kCGImagePropertyColorModel] as? String {
            fields.append(.init(L10n.s("Color Space", "色彩空间"), model))
        }
        if let profile = props[kCGImagePropertyProfileName] as? String {
            fields.append(.init(L10n.s("ICC Profile", "ICC 配置"), profile))
        }
        if let dpiX = props[kCGImagePropertyDPIWidth] as? Double,
           let dpiY = props[kCGImagePropertyDPIHeight] as? Double {
            fields.append(.init("DPI", "\(Int(dpiX)) × \(Int(dpiY))"))
        }
        return fields.isEmpty ? nil : .init(L10n.s("Image", "图像"), fields)
    }

    // MARK: - EXIF section

    private static func exifSection(url: URL) -> ImageMetadata.Section? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        guard exif != nil || tiff != nil || gps != nil else { return nil }

        var fields: [ImageMetadata.Field] = []

        // Camera = Make + Model merged ("Canon EOS R5").
        let make = tiff?[kCGImagePropertyTIFFMake] as? String
        let model = tiff?[kCGImagePropertyTIFFModel] as? String
        if let camera = [make, model].compactMap({ $0 }).joined(separator: " ")
            .nonEmpty {
            fields.append(.init(L10n.s("Camera", "相机"), camera))
        }
        if let lens = exif?[kCGImagePropertyExifLensModel] as? String {
            fields.append(.init(L10n.s("Lens", "镜头"), lens))
        }
        if let focal = exif?[kCGImagePropertyExifFocalLength] as? Double {
            fields.append(.init(L10n.s("Focal Length", "焦距"), "\(focal.trimmed) mm"))
        }
        if let fnumber = exif?[kCGImagePropertyExifFNumber] as? Double {
            fields.append(.init(L10n.s("Aperture", "光圈"), "f/\(fnumber.trimmed)"))
        }
        if let exposure = exif?[kCGImagePropertyExifExposureTime] as? Double, exposure > 0 {
            fields.append(.init(L10n.s("Shutter", "快门"), exposure < 1
                ? "1/\(Int((1 / exposure).rounded()))" + L10n.s(" s", " 秒")
                : "\(exposure.trimmed)" + L10n.s(" s", " 秒")))
        }
        if let iso = isoValue(from: exif) {
            fields.append(.init("ISO", "\(iso)"))
        }
        if let dateTime = (exif?[kCGImagePropertyExifDateTimeOriginal]
            ?? tiff?[kCGImagePropertyTIFFDateTime]) as? String {
            fields.append(.init(L10n.s("Date Taken", "拍摄时间"), formattedEXIFDate(dateTime)))
        }
        if let gpsString = formattedGPS(gps) {
            fields.append(.init("GPS", gpsString))
        }
        return fields.isEmpty ? nil : .init(L10n.s("Camera Info", "拍摄信息"), fields)
    }

    private static func isoValue(from exif: [CFString: Any]?) -> Int? {
        let raw = exif?[kCGImagePropertyExifISOSpeedRatings]
            ?? exif?[kCGImagePropertyExifISOSpeed]
        if let array = raw as? [Int] { return array.first }
        return raw as? Int
    }

    private static func formattedEXIFDate(_ raw: String) -> String {
        // "2024:01:02 10:30:00" -> localized date
        let parser = DateFormatter()
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: raw) else { return raw }
        return dateFormatter.string(from: date)
    }

    private static func formattedGPS(_ gps: [CFString: Any]?) -> String? {
        guard let lat = gps?[kCGImagePropertyGPSLatitude] as? Double,
              let latRef = gps?[kCGImagePropertyGPSLatitudeRef] as? String,
              let lon = gps?[kCGImagePropertyGPSLongitude] as? Double,
              let lonRef = gps?[kCGImagePropertyGPSLongitudeRef] as? String else {
            return nil
        }
        return String(format: "%.4f° %@, %.4f° %@", lat, latRef, lon, lonRef)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension Double {
    /// "2.8" stays "2.8", "35.0" becomes "35".
    var trimmed: String {
        truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(self))
            : String(format: "%.1f", self)
    }
}
