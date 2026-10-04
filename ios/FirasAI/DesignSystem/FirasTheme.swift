import Observation
import SwiftUI

enum FirasTheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case light
    case dark
    case black
    case midnight
    case graphite
    case amber

    var id: String { rawValue }

    var isLight: Bool { self == .light }

    var titleKey: LocalizedStringKey {
        switch self {
        case .light: "theme.light"
        case .dark: "theme.dark"
        case .black: "theme.black"
        case .midnight: "theme.midnight"
        case .graphite: "theme.graphite"
        case .amber: "theme.amber"
        }
    }

    var palette: FirasPalette {
        switch self {
        case .light:
            FirasPalette(
                background: "FAF9F5", backgroundSubtle: "F0EEE6", surface: "FFFFFF",
                surfaceSunken: "F0EEE6", sidebar: "F5F4EE", textPrimary: "1A1A18",
                textSecondary: "6B6A63", textMuted: "6E6C64", border: "E6E4DA",
                borderStrong: "D8D6CB", accent: "237A68", accentHover: "1A6253",
                accentDeep: "14544A", onAccent: "FFFFFF", success: "2E7D5B", error: "B3261E"
            )
        case .dark:
            FirasPalette(
                background: "262624", backgroundSubtle: "1F1E1D", surface: "30302E",
                surfaceSunken: "1F1E1D", sidebar: "1F1E1D", textPrimary: "ECEAE3",
                textSecondary: "A6A39A", textMuted: "9A978E", border: "3A3A36",
                borderStrong: "46453F", accent: "57AE9C", accentHover: "6BC0AE",
                accentDeep: "2F6F62", onAccent: "1F1E1D", success: "4BA784", error: "E06A60"
            )
        case .black:
            FirasPalette(
                background: "000000", backgroundSubtle: "0A0A0A", surface: "161616",
                surfaceSunken: "0A0A0A", sidebar: "000000", textPrimary: "F2F2F0",
                textSecondary: "ABABA6", textMuted: "8C8C87", border: "232323",
                borderStrong: "343432", accent: "5FBBA7", accentHover: "74CFBB",
                accentDeep: "2F6F62", onAccent: "000000", success: "4BA784", error: "E06A60"
            )
        case .midnight:
            FirasPalette(
                background: "0F1522", backgroundSubtle: "0A0E19", surface: "182133",
                surfaceSunken: "0A0E19", sidebar: "0A0E19", textPrimary: "E6ECF5",
                textSecondary: "9FACC2", textMuted: "8695AE", border: "232E44",
                borderStrong: "33405A", accent: "5AA9E6", accentHover: "7CBEF0",
                accentDeep: "2C6394", onAccent: "0A0E19", success: "4BA784", error: "E06A60"
            )
        case .graphite:
            FirasPalette(
                background: "171719", backgroundSubtle: "101012", surface: "202023",
                surfaceSunken: "101012", sidebar: "101012", textPrimary: "ECECEE",
                textSecondary: "A5A5AA", textMuted: "8B8B90", border: "2A2A2E",
                borderStrong: "3A3A3F", accent: "57AE9C", accentHover: "6BC0AE",
                accentDeep: "2F6F62", onAccent: "101012", success: "4BA784", error: "E06A60"
            )
        case .amber:
            FirasPalette(
                background: "1B1713", backgroundSubtle: "141110", surface: "241F19",
                surfaceSunken: "141110", sidebar: "141110", textPrimary: "F0E7D8",
                textSecondary: "B3A793", textMuted: "9C907C", border: "332C23",
                borderStrong: "453C30", accent: "D9A05B", accentHover: "E8B475",
                accentDeep: "8A6234", onAccent: "1B1713", success: "8FBF6F", error: "E06A60"
            )
        }
    }
}

struct FirasPalette: Sendable {
    let background: Color
    let backgroundSubtle: Color
    let surface: Color
    let surfaceSunken: Color
    let sidebar: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let border: Color
    let borderStrong: Color
    let accent: Color
    let accentHover: Color
    let accentDeep: Color
    let onAccent: Color
    let success: Color
    let error: Color

    init(
        background: String,
        backgroundSubtle: String,
        surface: String,
        surfaceSunken: String,
        sidebar: String,
        textPrimary: String,
        textSecondary: String,
        textMuted: String,
        border: String,
        borderStrong: String,
        accent: String,
        accentHover: String,
        accentDeep: String,
        onAccent: String,
        success: String,
        error: String
    ) {
        self.background = Color(hex: background)
        self.backgroundSubtle = Color(hex: backgroundSubtle)
        self.surface = Color(hex: surface)
        self.surfaceSunken = Color(hex: surfaceSunken)
        self.sidebar = Color(hex: sidebar)
        self.textPrimary = Color(hex: textPrimary)
        self.textSecondary = Color(hex: textSecondary)
        self.textMuted = Color(hex: textMuted)
        self.border = Color(hex: border)
        self.borderStrong = Color(hex: borderStrong)
        self.accent = Color(hex: accent)
        self.accentHover = Color(hex: accentHover)
        self.accentDeep = Color(hex: accentDeep)
        self.onAccent = Color(hex: onAccent)
        self.success = Color(hex: success)
        self.error = Color(hex: error)
    }
}

enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case arabic = "ar"
    case english = "en"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }
    var layoutDirection: LayoutDirection { self == .arabic ? .rightToLeft : .leftToRight }

    var titleKey: LocalizedStringKey {
        switch self {
        case .arabic: "language.arabic"
        case .english: "language.english"
        }
    }
}

enum FontScale: String, CaseIterable, Codable, Identifiable, Sendable {
    case small = "sm"
    case medium = "md"
    case large = "lg"

