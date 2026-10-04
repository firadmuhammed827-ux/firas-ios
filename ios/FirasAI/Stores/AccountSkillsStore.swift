import Foundation
import Observation

nonisolated struct AccountSkillsTicket: Equatable, Sendable {
    let ownerID: String
    let identityGeneration: Int
    let generation: Int
}

nonisolated enum AccountSkillMutationPolicy {
    static func isDefinitiveRejection(_ error: Error) -> Bool {
        guard let failure = error as? APIError else { return false }
        switch failure {
        case .invalidURL, .invalidRequest, .encoding, .skillValidation:
            return true // Local request validation precedes transport.
        case .httpStatus(let status, let code):
            return (400...499).contains(status) && status != 408 ||
                (status == 507 && code == "storage_full")
        case .transport, .invalidResponse, .decoding:
            return false // A mutation may already have committed.
        }
    }
}

@MainActor
@Observable
final class AccountSkillsStore {
    private var storedSkills: [AccountSkill] = []
    private var unconfirmedOwners: Set<String> = []
    private(set) var isWorking = false
    private(set) var ownSkillsLoaded = false
    private(set) var uncertaintyReviewed = false
    private(set) var error: APIError?
    @ObservationIgnored private let api: FirasAPI
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private var ownerID: String?
    @ObservationIgnored private var identityGeneration = -1
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var dispatchedMutationID: UUID?
    @ObservationIgnored private var outstandingMutations: [UUID: String] = [:]

    init(session: SessionStore, api: FirasAPI = FirasAPI()) {
        self.session = session
        self.api = api
    }

    var skills: [AccountSkill] { hasCurrentIdentity ? storedSkills : [] }
    var mutationUncertain: Bool {
        guard hasCurrentIdentity, let ownerID else { return false }
        return unconfirmedOwners.contains(ownerID)
    }
    var canMutate: Bool { hasCurrentIdentity && !session.isWorking && !isWorking && !mutationUncertain }

    func synchronizeOwner() {
        let nextOwner = session.isAuthenticated ? session.identityID : nil
        let nextEpoch = session.identityGeneration
        guard ownerID != nextOwner || identityGeneration != nextEpoch else { return }
        retireDispatchedMutation()
        generation &+= 1
        if ownerID != nextOwner { storedSkills = [] }
        ownerID = nextOwner
        identityGeneration = nextEpoch
        operationID = nil
        dispatchedMutationID = nil
        ownSkillsLoaded = false
        uncertaintyReviewed = false
        error = nil
        isWorking = false
    }

    /// Capture before a queued Task. A same-ID authentication transition is
    /// still a different ticket and cannot inherit an older Save/Delete tap.
    func operationTicket() -> AccountSkillsTicket? {
        synchronizeOwner()
        guard let ownerID, hasCurrentIdentity, !session.isWorking else { return nil }
        return AccountSkillsTicket(ownerID: ownerID, identityGeneration: identityGeneration, generation: generation)
    }

    /// Retires local callbacks, never a server write. Keep the shared owner's
    /// uncertainty guard across closing and reopening a manager or editor.
    func invalidate(ticket expected: AccountSkillsTicket? = nil) {
        if let expected {
            guard ownerID == expected.ownerID, identityGeneration == expected.identityGeneration,
                  generation == expected.generation else { return }
        }
        retireDispatchedMutation()
        generation &+= 1
        operationID = nil
        dispatchedMutationID = nil
        ownSkillsLoaded = false
        uncertaintyReviewed = false
        error = nil
        isWorking = false
    }

