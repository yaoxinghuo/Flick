import AppKit
import FlickCore

/// Canvas background behind the image.
enum BackgroundStyle: String, CaseIterable {
    case darkGray
    case black
    case system

    var displayName: String {
        switch self {
        case .darkGray: return L10n.s("Dark Gray", "深灰")
        case .black: return L10n.s("Black", "纯黑")
        case .system: return L10n.s("System", "跟随系统")
        }
    }

    var color: NSColor {
        switch self {
        case .darkGray: return NSColor(calibratedWhite: 0.11, alpha: 1)
        case .black: return .black
        case .system: return .windowBackgroundColor
        }
    }

    private static let defaultsKey = "backgroundStyle"

    static func load() -> BackgroundStyle {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(BackgroundStyle.init(rawValue:)) ?? .darkGray
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}
