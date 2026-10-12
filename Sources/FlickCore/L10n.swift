import Foundation

/// Minimal two-language strings: English + Simplified Chinese, following the
/// system language. No `.lproj` catalogs — the app is built from raw SwiftPM
/// without Xcode's resource bundling, so strings live in code.
public enum L10n {
    /// True when the system's preferred UI language is any Chinese variant.
    public static var isChinese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true
    }

    /// Picks the Chinese string on Chinese systems, English otherwise.
    public static func s(_ english: String, _ chinese: String) -> String {
        isChinese ? chinese : english
    }
}
