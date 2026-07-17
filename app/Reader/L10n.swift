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
    static var settingsVoice: String { String(localized: "settings.section.voice") }
    static var settingsVoiceNote: String { String(localized: "settings.voice.note") }

    // Settings — membership status/management.
    static var settingsMembership: String { String(localized: "settings.section.membership") }
    static var membershipActive: String { String(localized: "membership.active") }
    static var membershipManage: String { String(localized: "membership.manage") }

    // About — version, product links, data-source attributions.
    static var settingsAbout: String { String(localized: "settings.about") }
    static var aboutVersion: String { String(localized: "about.version") }
    static var aboutDescription: String { String(localized: "about.description") }
    static var aboutLinks: String { String(localized: "about.section.links") }
    static var aboutWebsite: String { String(localized: "about.website") }
    static var aboutTerms: String { String(localized: "about.terms") }
    static var aboutPrivacy: String { String(localized: "about.privacy") }
    static var aboutContact: String { String(localized: "about.contact") }
    static var aboutSources: String { String(localized: "about.section.sources") }
    static var aboutSourcesNote: String { String(localized: "about.sources.note") }
    static var aboutAINote: String { String(localized: "about.ai.note") }
    // Settings — storage: clear the on-disk narration cache.
    static var settingsStorage: String { String(localized: "settings.section.storage") }
    static var storageClear: String { String(localized: "settings.storage.clear") }
    static var storageClearTitle: String { String(localized: "settings.storage.clear.title") }
    static var storageClearBody: String { String(localized: "settings.storage.clear.body") }
    static var themePaper: String { String(localized: "theme.paper") }
    static var themeWhite: String { String(localized: "theme.white") }
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
    static var readerFailedNetwork: String { String(localized: "reader.failed.network") }
    static var readerNextChapter: String { String(localized: "reader.nextChapter") }
    static var readerSubscribeTitle: String { String(localized: "reader.subscribe.title") }
    static var readerSubscribeBody: String { String(localized: "reader.subscribe.body") }
    static var readerSubscribeCTA: String { String(localized: "reader.subscribe.cta") }
    static var membershipUnavailable: String { String(localized: "membership.unavailable") }
    static var membershipFeatureNarrationTitle: String { String(localized: "membership.feature.narration.title") }
    static var membershipFeatureNarrationBody: String { String(localized: "membership.feature.narration.body") }
    static var membershipFeatureVoicesTitle: String { String(localized: "membership.feature.voices.title") }
    static var membershipFeatureVoicesBody: String { String(localized: "membership.feature.voices.body") }
    static var membershipFeatureOCRTitle: String { String(localized: "membership.feature.ocr.title") }
    static var membershipFeatureOCRBody: String { String(localized: "membership.feature.ocr.body") }
    static var membershipSubscribe: String { String(localized: "membership.subscribe") }
    static var membershipRestore: String { String(localized: "membership.restore") }
    static var membershipRestoreNone: String { String(localized: "membership.restore.none") }
    /// Subscription-details sheet; the renews/expires lines take a formatted date.
    static func membershipRenews(_ date: String) -> String {
        String(format: String(localized: "membership.details.renews.format"), date)
    }
    static func membershipExpires(_ date: String) -> String {
        String(format: String(localized: "membership.details.expires.format"), date)
    }
    static var membershipTestPurchase: String { String(localized: "membership.details.testPurchase") }
    static var membershipManageAppStore: String { String(localized: "membership.details.manage") }
    static var chapters: String { String(localized: "reader.chapters") }
    /// Fallback navigation label for an imported chapter with no title of its own
    /// (chrome — localizes, unlike the real title, which is reader content).
    static func chapterNumber(_ n: Int) -> String {
        String(format: String(localized: "reader.chapterNumber.format"), n)
    }
    /// Header subtitle for an untitled chapter; %1$d current, %2$d total.
    static func chapterOfCount(_ n: Int, _ count: Int) -> String {
        String(format: String(localized: "reader.chapterOfCount.format"), n, count)
    }
    static var readerGenerating: String { String(localized: "reader.generating") }

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
    static var a11ySpeed: String { String(localized: "a11y.speed") }
    static var a11yVoiceDemo: String { String(localized: "a11y.voiceDemo") }
}
