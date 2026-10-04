import Foundation

// Only SwiftUI/account types unused by the model policy are substituted.
// CommonModels, ChatModels and the real backup sanitizer compile unchanged.
nonisolated enum AppLanguage: String, Codable, Sendable {
    case arabic = "ar"
    case english = "en"
}
nonisolated struct Subscription: Codable, Equatable, Sendable {}
nonisolated struct User: Codable, Equatable, Sendable {}