    @discardableResult
    func load(ticket expected: AccountSkillsTicket? = nil) async -> Bool {
        synchronizeOwner()
        guard let ticket = expected ?? operationTicket(), accepts(ticket), !Task.isCancelled, !isWorking else { return false }
        let operation = UUID()
        operationID = operation
        isWorking = true
        ownSkillsLoaded = false
        uncertaintyReviewed = false
        error = nil
        // A response can be delayed after GET read the server. A review that
        // began before an older dispatched write settled is never final.
        let reviewEligible = !outstandingMutations.values.contains(ticket.ownerID)
        defer { release(operation, ticket: ticket) }
        do {
            let credentials = try await api.mediaCredentialSnapshot()
            guard owns(operation, ticket: ticket), !Task.isCancelled else { return false }
            let result = try await MediaCredentialScope.$current.withValue(credentials) {
                try await api.accountSkills()
            }
            guard owns(operation, ticket: ticket), !Task.isCancelled else { return false }
            guard result.count <= 40, Set(result.map(\.id)).count == result.count,
                  result.allSatisfy({ validRow($0) }) else { throw APIError.invalidResponse }
            storedSkills = result
            ownSkillsLoaded = true
            uncertaintyReviewed = reviewEligible && unconfirmedOwners.contains(ticket.ownerID) &&
                !outstandingMutations.values.contains(ticket.ownerID)
            return true
        } catch {
            guard owns(operation, ticket: ticket) else { return false }
            record(error, ticket: ticket)
            return false
        }
    }

    func acknowledgeUncertainMutation(ticket: AccountSkillsTicket) {
        synchronizeOwner()
        guard accepts(ticket), !isWorking, ownSkillsLoaded, uncertaintyReviewed,
              !outstandingMutations.values.contains(ticket.ownerID) else { return }
        unconfirmedOwners.remove(ticket.ownerID)
        uncertaintyReviewed = false
        error = nil
    }

    @discardableResult
    func save(_ request: AccountSkillRequest, ticket: AccountSkillsTicket) async -> AccountSkill? {
        synchronizeOwner()
        guard accepts(ticket), !Task.isCancelled, canMutate else { return nil }
        guard request.validationProblems.isEmpty else { error = .skillValidation(request.validationProblems); return nil }
        if let id = request.id, !AccountSkillRequest.permitsID(id) { error = .invalidRequest("skill_not_found"); return nil }
        let operation = reserveMutation()
        defer { release(operation, ticket: ticket) }
        do {
            let credentials = try await api.mediaCredentialSnapshot()
            guard owns(operation, ticket: ticket), !Task.isCancelled else { return nil }
            dispatchedMutationID = operation
            outstandingMutations[operation] = ticket.ownerID
            let result = try await MediaCredentialScope.$current.withValue(credentials) {
                try await api.saveAccountSkill(request)
            }
            guard owns(operation, ticket: ticket) else { return nil }
            guard !Task.isCancelled else { markUncertain(operation, ticket: ticket); return nil }
            guard validRow(result), request.id == nil || request.id == result.id,
                  storedSkills.contains(where: { $0.id == result.id }) || storedSkills.count < 40 else {
                throw APIError.invalidResponse
            }
            if let index = storedSkills.firstIndex(where: { $0.id == result.id }) { storedSkills[index] = result }
            else { storedSkills.append(result) }
            return result
        } catch {
            mutationFailure(error, operation: operation, ticket: ticket)
            return nil
        }
    }

    @discardableResult
    func setEnabled(_ skill: AccountSkill, enabled: Bool, ticket: AccountSkillsTicket) async -> Bool {
        synchronizeOwner()
        guard accepts(ticket), !Task.isCancelled, canMutate,
              storedSkills.contains(where: { $0.id == skill.id }) else { return false }
        let operation = reserveMutation()
        defer { release(operation, ticket: ticket) }
        do {
            let credentials = try await api.mediaCredentialSnapshot()
            guard owns(operation, ticket: ticket), !Task.isCancelled else { return false }
            dispatchedMutationID = operation
            outstandingMutations[operation] = ticket.ownerID
            let result = try await MediaCredentialScope.$current.withValue(credentials) {
                try await api.setAccountSkillEnabled(id: skill.id, enabled: enabled)
            }
            guard owns(operation, ticket: ticket) else { return false }
            guard !Task.isCancelled else { markUncertain(operation, ticket: ticket); return false }
            guard validRow(result), result.id == skill.id, result.enabled == enabled else { throw APIError.invalidResponse }
            if let index = storedSkills.firstIndex(where: { $0.id == result.id }) { storedSkills[index] = result }
            return true
        } catch {
            mutationFailure(error, operation: operation, ticket: ticket)
            return false
        }
    }

