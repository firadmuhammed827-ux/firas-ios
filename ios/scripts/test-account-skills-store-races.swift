import Foundation

@main
@MainActor enum AccountSkillsStoreRaceTests {
    static func main() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label)
            checks += 1
        }
        let oldSkill = sample(id: "usk-1111111111111111", name: "Old account", enabled: true)
        let newSkill = sample(id: "usk-2222222222222222", name: "New account", enabled: false)
        let edited = sample(id: oldSkill.id, name: "Owned edited skill", enabled: false)
        let createRequest = AccountSkillRequest(name: "New own skill", cues: oldSkill.cues, rules: oldSkill.rules)

        // Current GET wins, even when an earlier owner's GET arrives last.
        do {
            let f = AccountSkillsFixture()
            let oldTicket = f.ticket()
            let oldLoad = Task { await f.store.load(ticket: oldTicket) }
            try await waitUntil { f.api.pendingLoads.count == 1 }
            f.transition(to: "owner-two")
            let newTicket = f.ticket()
            let newLoad = Task { await f.store.load(ticket: newTicket) }
            try await waitUntil { f.api.pendingLoads.count == 2 }
            f.api.resolveLoad([newSkill], index: 1)
            let newAccepted = await newLoad.value
            f.api.resolveLoad([oldSkill])
            let oldAccepted = await oldLoad.value
            expect(newAccepted && !oldAccepted, "only the current owner GET is a reconciliation signal")
            expect(f.store.skills == [newSkill], "late GET cannot disclose old owner rows")
            expect(f.store.error == nil && !f.store.isWorking, "late GET cannot change current error/busy state")
            expect(!f.store.mutationUncertain, "retiring GET does not imply a write")
        }

        // Every tap ticket is captured BEFORE the queued Task. The identical
        // row remains present so rejection must come from the session epoch.
        for changeOwner in [false, true] {
            let f = AccountSkillsFixture()
            try await load([oldSkill], fixture: f)
            let captured = f.ticket()
            let gate = SkillsMutationGate()
            let queued = Task {
                await gate.wait()
                let saved = await f.store.save(AccountSkillRequest(skill: oldSkill, enabled: false), ticket: captured)
                let toggled = await f.store.setEnabled(oldSkill, enabled: false, ticket: captured)
                let deleted = await f.store.delete(oldSkill, ticket: captured)
                let refreshed = await f.store.load(ticket: captured)
                return saved == nil && !toggled && !deleted && !refreshed
            }
            try await waitUntil { gate.isWaiting }
            f.transition(to: changeOwner ? "owner-two" : "owner-one")
            try await load([oldSkill], fixture: f)
            let snapshots = f.api.snapshotCount
            gate.release()
            let rejected = await queued.value
            expect(rejected, "queued old owner/epoch work is rejected")
            expect(f.api.saveRequests.isEmpty && f.api.toggleRequests.isEmpty && f.api.deleteRequests.isEmpty,
                   "no queued retired tap reaches a mutation endpoint")
            expect(f.api.snapshotCount == snapshots, "retired tickets do not even request credentials")
            expect(f.store.skills == [oldSkill] && f.store.canMutate, "retired tap does not lock or edit current rows")
        }

        // Closing before a queued Task begins also retires its immutable ticket.
        do {
            let f = AccountSkillsFixture()
            let captured = f.ticket()
            f.store.invalidate()
            let rejected = await f.store.save(createRequest, ticket: captured)
            expect(rejected == nil && f.api.saveRequests.isEmpty, "dismissed queued Save performs no POST")
            expect(!f.store.mutationUncertain, "a never-dispatched Save needs no uncertainty review")
        }

        do {
            let f = AccountSkillsFixture()
            let captured = f.ticket()
            let gate = SkillsMutationGate()
            let queued = Task {
                await gate.wait()
                return await f.store.save(createRequest, ticket: captured)
            }
            try await waitUntil { gate.isWaiting }
            queued.cancel()
            gate.release()
            let accepted = await queued.value
            expect(accepted == nil && f.api.snapshotCount == 0 && !f.store.mutationUncertain,
                   "pre-cancelled queued tap is rejected before credential or mutation dispatch")
        }

        // The credential actor is a real await boundary. Recheck the ticket
        // AFTER it returns for GET, POST, PATCH and DELETE.
        for action in 0..<4 {
            let f = AccountSkillsFixture()
            try await load([oldSkill], fixture: f)
            f.api.holdSnapshots = true
            let captured = f.ticket()
            let pending = Task {
                switch action {
                case 0: return await f.store.load(ticket: captured)
                case 1: return await f.store.save(createRequest, ticket: captured) != nil
                case 2: return await f.store.setEnabled(oldSkill, enabled: false, ticket: captured)
                default: return await f.store.delete(oldSkill, ticket: captured)
                }
            }
            try await waitUntil { f.api.pendingSnapshots.count == 1 }
            f.transition(to: "owner-one")
            f.api.resolveSnapshot()
            let accepted = await pending.value
            expect(!accepted, "credential await cannot inherit a replacement same-ID epoch")
            expect(f.api.loadCount == 1 && f.api.saveRequests.isEmpty && f.api.toggleRequests.isEmpty && f.api.deleteRequests.isEmpty,
                   "post-snapshot epoch guard precedes every endpoint and dispatch marker")
            expect(!f.store.mutationUncertain && f.store.canMutate, "retired pre-dispatch credential work has no uncertain write")
        }

        // All actual GET/write calls inherit the captured TaskLocal scope.
        do {
            let f = AccountSkillsFixture()
            try await load([oldSkill], fixture: f)
            let toggleTicket = f.ticket()
            let toggle = Task { await f.store.setEnabled(oldSkill, enabled: false, ticket: toggleTicket) }
            try await waitUntil { f.api.pendingToggles.count == 1 }
            f.api.resolveToggle(edited)
            let toggled = await toggle.value
            let saveTicket = f.ticket()
            let save = Task { await f.store.save(AccountSkillRequest(skill: edited, enabled: true), ticket: saveTicket) }
            try await waitUntil { f.api.pendingSaves.count == 1 }
            let savedRow = sample(id: oldSkill.id, name: edited.name, enabled: true)
            f.api.resolveSave(savedRow)
            let saved = await save.value
            let deleteTicket = f.ticket()
            let deletion = Task { await f.store.delete(savedRow, ticket: deleteTicket) }
            try await waitUntil { f.api.pendingDeletes.count == 1 }
            f.api.resolveDelete()
            let deleted = await deletion.value
            expect(toggled && saved == savedRow && deleted, "owned validated acknowledgements are returned to UI")
            expect(f.api.credentialScopes.count == 4, "GET and all three writes use the captured credential scope")
            expect(f.api.credentialScopes.allSatisfy { $0.cookieHeader == "synthetic-owner-one" },
                   "TaskLocal scope carries one captured credential identity")
            expect(f.store.skills.isEmpty && !f.store.mutationUncertain, "acknowledged mutations settle without a review guard")
            expect(MediaCredentialScope.current == nil, "owned scope never leaks into later unrelated Tasks")
        }

        // A stale save must not release a newer owner's in-flight GET.
        do {
            let f = AccountSkillsFixture()
            try await load([oldSkill], fixture: f)
            let captured = f.ticket()
            let oldSave = Task { await f.store.save(AccountSkillRequest(skill: oldSkill, enabled: false), ticket: captured) }
            try await waitUntil { f.api.pendingSaves.count == 1 }
            f.transition(to: "owner-two")
            let newTicket = f.ticket()
            let newer = Task { await f.store.load(ticket: newTicket) }
            try await waitUntil { f.api.pendingLoads.count == 1 }
            f.api.resolveSave(edited)
            let accepted = await oldSave.value
            expect(accepted == nil && f.store.skills.isEmpty, "old save cannot insert a foreign row")
            expect(f.store.isWorking, "old defer does not unlock newer GET")
            f.api.resolveLoad([newSkill])
            _ = await newer.value
            expect(f.store.skills == [newSkill] && !f.store.mutationUncertain, "new owner does not inherit old owner's uncertainty")
            f.transition(to: "owner-one")
            expect(f.store.mutationUncertain, "the original owner's retired write still requires owned review")
        }

        // Same-ID epoch and account A -> B -> A both reject delayed callbacks.
        for switchAway in [false, true] {
            let f = AccountSkillsFixture()
            try await load([oldSkill], fixture: f)
            let captured = f.ticket()
            let toggle = Task { await f.store.setEnabled(oldSkill, enabled: false, ticket: captured) }
            try await waitUntil { f.api.pendingToggles.count == 1 }
            if switchAway { f.transition(to: "owner-two") }
            f.transition(to: "owner-one")
            let refreshed = sample(id: oldSkill.id, name: "Refreshed current epoch", enabled: true)
            try await load([refreshed], fixture: f)
            f.api.resolveToggle(edited)
            let accepted = await toggle.value
            expect(!accepted && f.store.skills == [refreshed], "retired same-owner response cannot replace fresh rows")
            expect(f.store.mutationUncertain && !f.store.canMutate, "retired dispatched write cannot silently permit another write")
            expect(!f.store.uncertaintyReviewed, "review begun with old transport pending is insufficient")
        }

        // Read live session identity even before a SwiftUI observer synchronizes
        // the shared store; same account ID alone never authorizes a callback.
        do {
            let f = AccountSkillsFixture()
            try await load([oldSkill], fixture: f)
            let captured = f.ticket()
            let save = Task { await f.store.save(AccountSkillRequest(skill: oldSkill, enabled: false), ticket: captured) }
            try await waitUntil { f.api.pendingSaves.count == 1 }
            f.session.transition(to: "owner-one") // Deliberately no store synchronization.
            expect(f.store.skills.isEmpty && !f.store.canMutate, "stale epoch rows are hidden synchronously by live session reads")
            f.api.resolveSave(edited)
            let accepted = await save.value
            expect(accepted == nil && f.store.skills == [oldSkill], "late same-ID result cannot restore edited content before observer runs")
            expect(f.store.mutationUncertain && !f.store.canMutate, "defer adopts current epoch while preserving retired write uncertainty")
        }

        // Two queued Save taps cannot pass the same admission while the first
        // one is awaiting its credential actor or server acknowledgement.
        do {
            let f = AccountSkillsFixture()
            f.api.holdSnapshots = true
            let ticket = f.ticket()
            let first = Task { await f.store.save(createRequest, ticket: ticket) }
            try await waitUntil { f.api.pendingSnapshots.count == 1 }
            let second = await f.store.save(createRequest, ticket: ticket)
            expect(second == nil && f.api.snapshotCount == 1, "reserved Save rejects another tap before snapshot await completes")
            f.api.resolveSnapshot()
            try await waitUntil { f.api.pendingSaves.count == 1 }
            f.api.resolveSave(newSkill)
            let accepted = await first.value
            expect(accepted == newSkill && f.api.saveRequests.count == 1, "one owned admission produces exactly one POST")
        }

        // A lost create response blocks ALL mutation paths without replay.
        do {
            let f = AccountSkillsFixture()
            try await load([oldSkill], fixture: f)
            let captured = f.ticket()
            let creation = Task { await f.store.save(createRequest, ticket: captured) }
            try await waitUntil { f.api.pendingSaves.count == 1 }
            f.api.rejectSave(APIError.transport(code: -1001, message: "synthetic timeout"))
            let result = await creation.value
            expect(result == nil && f.store.skills == [oldSkill], "lost create response retains current rows and no accepted result")
            expect(f.store.mutationUncertain && !f.store.canMutate && !f.store.isWorking, "uncertainty releases busy state but blocks writes")
            expect(f.store.error == .invalidRequest("skills_mutation_unconfirmed"), "UI receives a controlled uncertainty code")
            let ticket = f.ticket()
            let saved = await f.store.save(createRequest, ticket: ticket)
            let toggled = await f.store.setEnabled(oldSkill, enabled: false, ticket: ticket)
            let deleted = await f.store.delete(oldSkill, ticket: ticket)
            expect(saved == nil && !toggled && !deleted, "unknown create admission blocks every subsequent write")
            expect(f.api.saveRequests.count == 1 && f.api.toggleRequests.isEmpty && f.api.deleteRequests.isEmpty,
                   "no mutation is automatically retried or implicitly authorized")
            f.store.acknowledgeUncertainMutation(ticket: ticket)
            expect(f.store.mutationUncertain, "acknowledgement without a successful current GET is rejected")

            for failure in [APIError.httpStatus(code: 503, message: "unavailable"), .invalidResponse] {
                let refresh = Task { await f.store.load(ticket: ticket) }
                try await waitUntil { f.api.pendingLoads.count == 1 }
                f.api.rejectLoad(failure)
                let refreshed = await refresh.value
                f.store.acknowledgeUncertainMutation(ticket: ticket)
                expect(!refreshed && !f.store.ownSkillsLoaded && f.store.mutationUncertain, "failed review cannot authorize another Save")
            }
            let canceledReview = Task { await f.store.load(ticket: ticket) }
            try await waitUntil { f.api.pendingLoads.count == 1 }
            canceledReview.cancel()
            f.api.resolveLoad([newSkill])
            let canceledAccepted = await canceledReview.value
            f.store.acknowledgeUncertainMutation(ticket: ticket)
            expect(!canceledAccepted && f.store.mutationUncertain && !f.store.uncertaintyReviewed, "cancelled GET cannot clear uncertainty")

            f.store.invalidate() // Close and reopen the shared manager.
            expect(f.store.mutationUncertain && !f.store.canMutate, "dismissal preserves unconfirmed owner state")
            try await load([oldSkill, newSkill], fixture: f)
            expect(f.store.uncertaintyReviewed && f.store.mutationUncertain, "successful owned GET alone does not authorize writes")
            let reviewedTicket = f.ticket()
            f.store.acknowledgeUncertainMutation(ticket: reviewedTicket)
            expect(!f.store.mutationUncertain && f.store.canMutate && f.store.error == nil, "explicit current review acknowledgement allows changes")
            expect(f.api.saveRequests.count == 1, "list review and acknowledgement perform no replay")
        }

        // GET can capture the old list while a dismissed POST is still pending.
        // Even if POST ends before that delayed GET returns, require a NEW GET.
        do {
            let f = AccountSkillsFixture()
            let originalTicket = f.ticket()
            let creation = Task { await f.store.save(createRequest, ticket: originalTicket) }
            try await waitUntil { f.api.pendingSaves.count == 1 }
            f.store.invalidate(ticket: originalTicket)
            let ticket = f.ticket()
            let tooEarly = Task { await f.store.load(ticket: ticket) }
            try await waitUntil { f.api.pendingLoads.count == 1 }
            f.api.resolveSave(newSkill)
            let retiredAccepted = await creation.value
            f.api.resolveLoad([]) // Server snapshot was taken before POST committed.
            let earlyLoaded = await tooEarly.value
            f.store.acknowledgeUncertainMutation(ticket: ticket)
            expect(retiredAccepted == nil && earlyLoaded, "retired write result is inert while GET remains a real read")
            expect(f.store.mutationUncertain && !f.store.uncertaintyReviewed && !f.store.canMutate,
                   "pre-settlement GET cannot become review just because its response arrives later")
            try await load([newSkill], fixture: f)
            expect(f.store.skills == [newSkill] && f.store.uncertaintyReviewed, "new GET after old transport settles reviews actual committed skill")
            f.store.acknowledgeUncertainMutation(ticket: f.ticket())
            expect(f.store.canMutate && f.api.saveRequests.count == 1, "reopen recovery never duplicates creation")
        }

        // Cancellation after dispatch is unknown, including a late success.
        for action in 0..<3 {
            let f = AccountSkillsFixture()
            try await load([oldSkill], fixture: f)
            let ticket = f.ticket()
            let mutation = Task {
                switch action {
                case 0: return await f.store.save(createRequest, ticket: ticket) != nil
                case 1: return await f.store.setEnabled(oldSkill, enabled: false, ticket: ticket)
                default: return await f.store.delete(oldSkill, ticket: ticket)
                }
            }
            try await waitUntil { f.api.pendingSaves.count + f.api.pendingToggles.count + f.api.pendingDeletes.count == 1 }
            mutation.cancel()
            switch action {
            case 0: f.api.resolveSave(newSkill)
            case 1: f.api.resolveToggle(edited)
            default: f.api.resolveDelete()
            }
            let accepted = await mutation.value
            expect(!accepted && f.store.skills == [oldSkill], "cancelled mutation callback cannot edit current displayed rows")
            expect(f.store.mutationUncertain && !f.store.canMutate, "cancelled dispatched write needs owned review")
            expect(f.api.saveRequests.count + f.api.toggleRequests.count + f.api.deleteRequests.count == 1, "cancellation performs no write replay")
        }
        do {
            let f = AccountSkillsFixture()
            let ticket = f.ticket()
            let creation = Task { await f.store.save(createRequest, ticket: ticket) }
            try await waitUntil { f.api.pendingSaves.count == 1 }
            f.api.rejectSave(CancellationError())
            let accepted = await creation.value
            expect(accepted == nil && f.store.mutationUncertain, "transport cancellation after dispatch also requires review")
        }

        // Cancellation/credential failure BEFORE dispatch never needs review.
        do {
            let f = AccountSkillsFixture()
            f.api.holdSnapshots = true
            let ticket = f.ticket()
            let creation = Task { await f.store.save(createRequest, ticket: ticket) }
            try await waitUntil { f.api.pendingSnapshots.count == 1 }
            creation.cancel()
            f.api.resolveSnapshot()
            let accepted = await creation.value
            expect(accepted == nil && f.api.saveRequests.isEmpty, "cancelled credential capture cannot dispatch a POST")
            expect(!f.store.mutationUncertain && f.store.canMutate, "no dispatched mutation means no uncertainty")
            f.api.holdSnapshots = false
            f.api.snapshotFailure = .invalidRequest("media_session_required")
            let rejected = await f.store.save(createRequest, ticket: f.ticket())
            expect(rejected == nil && f.api.saveRequests.isEmpty && f.store.canMutate, "credential capture rejection leaves an editable draft")
        }

        // Actual API error classes determine whether acceptance is impossible.
        let uncertainFailures: [any Error] = [
            APIError.httpStatus(code: 408, message: "timeout"),
            APIError.httpStatus(code: 500, message: "unavailable"),
            APIError.httpStatus(code: 503, message: "unavailable"),
            APIError.invalidResponse, APIError.decoding("synthetic"),
            APIError.transport(code: -1005, message: "synthetic connection loss")
        ]
        for failure in uncertainFailures {
            let f = AccountSkillsFixture()
            let ticket = f.ticket()
            let creation = Task { await f.store.save(createRequest, ticket: ticket) }
            try await waitUntil { f.api.pendingSaves.count == 1 }
            f.api.rejectSave(failure)
            let accepted = await creation.value
            expect(accepted == nil && f.store.mutationUncertain && !f.store.canMutate, "ambiguous transport/server/response failure blocks a fresh POST")
            expect(f.api.saveRequests.count == 1, "ambiguous error never retries")
        }
        let definitiveFailures: [APIError] = [
            .httpStatus(code: 400, message: "invalid_skill"),
            .httpStatus(code: 401, message: "auth"),
            .httpStatus(code: 403, message: "auth"),
            .httpStatus(code: 404, message: "skill_not_found"),
            .httpStatus(code: 409, message: "account_full"),
            .httpStatus(code: 429, message: "rate"),
            .httpStatus(code: 507, message: "storage_full"),
            .skillValidation(["rule_too_short:2"]), .encoding("synthetic"),
            .invalidRequest("invalid_skill"), .invalidURL
        ]
        for failure in definitiveFailures {
            let f = AccountSkillsFixture()
            try await load([oldSkill], fixture: f)
            let ticket = f.ticket()
            let creation = Task { await f.store.save(createRequest, ticket: ticket) }
            try await waitUntil { f.api.pendingSaves.count == 1 }
            f.api.rejectSave(failure)
            let accepted = await creation.value
            expect(accepted == nil && !f.store.mutationUncertain && f.store.canMutate, "definitive rejection does not require uncertainty acknowledgement")
            if failure.statusCode == 401 || failure.statusCode == 403 {
                expect(f.store.skills.isEmpty, "current authorization rejection clears private rows")
            } else {
                expect(f.store.skills == [oldSkill], "definitive rejection preserves original rows")
            }
            expect(f.api.saveRequests.count == 1, "definitive rejection also never automatically replays")
        }

        // A response with a wrong target ID is not a valid acceptance.
        do {
            let f = AccountSkillsFixture()
            try await load([oldSkill], fixture: f)
            let ticket = f.ticket()
            let save = Task { await f.store.save(AccountSkillRequest(skill: oldSkill, enabled: false), ticket: ticket) }
            try await waitUntil { f.api.pendingSaves.count == 1 }
            f.api.resolveSave(newSkill)
            let accepted = await save.value
            expect(accepted == nil && f.store.skills == [oldSkill] && f.store.mutationUncertain, "mismatched saved ID cannot overwrite another row or permit a duplicate write")
        }
        do {
            let f = AccountSkillsFixture()
            try await load([oldSkill], fixture: f)
            let ticket = f.ticket()
            let toggle = Task { await f.store.setEnabled(oldSkill, enabled: false, ticket: ticket) }
            try await waitUntil { f.api.pendingToggles.count == 1 }
            f.api.resolveToggle(oldSkill) // Wrong enabled acknowledgement.
            let accepted = await toggle.value
            expect(!accepted && f.store.skills == [oldSkill] && f.store.mutationUncertain, "mismatched enabled response requires review")
        }

        // Successful Save returns the canonical row so a later edited draft
        // can preserve the accepted ID rather than silently POST a second copy.
        do {
            let f = AccountSkillsFixture()
            let ticket = f.ticket()
            let creation = Task { await f.store.save(createRequest, ticket: ticket) }
            try await waitUntil { f.api.pendingSaves.count == 1 }
            f.api.resolveSave(newSkill)
            let accepted = await creation.value
            expect(accepted == newSkill && f.store.skills == [newSkill], "new Save returns actual accepted row identity")
            let next = AccountSkillRequest(id: accepted?.id, name: "Later draft edit", cues: oldSkill.cues, rules: oldSkill.rules)
            let laterTicket = f.ticket()
            let later = Task { await f.store.save(next, ticket: laterTicket) }
            try await waitUntil { f.api.pendingSaves.count == 1 }
            f.api.resolveSave(sample(id: newSkill.id, name: next.name, enabled: true))
            _ = await later.value
            expect(f.api.saveRequests.last?.id == newSkill.id && f.store.skills.count == 1,
                   "explicit later edit uses accepted identity without appending a duplicate skill")
        }

        // A successful empty list is authoritative; quiet GET cancellation is
        // not an empty list and cannot retire valid selected skill pins.
        do {
            let f = AccountSkillsFixture()
            let ticket = f.ticket()
            let empty = Task { await f.store.load(ticket: ticket) }
            try await waitUntil { f.api.pendingLoads.count == 1 }
            f.api.resolveLoad([])
            let emptyAccepted = await empty.value
            expect(emptyAccepted && f.store.ownSkillsLoaded, "successful empty GET can reconcile deleted pins")
            let canceled = Task { await f.store.load(ticket: ticket) }
            try await waitUntil { f.api.pendingLoads.count == 1 }
            f.api.rejectLoad(CancellationError())
            let cancellationAccepted = await canceled.value
            expect(!cancellationAccepted && f.store.error == nil && !f.store.ownSkillsLoaded,
                   "quiet GET cancellation cannot masquerade as a current empty catalogue")
        }
        do {
            let f = AccountSkillsFixture()
            let ticket = f.ticket()
            let invalid = Task { await f.store.load(ticket: ticket) }
            try await waitUntil { f.api.pendingLoads.count == 1 }
            f.api.resolveLoad([oldSkill, oldSkill])
            let loaded = await invalid.value
            expect(!loaded && !f.store.ownSkillsLoaded && !f.store.uncertaintyReviewed, "duplicate IDs are not an authoritative reviewed list")
        }

        // Local validation, guests, and a busy session cannot dispatch writes.
        do {
            let f = AccountSkillsFixture()
            let invalid = AccountSkillRequest(name: "x", cues: [], rules: [])
            let rejected = await f.store.save(invalid, ticket: f.ticket())
            expect(rejected == nil && f.api.snapshotCount == 0 && !f.store.mutationUncertain, "local input rejection precedes transport")
            let ticket = f.ticket()
            f.session.isWorking = true
            let busy = await f.store.save(createRequest, ticket: ticket)
            expect(busy == nil && f.api.saveRequests.isEmpty && f.store.operationTicket() == nil, "busy authentication cannot capture or dispatch a mutation")
            f.session.isWorking = false
            f.transition(to: nil)
            expect(f.store.skills.isEmpty && !f.store.canMutate && f.store.operationTicket() == nil, "signed-out state exposes no owner rows or mutation ticket")
        }
        print("CLEAN: \(checks) production AccountSkillsStore identity/uncertainty/credential checks")
    }

    private static func sample(id: String, name: String, enabled: Bool) -> AccountSkill {
        AccountSkill(id: id, name: name, cues: ["report", "research", "study"],
                     rules: (1...4).map { "Rule \($0): write clear explanations and verify the final result." },
                     mode: .auto, enabled: enabled)
    }
    private static func load(_ skills: [AccountSkill], fixture f: AccountSkillsFixture) async throws {
        let ticket = f.ticket()
        let loading = Task { await f.store.load(ticket: ticket) }
        try await waitUntil { f.api.pendingLoads.count == 1 }
        f.api.resolveLoad(skills)
        let accepted = await loading.value
        precondition(accepted, "fixture owned GET was rejected")
    }
    private static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(4))
        }
        preconditionFailure("test operation did not reach its synchronization point")
    }
}
