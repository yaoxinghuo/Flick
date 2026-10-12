import Foundation

/// A single image file discovered in a folder, carrying the attributes needed for sorting.
public struct ImageFile: Equatable {
    public let url: URL
    public let fileSize: Int64
    public let creationDate: Date?
    public let modificationDate: Date?

    public init(url: URL, fileSize: Int64 = 0, creationDate: Date? = nil, modificationDate: Date? = nil) {
        self.url = url
        self.fileSize = fileSize
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }

    public var fileName: String {
        url.lastPathComponent
    }
}

public enum ImageSortKey: String, CaseIterable, Equatable {
    case name
    case modificationDate
    case creationDate
    case fileSize

    public var displayName: String {
        switch self {
        case .name: return L10n.s("Name", "名称")
        case .modificationDate: return L10n.s("Date Modified", "修改日期")
        case .creationDate: return L10n.s("Date Created", "创建日期")
        case .fileSize: return L10n.s("Size", "大小")
        }
    }
}

public struct ImageSortOrder: Equatable {
    public var key: ImageSortKey
    public var ascending: Bool

    public init(key: ImageSortKey = .name, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }
}
