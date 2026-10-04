import Foundation
import Observation

@MainActor
@Observable
final class OmnixAccessStore {
    private(set) var ownerID: String?
    private(set) var record: OmnixAccessRecord?
    private(set) var cloud: OmnixCloudStatus?
    private(set) var isWorking = false
    private(set) var mustRefresh = false
    private(set) var failed = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let api: FirasAPI

    init(api: FirasAPI = FirasAPI()) { self.api = api }

    func invalidate() {
        generation &+= 1
        ownerID = nil
        record = nil
        cloud = nil
        isWorking = false
        mustRefresh = false
        failed = false
    }

    func refresh(owner: String?) async {
        if ownerID != owner { invalidate(); ownerID = owner }
        guard owner != nil, !isWorking else { return }
        let ticket = generation
        isWorking = true; failed = false
        defer { if ticket == generation { isWorking = false } }
        do {
            let value = try await api.omnixAccess()
            guard ticket == generation, ownerID == owner else { return }
            guard value.isValid else { throw APIError.invalidResponse }
            record = value; mustRefresh = false
            cloud = nil
            if value.status == "approved" {
                let readiness = try await api.omnixCloudStatus()
                guard ticket == generation, ownerID == owner else { return }
                cloud = readiness
            }
        } catch {
            guard ticket == generation else { return }
            failed = true
        }
    }

    func submit(reason: String, owner: String?) async {
        let request = OmnixAccessRequest(reason: reason)
        guard let owner, ownerID == owner, !isWorking, !mustRefresh,
              record?.acceptsRequest == true, request.isValid else { return }
        let ticket = generation
        isWorking = true; failed = false
        defer { if ticket == generation { isWorking = false } }
        do {
            let value = try await api.requestOmnixAccess(request)
            guard ticket == generation, ownerID == owner else { return }
            guard value.isValid else { throw APIError.invalidResponse }
            record = value
        } catch {
            guard ticket == generation else { return }
            // A lost POST response may already have saved the request. Refresh before resubmitting.
            failed = true; mustRefresh = true
        }
    }
}
