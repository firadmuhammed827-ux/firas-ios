import Foundation

nonisolated struct ArtifactDownload: Equatable, Sendable {
    let data: Data
    let mimeType: String
    let suggestedFilename: String
}

nonisolated enum AppAPIValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case object([String: AppAPIValue])
    case array([AppAPIValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: AppAPIValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([AppAPIValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

/// Generation 1 is represented by an absent wire key. This preserves the
/// website's legacy request fingerprint and historical model attribution.
nonisolated enum ModelGeneration: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case legacy = ""
    case v11 = "1.1"

    // Mirrors the shipping website's CONFIG.DEFAULT_MGEN.
    static let shippingDefault: ModelGeneration = .v11

    var id: String { rawValue }
    var displayVersion: String { self == .legacy ? "1" : "1.1" }
    var wireValue: String? { self == .v11 ? rawValue : nil }

    static func savedPreference(_ value: String?) -> ModelGeneration {
        guard let value else { return shippingDefault }
        return ModelGeneration(rawValue: value) ?? shippingDefault
    }

    /// Old and unknown history never inherit the current picker selection.
    static func historyValue(_ value: String?) -> ModelGeneration {
        value == ModelGeneration.v11.rawValue ? .v11 : .legacy
    }
}

nonisolated enum ModelTier: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case mini
    case pro
    case ultra
    case max

    var id: String { rawValue }

    var labelArabic: String {
        labelEnglish
    }

    var labelEnglish: String { label(generation: .legacy) }

    func label(generation: ModelGeneration) -> String {
        let name: String = switch self {
        case .mini: "luma"
        case .pro: "nova"
        case .ultra: "titan"
        case .max: "atlas"
        }
        return "\(name) \(generation.displayVersion)"
    }

    var taglineArabic: String {
        switch self {
        case .mini: "سريع للأسئلة اليومية"
        case .pro: "متوازن وذكي"
        case .ultra: "قويّ جدًا — الأفضل للأكواد"
        case .max: "الأقوى — أعلى ذكاء وتفكير"
        }
    }

    var taglineEnglish: String {
        switch self {
        case .mini: "Fast for everyday questions"
        case .pro: "Balanced & smart"
        case .ultra: "Very powerful — best for code"
        case .max: "Strongest — top intelligence"
        }
    }

    @MainActor
    func label(language: AppLanguage, generation: ModelGeneration = .legacy) -> String {
        // Product model names stay in Latin script in both interface languages.
        label(generation: generation)
    }

    @MainActor
    func tagline(language: AppLanguage) -> String {
        language == .arabic ? taglineArabic : taglineEnglish
    }
}

nonisolated enum ProductKind: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case ai
    case code
    case brain

    var id: String { rawValue }
}
