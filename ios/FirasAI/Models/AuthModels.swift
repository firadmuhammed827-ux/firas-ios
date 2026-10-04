import Foundation

nonisolated enum SubscriptionPlan: String, Codable, Equatable, Sendable {
    case guest
    case free
    case gold
    case diamond
    case unlimited

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = SubscriptionPlan(rawValue: value) ?? .free
    }
}

nonisolated struct UsageCounts: Codable, Equatable, Sendable {
    let ai: Int
    let code: Int
    let agent: Int
    let brain: Int
}

nonisolated struct Subscription: Codable, Equatable, Sendable {
    let plan: SubscriptionPlan
    let expiresAt: Double?
    let daysLeft: Int?
    let limits: UsageCounts
    let used: UsageCounts
    let remaining: UsageCounts
}

nonisolated struct User: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let email: String
    let admin: Bool
    let sub: Subscription
    let guest: Bool?

    var isGuest: Bool { guest == true }
}

nonisolated struct PendingSignup: Codable, Equatable, Sendable {
    let email: String
    let pid: String
}

nonisolated struct LoginRequest: Encodable, Equatable, Sendable {
    let email: String
    let password: String
}

nonisolated struct FirebaseIDTokenRequest: Encodable, Equatable, Sendable {
    let idToken: String
}

/// Request for the existing server-side Google OAuth PKCE exchange. The
/// returned token is a Google ID token, not a Firebase Secure Token.
nonisolated struct GoogleOAuthCodeExchangeRequest: Encodable, Equatable, Sendable {
    let code: String
    let codeVerifier: String

    private enum CodingKeys: String, CodingKey {
        case code
        case codeVerifier = "code_verifier"
    }
}

nonisolated struct GoogleOAuthCodeExchangeResponse: Decodable, Equatable, Sendable {
    let googleIDToken: String

    private enum CodingKeys: String, CodingKey {
        case googleIDToken = "id_token"
    }
}

nonisolated struct GoogleNativeAuthorization: Equatable, Sendable {
    let code: String
    let codeVerifier: String
    let nonce: String
}

nonisolated struct GoogleNativeAuthRequest: Encodable, Equatable, Sendable {
    let code: String
    let codeVerifier: String
    let nonce: String

    init(authorization: GoogleNativeAuthorization) {
        code = authorization.code
        codeVerifier = authorization.codeVerifier
        nonce = authorization.nonce
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case codeVerifier = "code_verifier"
        case nonce
    }
}

nonisolated struct SignupRequest: Encodable, Equatable, Sendable {
    let name: String
    let email: String
    let password: String
}

nonisolated struct SignupResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let pending: Bool
    let email: String
    let pid: String
}

nonisolated struct VerifySignupRequest: Encodable, Equatable, Sendable {
    let token: String
}

nonisolated struct VerificationStatusRequest: Encodable, Equatable, Sendable {
    let pid: String
}

nonisolated struct VerificationStatusResponse: Decodable, Equatable, Sendable {
    let verified: Bool
    let gone: Bool?
    let expired: Bool?
    let user: User?
}

nonisolated struct UserEnvelope: Decodable, Equatable, Sendable {
    let user: User
}

nonisolated struct VerifiedUserEnvelope: Decodable, Equatable, Sendable {
    let ok: Bool
    let user: User
}

nonisolated struct GuestSessionResponse: Decodable, Equatable, Sendable {
    let guest: Bool
    let user: User
}

nonisolated struct OperationResponse: Codable, Equatable, Sendable {
    let ok: Bool
}
