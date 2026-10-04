import Foundation

nonisolated enum OmnixCloudProduct: String, Codable, Sendable { case ai, code }

nonisolated enum OmnixCloudPolicy {
    static func matches(_ value: String, _ pattern: String) -> Bool {
        guard let range = value.range(of: pattern, options: .regularExpression) else { return false }
        return range.lowerBound == value.startIndex && range.upperBound == value.endIndex
    }
    static func jobID(_ value: String) -> Bool { matches(value, "^omxj_[a-f0-9]{32}$") }
    static func sessionID(_ value: String) -> Bool { matches(value, "^omxs_[a-f0-9]{32}$") }
    static func fileID(_ value: String) -> Bool { matches(value, "^[a-f0-9]{64}$") }
    static func requestKey(_ value: String) -> Bool { matches(value, "^[A-Za-z0-9_-]{16,128}$") }
    static func terminal(_ state: String) -> Bool { ["completed", "failed", "cancelled", "canceled", "interrupted"].contains(state) }
    static func state(_ value: String) -> Bool {
        terminal(value) || ["reserved", "submission_uncertain", "queued", "running", "waiting_for_approval", "stopping"].contains(value)
    }
}

nonisolated struct OmnixCloudPointer: Codable, Equatable, Sendable {
    var jobId: String?
    var sessionId: String?
    var requestKey: String?

    var isValid: Bool {
        (jobId == nil || OmnixCloudPolicy.jobID(jobId!)) &&
        (sessionId == nil || OmnixCloudPolicy.sessionID(sessionId!)) &&
        (requestKey == nil || OmnixCloudPolicy.requestKey(requestKey!))
    }
}

nonisolated struct OmnixCloudLatest: Decodable, Equatable, Sendable {
    let jobId: String
    let sessionId: String
    let state: String
    let product: OmnixCloudProduct
    let requestKey: String?
    var pointer: OmnixCloudPointer { OmnixCloudPointer(jobId: jobId, sessionId: sessionId, requestKey: requestKey) }
}

nonisolated struct OmnixCloudStatus: Decodable, Equatable, Sendable {
    let state: String
    let ready: Bool
    let latestJob: OmnixCloudLatest?
    let latestJobs: [String: OmnixCloudLatest]?

    var canRun: Bool { ready && state == "ready" }
    func latest(for product: OmnixCloudProduct) -> OmnixCloudLatest? {
        let candidate = latestJobs?[product.rawValue] ?? (latestJob?.product == product ? latestJob : nil)
        guard let candidate, candidate.product == product, candidate.pointer.isValid else { return nil }
        return candidate
    }
}

nonisolated struct OmnixCloudRunRequest: Encodable, Sendable {
    let requestKey: String
    let text: String
    let product: OmnixCloudProduct
    let sessionId: String?
    var isValid: Bool {
        OmnixCloudPolicy.requestKey(requestKey) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        text.utf16.count <= 60_000 && (sessionId == nil || OmnixCloudPolicy.sessionID(sessionId!))
    }
}

nonisolated struct OmnixCloudApprovalRequest: Encodable, Sendable {
    let requestId: String
    let choice: String
    var isValid: Bool { OmnixCloudPolicy.matches(requestId, "^[A-Za-z0-9_-]{1,256}$") && ["once", "deny"].contains(choice) }
}

nonisolated struct OmnixCloudEmptyBody: Encodable, Sendable {}
nonisolated struct OmnixCloudAcknowledgement: Decodable, Sendable {}

nonisolated struct OmnixCloudApproval: Decodable, Equatable, Sendable {
    let requestId: String
    let command: String
    let reason: String
    let choices: [String]
    var isValid: Bool {
        OmnixCloudPolicy.matches(requestId, "^[A-Za-z0-9_-]{1,256}$") && command.utf16.count <= 4_000 &&
        reason.utf16.count <= 1_000 && choices.count <= 2 && Set(choices).count == choices.count && choices.allSatisfy { ["once", "deny"].contains($0) }
    }
}

nonisolated struct OmnixCloudResult: Decodable, Equatable, Sendable {
    let output: String?
    let approval: OmnixCloudApproval?
}

nonisolated struct OmnixCloudStep: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let s: String
    let observed: Bool
    let durationMs: Double?
    let error: Bool?
    var isValid: Bool { !id.isEmpty && id.count <= 128 && title.utf16.count <= 128 && observed && ["run", "done", "fail", "unknown"].contains(s) }
}

nonisolated struct OmnixCloudCapture: Decodable, Equatable, Sendable {
    let complete: Bool
    let droppedSteps: Int
}

nonisolated struct OmnixCloudProgress: Decodable, Equatable, Sendable {
    let engine: String
    let plan: [OmnixCloudStep]
    let says: [String]
    let capture: OmnixCloudCapture?
    var observedSteps: [OmnixCloudStep] {
        guard engine == "omnix" else { return [] }
        var seen = Set<String>()
        return Array(plan.suffix(500)).filter { $0.isValid && seen.insert($0.id).inserted }
    }
}

nonisolated struct OmnixCloudJob: Decodable, Equatable, Sendable {
    let jobId: String
    let sessionId: String
    let state: String
    let createdAt: Int64
    let updatedAt: Int64
    let result: OmnixCloudResult?
    let progress: OmnixCloudProgress?
    var isValid: Bool { OmnixCloudPolicy.jobID(jobId) && OmnixCloudPolicy.sessionID(sessionId) && OmnixCloudPolicy.state(state) }
    var isTerminal: Bool { OmnixCloudPolicy.terminal(state) }
    var pendingApproval: OmnixCloudApproval? {
        guard state == "waiting_for_approval", let value = result?.approval, value.isValid else { return nil }
        return value
    }
}

nonisolated struct OmnixCloudFile: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let size: Int64
    let modifiedAt: Int64
    var isValid: Bool {
        OmnixCloudPolicy.fileID(id) && !name.isEmpty && name.utf16.count <= 1_000 && !name.hasPrefix("/") &&
        !name.contains("\\") && !name.contains(":") && !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) &&
        name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." } &&
        size >= 0 && size <= 25 * 1024 * 1024
    }
}

nonisolated struct OmnixCloudFiles: Decodable, Sendable { let files: [OmnixCloudFile] }
