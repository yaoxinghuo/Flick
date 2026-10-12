import Foundation
import UniformTypeIdentifiers

/// Scans a folder (non-recursively) for image files and sorts them.
public enum ImageFileScanner {

    /// Whether the file at `url` is an image, judged by its `UTType` conformance
    /// (not just the raw extension string). Covers JPEG/PNG/GIF/HEIC/TIFF/BMP/WebP/ICO
    /// and system-supported RAW formats.
    public static func isImageFile(_ url: URL) -> Bool {
        guard !url.pathExtension.isEmpty,
              let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }

    /// Lists image files directly inside `folder`. Hidden files are skipped.
    /// Returns `nil` when the folder cannot be read.
    public static func scan(folder: URL) -> [ImageFile]? {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var files: [ImageFile] = []
        files.reserveCapacity(urls.count)
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  isImageFile(url) else {
                continue
            }
            files.append(ImageFile(
                url: url,
                fileSize: Int64(values.fileSize ?? 0),
                creationDate: values.creationDate,
                modificationDate: values.contentModificationDate
            ))
        }
        return files
    }

    /// Sorts files by the given order. Name sorting uses Finder-style natural
    /// ordering ("2" before "10"). Ties always fall back to natural name order so
    /// the result is stable.
    public static func sorted(_ files: [ImageFile], by order: ImageSortOrder) -> [ImageFile] {
        let comparator: (ImageFile, ImageFile) -> ComparisonResult = { a, b in
            switch order.key {
            case .name:
                return a.fileName.localizedStandardCompare(b.fileName)
            case .modificationDate:
                return compare(a.modificationDate, b.modificationDate)
            case .creationDate:
                return compare(a.creationDate, b.creationDate)
            case .fileSize:
                return compare(a.fileSize, b.fileSize)
            }
        }
        return files.sorted { a, b in
            let result = comparator(a, b)
            if result == .orderedSame {
                return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
            }
            let ascending = result == .orderedAscending
            return order.ascending ? ascending : !ascending
        }
    }

    private static func compare<T: Comparable>(_ a: T?, _ b: T?) -> ComparisonResult {
        switch (a, b) {
        case let (a?, b?):
            if a == b { return .orderedSame }
            return a < b ? .orderedAscending : .orderedDescending
        case (nil, nil): return .orderedSame
        case (nil, _?): return .orderedDescending // missing values go last
        case (_?, nil): return .orderedAscending
        }
    }
}
