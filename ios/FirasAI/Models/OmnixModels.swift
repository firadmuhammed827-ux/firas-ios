import Foundation

nonisolated struct OmnixAccessRecord: Decodable, Equatable, Sendable {
    let ok: Bool
    let status: String
    let reason: String
    let canRequest: Bool
    let canUse: Bool
    let available: Bool
    let requestedAt: Int64?
    let reviewedAt: Int64?

    var isValid: Bool {
        ok && ["not_requested", "pending", "approved", "rejected", "revoked"].contains(status) && reason.utf16.count <= 1_200
    }

    var acceptsRequest: Bool {
        isValid && canRequest && ["not_requested", "rejected", "revoked"].contains(status)
    }
}

nonisolated struct OmnixAccessRequest: Encodable, Sendable {
    let reason: String

    var isValid: Bool {
        reason.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count >= 20 && reason.utf16.count <= 1_200
    }
}
