import Foundation
import Testing
@testable import PeekCore

struct ImageFileScannerTests {

    /// Creates a temp folder populated with the given file names (empty files).
    private func makeFolder(files: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("peek-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in files {
            let url = folder.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data([0x00]))
        }
        return folder
    }

    private func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    private func names(_ files: [ImageFile]) -> [String] {
        files.map(\.fileName)
    }

    @Test func naturalSortPuts2Before10() throws {
        let folder = try makeFolder(files: ["img10.png", "img2.png", "img1.png"])
        defer { remove(folder) }
        let sorted = ImageFileScanner.sorted(
            try #require(ImageFileScanner.scan(folder: folder)),
            by: ImageSortOrder(key: .name)
        )
        #expect(names(sorted) == ["img1.png", "img2.png", "img10.png"])
    }

    @Test func descendingNameSort() throws {
        let folder = try makeFolder(files: ["a.png", "c.png", "b.png"])
        defer { remove(folder) }
        let sorted = ImageFileScanner.sorted(
            try #require(ImageFileScanner.scan(folder: folder)),
            by: ImageSortOrder(key: .name, ascending: false)
        )
        #expect(names(sorted) == ["c.png", "b.png", "a.png"])
    }

    @Test func nonImageFilesAreFiltered() throws {
        let folder = try makeFolder(files: [
            "photo.jpg", "notes.txt", "doc.pdf", "script.sh", "data.bin", "pic.heic",
        ])
        defer { remove(folder) }
        let files = try #require(ImageFileScanner.scan(folder: folder))
        #expect(names(files).sorted() == ["photo.jpg", "pic.heic"].sorted())
    }

    @Test func hiddenFilesAreIgnored() throws {
        let folder = try makeFolder(files: ["visible.png", ".hidden.png", ".DS_Store"])
        defer { remove(folder) }
        let files = try #require(ImageFileScanner.scan(folder: folder))
        #expect(names(files) == ["visible.png"])
    }

    @Test func subfoldersAreNotScanned() throws {
        let folder = try makeFolder(files: ["top.png"])
        defer { remove(folder) }
        let sub = folder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sub.appendingPathComponent("inner.png").path, contents: Data())
        let files = try #require(ImageFileScanner.scan(folder: folder))
        #expect(names(files) == ["top.png"])
    }

    @Test func sortByFileSize() {
        let files = [
            ImageFile(url: URL(fileURLWithPath: "/b.png"), fileSize: 300),
            ImageFile(url: URL(fileURLWithPath: "/a.png"), fileSize: 100),
            ImageFile(url: URL(fileURLWithPath: "/c.png"), fileSize: 100),
        ]
        let sorted = ImageFileScanner.sorted(files, by: ImageSortOrder(key: .fileSize))
        // Ties fall back to natural name order.
        #expect(names(sorted) == ["a.png", "c.png", "b.png"])
    }

    @Test func sortByModificationDateMissingValuesLast() {
        let now = Date()
        let files = [
            ImageFile(url: URL(fileURLWithPath: "/z.png"), modificationDate: nil),
            ImageFile(url: URL(fileURLWithPath: "/a.png"), modificationDate: now.addingTimeInterval(-10)),
            ImageFile(url: URL(fileURLWithPath: "/b.png"), modificationDate: now),
        ]
        let sorted = ImageFileScanner.sorted(files, by: ImageSortOrder(key: .modificationDate))
        #expect(names(sorted) == ["a.png", "b.png", "z.png"])
    }

    @Test func utTypeClassification() {
        #expect(ImageFileScanner.isImageFile(URL(fileURLWithPath: "/x.png")))
        #expect(ImageFileScanner.isImageFile(URL(fileURLWithPath: "/x.jpeg")))
        #expect(ImageFileScanner.isImageFile(URL(fileURLWithPath: "/x.gif")))
        #expect(ImageFileScanner.isImageFile(URL(fileURLWithPath: "/x.webp")))
        #expect(ImageFileScanner.isImageFile(URL(fileURLWithPath: "/x.tiff")))
        #expect(ImageFileScanner.isImageFile(URL(fileURLWithPath: "/x.bmp")))
        #expect(ImageFileScanner.isImageFile(URL(fileURLWithPath: "/x.ico")))
        #expect(!ImageFileScanner.isImageFile(URL(fileURLWithPath: "/x.txt")))
        #expect(!ImageFileScanner.isImageFile(URL(fileURLWithPath: "/x.pdf")))
        #expect(!ImageFileScanner.isImageFile(URL(fileURLWithPath: "/x")))
        #expect(!ImageFileScanner.isImageFile(URL(fileURLWithPath: "/x.xyzfakeext")))
    }
}
