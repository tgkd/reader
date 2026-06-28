import Foundation

/// Central, typed access to the UI-chrome localization tables
/// (`Localization/{en,ja}.lproj/Localizable.strings`). Keeps call sites free of
/// stringly-typed keys and gives one place to see every translatable label.
///
/// Scope note: only CHROME is localized. Reader content (the Japanese text,
/// furigana, dictionary headwords/readings) is always Japanese — those are the
/// material being read, not UI. Compact toggle glyphs (縦/横, 紙/茶/夜) stay
/// iconic in both languages.
enum L10n {
    static var wordmark: String { String(localized: "brand.wordmark") }

    static var statusUnread: String { String(localized: "library.status.unread") }
    static var statusDone: String { String(localized: "library.status.done") }
    static var libraryEmptyTitle: String { String(localized: "library.empty.title") }
    static var libraryEmptyBody: String { String(localized: "library.empty.body") }

    static var dictSave: String { String(localized: "dict.save") }
    static var dictSaved: String { String(localized: "dict.saved") }
    static var dictNotFound: String { String(localized: "dict.notFound") }

    static var readerNotGeneratedTitle: String { String(localized: "reader.notGenerated.title") }
    static var readerNotGeneratedBody: String { String(localized: "reader.notGenerated.body") }
    static var readerFailedTitle: String { String(localized: "reader.failed.title") }
    static var chapters: String { String(localized: "reader.chapters") }

    static var importFailedTitle: String { String(localized: "import.failed.title") }
    static var importUnsupported: String { String(localized: "import.unsupported") }
    static var importUnreadable: String { String(localized: "import.unreadable") }
    static var importEmpty: String { String(localized: "import.empty") }

    // VoiceOver labels for icon-only / custom-drawn controls.
    static var a11yBack: String { String(localized: "a11y.back") }
    static var a11yPlay: String { String(localized: "a11y.play") }
    static var a11yPause: String { String(localized: "a11y.pause") }
    static var a11yTheme: String { String(localized: "a11y.theme") }
    static var a11yAdd: String { String(localized: "a11y.add") }
    static var a11yOrientation: String { String(localized: "a11y.orientation") }
    static var a11yPosition: String { String(localized: "a11y.position") }
    static var a11yPlayWord: String { String(localized: "a11y.playWord") }
    static var a11ySaveWord: String { String(localized: "a11y.saveWord") }
}
