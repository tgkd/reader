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

    static var commonOK: String { String(localized: "common.ok") }
    static var commonCancel: String { String(localized: "common.cancel") }

    // Library — swipe-to-delete a text + its cached audio.
    static var libraryDelete: String { String(localized: "library.delete") }
    static var libraryDeleteTitle: String { String(localized: "library.delete.title") }
    /// Confirmation body; %@ is the text's title.
    static func libraryDeleteBody(_ title: String) -> String {
        String(format: String(localized: "library.delete.body.format"), title)
    }

    // Settings — reading preferences (font + size)
    static var settings: String { String(localized: "settings.title") }
    static var settingsFont: String { String(localized: "settings.section.font") }
    static var settingsSize: String { String(localized: "settings.section.size") }
    static var fontMincho: String { String(localized: "settings.font.mincho") }
    static var fontGothic: String { String(localized: "settings.font.gothic") }
    static var fontRounded: String { String(localized: "settings.font.rounded") }
    static var sizeSmall: String { String(localized: "settings.size.small") }
    static var sizeMedium: String { String(localized: "settings.size.medium") }
    static var sizeLarge: String { String(localized: "settings.size.large") }
    static var settingsDirection: String { String(localized: "settings.section.direction") }
    static var directionVertical: String { String(localized: "direction.vertical") }
    static var directionHorizontal: String { String(localized: "direction.horizontal") }
    static var settingsFurigana: String { String(localized: "settings.section.furigana") }
    static var furiganaShow: String { String(localized: "furigana.show") }
    static var furiganaHide: String { String(localized: "furigana.hide") }
    static var settingsTheme: String { String(localized: "settings.section.theme") }
    // Settings — storage: clear the on-disk narration cache.
    static var settingsStorage: String { String(localized: "settings.section.storage") }
    static var storageClear: String { String(localized: "settings.storage.clear") }
    static var storageClearTitle: String { String(localized: "settings.storage.clear.title") }
    static var storageClearBody: String { String(localized: "settings.storage.clear.body") }
    static var themePaper: String { String(localized: "theme.paper") }
    static var themeSepia: String { String(localized: "theme.sepia") }
    static var themeNight: String { String(localized: "theme.night") }

    static var statusUnread: String { String(localized: "library.status.unread") }
    static var statusDone: String { String(localized: "library.status.done") }
    static var libraryEmptyTitle: String { String(localized: "library.empty.title") }
    static var libraryEmptyBody: String { String(localized: "library.empty.body") }

    static var dictNotFound: String { String(localized: "dict.notFound") }

    static var readerNotGeneratedTitle: String { String(localized: "reader.notGenerated.title") }
    static var readerNotGeneratedBody: String { String(localized: "reader.notGenerated.body") }
    static var readerFailedTitle: String { String(localized: "reader.failed.title") }
    static var readerFailedTokenizer: String { String(localized: "reader.failed.tokenizer") }
    static var readerFailedAudio: String { String(localized: "reader.failed.audio") }
    static var readerSubscribeTitle: String { String(localized: "reader.subscribe.title") }
    static var readerSubscribeBody: String { String(localized: "reader.subscribe.body") }
    static var readerSubscribeCTA: String { String(localized: "reader.subscribe.cta") }
    static var membershipUnavailable: String { String(localized: "membership.unavailable") }
    static var chapters: String { String(localized: "reader.chapters") }
    /// Fallback navigation label for an imported chapter with no title of its own
    /// (chrome — localizes, unlike the real title, which is reader content).
    static func chapterNumber(_ n: Int) -> String {
        String(format: String(localized: "reader.chapterNumber.format"), n)
    }

    static var a11yMembership: String { String(localized: "a11y.membership") }
    static var a11ySettings: String { String(localized: "a11y.settings") }

    static var importFailedTitle: String { String(localized: "import.failed.title") }
    static var importUnsupported: String { String(localized: "import.unsupported") }
    static var importUnreadable: String { String(localized: "import.unreadable") }
    static var importEmpty: String { String(localized: "import.empty") }
    static var importOCRFailed: String { String(localized: "import.ocrFailed") }
    static var importOCRUnavailable: String { String(localized: "import.ocrUnavailable") }
    /// Determinate OCR progress while importing a scanned PDF; %1$d / %2$d.
    static func importRecognizing(_ done: Int, _ total: Int) -> String {
        String(format: String(localized: "import.recognizing.format"), done, total)
    }

    static var importOCRConfirmTitle: String { String(localized: "import.ocr.confirm.title") }
    static var importOCRConfirmAction: String { String(localized: "import.ocr.confirm.action") }
    /// Body for the "this book is image-only — read it with AI?" confirm; %d = page
    /// count. Above a soft threshold it appends a cost/time caution so a huge scan
    /// can't run away on Membership credits silently.
    static func importOCRConfirmBody(_ pages: Int) -> String {
        var message = String(format: String(localized: "import.ocr.confirm.body.format"), pages)
        if pages > 100 { message += " " + String(localized: "import.ocr.confirm.large") }
        return message
    }

    // VoiceOver labels for icon-only / custom-drawn controls.
    static var a11yBack: String { String(localized: "a11y.back") }
    static var a11yPlay: String { String(localized: "a11y.play") }
    static var a11yPause: String { String(localized: "a11y.pause") }
    static var a11yTheme: String { String(localized: "a11y.theme") }
    static var a11yAdd: String { String(localized: "a11y.add") }
    static var a11yOrientation: String { String(localized: "a11y.orientation") }
    static var a11yPosition: String { String(localized: "a11y.position") }
    static var a11yPlayWord: String { String(localized: "a11y.playWord") }
    static var a11yAudioCached: String { String(localized: "a11y.audioCached") }
}