    var id: String { rawValue }
    var factor: CGFloat {
        switch self {
        case .small: 0.92
        case .medium: 1
        case .large: 1.10
        }
    }
}

enum ContentWidth: String, CaseIterable, Codable, Identifiable, Sendable {
    case normal
    case wide

    var id: String { rawValue }
    var maxWidth: CGFloat { self == .wide ? 980 : 760 }
}

enum MotionPreference: String, CaseIterable, Codable, Identifiable, Sendable {
    case full
    case reduced

    var id: String { rawValue }
}

enum CallVoice: String, CaseIterable, Codable, Identifiable, Sendable {
    case cedar
    case ash
    case verse
    case echo
    case ballad

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

enum DictationDialect: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case arabic
    case english

    var id: String { rawValue }
}

@MainActor
@Observable
final class PreferencesStore {
    var theme: FirasTheme { didSet { persist(theme.rawValue, forKey: Keys.theme) } }
    var language: AppLanguage { didSet { persist(language.rawValue, forKey: Keys.language) } }
    var tier: ModelTier { didSet { persist(tier.rawValue, forKey: Keys.tier) } }
    var modelGeneration: ModelGeneration {
        didSet { persist(modelGeneration.rawValue, forKey: Keys.modelGeneration) }
    }
    var fontScale: FontScale { didSet { persist(fontScale.rawValue, forKey: Keys.fontScale) } }
    var contentWidth: ContentWidth { didSet { persist(contentWidth.rawValue, forKey: Keys.width) } }
    var webSearchEnabled: Bool { didSet { persist(webSearchEnabled, forKey: Keys.webSearch) } }
    var thinkingEnabled: Bool { didSet { persist(thinkingEnabled, forKey: Keys.thinking) } }
    var motionPreference: MotionPreference {
        didSet { persist(motionPreference.rawValue, forKey: Keys.motion) }
    }
    var sendOnReturn: Bool { didSet { persist(sendOnReturn, forKey: Keys.sendOnReturn) } }
    var sharpenImages: Bool { didSet { persist(sharpenImages, forKey: Keys.sharpenImages) } }
    var callVoice: CallVoice { didSet { persist(callVoice.rawValue, forKey: Keys.callVoice) } }
    var dictationDialect: DictationDialect {
        didSet { persist(dictationDialect.rawValue, forKey: Keys.dictationDialect) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = FirasTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .dark
        language = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .arabic
        tier = ModelTier(rawValue: defaults.string(forKey: Keys.tier) ?? "") ?? .pro
        modelGeneration = .savedPreference(defaults.string(forKey: Keys.modelGeneration))
        fontScale = FontScale(rawValue: defaults.string(forKey: Keys.fontScale) ?? "") ?? .medium
        contentWidth = ContentWidth(rawValue: defaults.string(forKey: Keys.width) ?? "") ?? .normal
        webSearchEnabled = defaults.object(forKey: Keys.webSearch) as? Bool ?? false
        thinkingEnabled = defaults.object(forKey: Keys.thinking) as? Bool ?? false
        if let rawMotion = defaults.string(forKey: Keys.motion),
           let savedMotion = MotionPreference(rawValue: rawMotion) {
            motionPreference = savedMotion
        } else if let legacyMotion = defaults.object(forKey: Keys.motion) as? Bool {
            motionPreference = legacyMotion ? .full : .reduced
        } else {
            motionPreference = .full
        }
        sendOnReturn = defaults.object(forKey: Keys.sendOnReturn) as? Bool ?? false
        sharpenImages = defaults.object(forKey: Keys.sharpenImages) as? Bool ?? false
        callVoice = CallVoice(rawValue: defaults.string(forKey: Keys.callVoice) ?? "") ?? .cedar
        dictationDialect = DictationDialect(
            rawValue: defaults.string(forKey: Keys.dictationDialect) ?? ""
        ) ?? .automatic
    }

    var palette: FirasPalette { theme.palette }

    func modelLabel(for tier: ModelTier) -> String {
        tier.label(language: language, generation: modelGeneration)
    }

    var motionEnabled: Bool {
        get { motionPreference == .full }
        set { motionPreference = newValue ? .full : .reduced }
    }

    /// Resets only the preference keys owned by this store. Session cookies,
    /// chats, drafts, imports, and other user-authored content are untouched.
    func resetToDefaults() {
        theme = .dark
        language = .arabic
        tier = .pro
        modelGeneration = .shippingDefault
        fontScale = .medium
        contentWidth = .normal
        webSearchEnabled = false
        thinkingEnabled = false
        motionPreference = .full
        sendOnReturn = false
        sharpenImages = false
        callVoice = .cedar
        dictationDialect = .automatic

        Keys.all.forEach { defaults.removeObject(forKey: $0) }
    }

    private func persist(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    private enum Keys {
        static let theme = "theme"
        static let language = "lang"
        static let tier = "tier"
        static let modelGeneration = "firas_ai_mgen"
        static let fontScale = "fontSize"
        static let width = "width"
        static let webSearch = "webSearch"
        static let thinking = "thinking"
        static let motion = "motion"
        static let sendOnReturn = "enterSend"
        static let sharpenImages = "imageSharpening"
        // Shared with VoiceCallView's @AppStorage so Settings takes effect
        // immediately without a second source of truth.
        static let callVoice = "callVoice"
        static let dictationDialect = "dictationLanguage"

        static let all = [
            theme, language, tier, modelGeneration, fontScale, width, webSearch, thinking,
            motion, sendOnReturn, sharpenImages, callVoice, dictationDialect,
        ]
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        switch cleaned.count {
        case 8:
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
            alpha = Double(value & 0xFF) / 255
        default:
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            alpha = 1
        }

        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