    @discardableResult
    func delete(_ skill: AccountSkill, ticket: AccountSkillsTicket) async -> Bool {
        synchronizeOwner()
        guard accepts(ticket), !Task.isCancelled, canMutate,
              storedSkills.contains(where: { $0.id == skill.id }) else { return false }
        let operation = reserveMutation()
        defer { release(operation, ticket: ticket) }
        do {
            let credentials = try await api.mediaCredentialSnapshot()
            guard owns(operation, ticket: ticket), !Task.isCancelled else { return false }
            dispatchedMutationID = operation
            outstandingMutations[operation] = ticket.ownerID
            try await MediaCredentialScope.$current.withValue(credentials) {
                try await api.deleteAccountSkill(id: skill.id)
            }
            guard owns(operation, ticket: ticket) else { return false }
            guard !Task.isCancelled else { markUncertain(operation, ticket: ticket); return false }
            storedSkills.removeAll { $0.id == skill.id }
            return true
        } catch {
            mutationFailure(error, operation: operation, ticket: ticket)
            return false
        }
    }

    private var hasCurrentIdentity: Bool {
        ownerID != nil && session.isAuthenticated && session.identityID == ownerID &&
            session.identityGeneration == identityGeneration
    }
    private func accepts(_ ticket: AccountSkillsTicket) -> Bool {
        hasCurrentIdentity && !session.isWorking && ownerID == ticket.ownerID &&
            identityGeneration == ticket.identityGeneration && generation == ticket.generation
    }
    private func owns(_ operation: UUID, ticket: AccountSkillsTicket) -> Bool {
        operationID == operation && accepts(ticket)
    }
    private func validRow(_ row: AccountSkill) -> Bool {
        AccountSkillRequest.permitsID(row.id) && AccountSkillRequest(skill: row, enabled: row.enabled).validationProblems.isEmpty
    }
    private func reserveMutation() -> UUID {
        let operation = UUID()
        operationID = operation
        isWorking = true
        uncertaintyReviewed = false
        error = nil
        return operation
    }
    private func markUncertain(_ operation: UUID, ticket: AccountSkillsTicket) {
        guard owns(operation, ticket: ticket), dispatchedMutationID == operation else { return }
        unconfirmedOwners.insert(ticket.ownerID)
        ownSkillsLoaded = false
        uncertaintyReviewed = false
        error = .invalidRequest("skills_mutation_unconfirmed")
    }
    private func retireDispatchedMutation() {
        guard operationID != nil, operationID == dispatchedMutationID, let ownerID else { return }
        unconfirmedOwners.insert(ownerID)
    }
    private func mutationFailure(_ failure: Error, operation: UUID, ticket: AccountSkillsTicket) {
        guard owns(operation, ticket: ticket) else { return }
        if !AccountSkillMutationPolicy.isDefinitiveRejection(failure) { markUncertain(operation, ticket: ticket) }
        record(failure, ticket: ticket)
    }
    private func record(_ failure: Error, ticket: AccountSkillsTicket) {
        guard accepts(ticket) else { return }
        if unconfirmedOwners.contains(ticket.ownerID) {
            error = .invalidRequest("skills_mutation_unconfirmed")
        } else if !(failure is CancellationError), !Task.isCancelled {
            error = (failure as? APIError) ?? .invalidResponse
        }
        if [401, 403].contains((failure as? APIError)?.statusCode ?? 0) {
            storedSkills = []
            ownSkillsLoaded = false
        }
    }
    private func release(_ operation: UUID, ticket: AccountSkillsTicket) {
        outstandingMutations.removeValue(forKey: operation)
        guard operationID == operation else { return }
        if !accepts(ticket) {
            retireDispatchedMutation()
            synchronizeOwner()
        }
        guard operationID == operation else { return }
        operationID = nil
        if dispatchedMutationID == operation { dispatchedMutationID = nil }
        isWorking = false
    }
}
