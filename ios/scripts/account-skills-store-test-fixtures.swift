import Foundation

// Only the transport/session boundaries are substituted. The production
// AccountSkillsStore and AccountSkill value types are compiled unchanged.
nonisolated enum APIError: Error, Equatable, Sendable {
    case invalidURL
    case invalidRequest(String)
    case transport(code: Int, message: String)
    case invalidResponse
    case httpStatus(code: Int, message: String)
    case skillValidation([String])
    case encoding(String)
    case decoding(String)

    var statusCode: Int? {
        if case .skillValidation = self { return 400 }
        if case .httpStatus(let value, _) = self { return value }
        return nil
    }
}

nonisolated struct MediaCredentialSnapshot: Equatable, Sendable {
    let origin: URL
    let cookieHeader: String
}

nonisolated enum MediaCredentialScope {
    @TaskLocal static var current: MediaCredentialSnapshot?
}

@MainActor final class SessionStore {
    var identityID: String? = "owner-one"
    var identityGeneration = 1
    var isAuthenticated = true
    var isWorking = false

    func transition(to owner: String?, working: Bool = false) {
        identityGeneration &+= 1
        identityID = owner
        isAuthenticated = owner != nil
        isWorking = working
    }
}

@MainActor final class FirasAPI {
    private(set) var snapshotCount = 0
    private(set) var loadCount = 0
    private(set) var saveRequests: [AccountSkillRequest] = []
    private(set) var toggleRequests: [(String, Bool)] = []
    private(set) var deleteRequests: [String] = []
    private(set) var credentialScopes: [MediaCredentialSnapshot] = []
    var holdSnapshots = false
    var snapshotFailure: APIError?
    var cookieHeader = "synthetic-owner-one"
    var pendingSnapshots: [CheckedContinuation<MediaCredentialSnapshot, Error>] = []
    var pendingLoads: [CheckedContinuation<[AccountSkill], Error>] = []
    var pendingSaves: [CheckedContinuation<AccountSkill, Error>] = []
    var pendingToggles: [CheckedContinuation<AccountSkill, Error>] = []
    var pendingDeletes: [CheckedContinuation<Void, Error>] = []

    func mediaCredentialSnapshot() async throws -> MediaCredentialSnapshot {
        snapshotCount += 1
        if let snapshotFailure { throw snapshotFailure }
        if holdSnapshots {
            return try await withCheckedThrowingContinuation { pendingSnapshots.append($0) }
        }
        return snapshot()
    }

    func accountSkills() async throws -> [AccountSkill] {
        recordScope()
        loadCount += 1
        return try await withCheckedThrowingContinuation { pendingLoads.append($0) }
    }
    func saveAccountSkill(_ request: AccountSkillRequest) async throws -> AccountSkill {
        recordScope()
        saveRequests.append(request)
        return try await withCheckedThrowingContinuation { pendingSaves.append($0) }
    }
    func setAccountSkillEnabled(id: String, enabled: Bool) async throws -> AccountSkill {
        recordScope()
        toggleRequests.append((id, enabled))
        return try await withCheckedThrowingContinuation { pendingToggles.append($0) }
    }
    func deleteAccountSkill(id: String) async throws {
        recordScope()
        deleteRequests.append(id)
        return try await withCheckedThrowingContinuation { pendingDeletes.append($0) }
    }
    func resolveSnapshot(index: Int = 0) {
        pendingSnapshots.remove(at: index).resume(returning: snapshot())
    }
    func rejectSnapshot(_ error: Error) {
        pendingSnapshots.removeFirst().resume(throwing: error)
    }
    func resolveLoad(_ skills: [AccountSkill], index: Int = 0) {
        pendingLoads.remove(at: index).resume(returning: skills)
    }
    func rejectLoad(_ error: Error) {
        pendingLoads.removeFirst().resume(throwing: error)
    }
    func resolveSave(_ skill: AccountSkill) {
        pendingSaves.removeFirst().resume(returning: skill)
    }
    func rejectSave(_ error: Error) {
        pendingSaves.removeFirst().resume(throwing: error)
    }
    func resolveToggle(_ skill: AccountSkill) {
        pendingToggles.removeFirst().resume(returning: skill)
    }
    func rejectToggle(_ error: Error) {
        pendingToggles.removeFirst().resume(throwing: error)
    }
    func resolveDelete() { pendingDeletes.removeFirst().resume(returning: ()) }
    func rejectDelete(_ error: Error) { pendingDeletes.removeFirst().resume(throwing: error) }

    private func snapshot() -> MediaCredentialSnapshot {
        MediaCredentialSnapshot(origin: URL(string: "https://synthetic.invalid")!, cookieHeader: cookieHeader)
    }
    private func recordScope() {
        guard let scope = MediaCredentialScope.current else {
            preconditionFailure("production skills call omitted frozen credential scope")
        }
        credentialScopes.append(scope)
    }
}

@MainActor final class SkillsMutationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor struct AccountSkillsFixture {
    let session = SessionStore()
    let api = FirasAPI()
    let store: AccountSkillsStore

    init() {
        store = AccountSkillsStore(session: session, api: api)
        store.synchronizeOwner()
    }
    func transition(to owner: String?, working: Bool = false) {
        session.transition(to: owner, working: working)
        api.cookieHeader = "synthetic-" + (owner ?? "signed-out")
        store.synchronizeOwner()
    }
    func ticket() -> AccountSkillsTicket {
        guard let ticket = store.operationTicket() else { preconditionFailure("fixture has no owned ticket") }
        return ticket
    }
}
