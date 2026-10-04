import Foundation

nonisolated protocol PromptEngineerAPI: Sendable {
    func mediaCredentialSnapshot() async throws -> MediaCredentialSnapshot
    func startPromptEngineer(_ request: PromptEngineerJobRequest) async throws -> PromptEngineerStart
    func promptEngineerReceipt(cid: String) async throws -> PromptEngineerReceipt
    func promptEngineerStatus(id: String) async throws -> PromptEngineerStatus
    func stopPromptEngineer(id: String) async throws -> Bool
}
