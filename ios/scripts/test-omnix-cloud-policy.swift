import Foundation

// Foundation-only acceptance tests. Run on a host with Swift 6.2+:
// swiftc FirasAI/Models/OmnixCloudModels.swift scripts/test-omnix-cloud-policy.swift -o /tmp/omnix-policy && /tmp/omnix-policy
@main
struct OmnixCloudPolicyTests {
    static func main() throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        let job = "omxj_" + String(repeating: "a", count: 32)
        let session = "omxs_" + String(repeating: "b", count: 32)
        let key = String(repeating: "k", count: 32)
        for value in ["../config", "https://example.test", job + "\n", job + "?url=x", "%2e%2e", ""] {
            expect(!OmnixCloudPolicy.jobID(value), "opaque job IDs reject traversal, URLs and suffixes")
        }
        expect(OmnixCloudPolicy.jobID(job), "real job shape accepted")
        expect(OmnixCloudPolicy.sessionID(session), "real session shape accepted")
        let tail = "FULL_REQUEST_TAIL"
        let brief = String(repeating: "ب", count: 60_000 - tail.utf16.count) + tail
        let request = OmnixCloudRunRequest(requestKey: key, text: brief, product: .code, sessionId: session)
        expect(request.isValid, "60000 UTF16 multilingual request accepted")
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        expect(body["text"] as? String == brief, "brief tail is preserved")
        expect(Set(body.keys) == Set(["requestKey", "text", "product", "sessionId"]), "no caller UID, model, URL or secret fields")
        expect(!OmnixCloudRunRequest(requestKey: key, text: brief + "x", product: .ai, sessionId: nil).isValid, "oversize rejected")
        expect(!OmnixCloudRunRequest(requestKey: key, text: "   ", product: .ai, sessionId: nil).isValid, "blank request rejected")
        expect(!OmnixCloudApprovalRequest(requestId: "safe-id", choice: "always").isValid, "no permanent approval")
        expect(OmnixCloudApprovalRequest(requestId: "safe-id", choice: "once").isValid, "allow once accepted")
        expect(OmnixCloudApprovalRequest(requestId: String(repeating: "a", count: 256), choice: "deny").isValid, "native 256-character approval identifier accepted")
        expect(!OmnixCloudApprovalRequest(requestId: String(repeating: "a", count: 257), choice: "deny").isValid, "oversize approval identifier rejected")
        expect(!OmnixCloudApprovalRequest(requestId: "safe-id\n", choice: "deny").isValid, "approval ID cannot include newline")
        let pointer = OmnixCloudPointer(jobId: job, sessionId: session, requestKey: key)
        let encodedPointer = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pointer)) as! [String: Any]
        expect(Set(encodedPointer.keys) == Set(["jobId", "sessionId", "requestKey"]), "pointers never persist prompts or output")
        // STORE-4: an unconfirmed submission is bounded. Unknown answers start a
        // window that survives relaunch in the pointer; once it has passed the
        // request is let go and Start returns. Only an unsent request fails at once.
        let uncertain = OmnixCloudPointer(jobId: nil, sessionId: session, requestKey: key)
        let firstUnknown = Date(timeIntervalSince1970: 1_000_000)
        let waiting = OmnixCloudPolicy.afterUnknownReceipt(uncertain, answeredAt: firstUnknown)
        expect(waiting.requestKey == key && waiting.receiptUnknownSince == firstUnknown, "the first unknown answer starts the window and keeps the request")
        let storedWaiting = try JSONSerialization.jsonObject(with: JSONEncoder().encode(waiting)) as! [String: Any]
        expect(Set(storedWaiting.keys) == Set(["sessionId", "requestKey", "receiptUnknownSince"]), "the window adds only a time to the stored identifiers")
        let relaunched = try JSONDecoder().decode(OmnixCloudPointer.self, from: JSONEncoder().encode(waiting))
        expect(relaunched == waiting, "the window start survives relaunch")
        let inside = OmnixCloudPolicy.afterUnknownReceipt(relaunched, answeredAt: firstUnknown.addingTimeInterval(179))
        expect(inside.requestKey == key && inside.receiptUnknownSince == firstUnknown, "an unknown answer inside the window neither clears nor extends it")
        let settled = OmnixCloudPolicy.afterUnknownReceipt(inside, answeredAt: firstUnknown.addingTimeInterval(OmnixCloudPolicy.unknownReceiptWindow))
        expect(settled.requestKey == nil && settled.jobId == nil && settled.sessionId == session && settled.receiptUnknownSince == nil,
               "after the window the request is let go and the session is kept")
        let rewound = OmnixCloudPolicy.afterUnknownReceipt(waiting, answeredAt: firstUnknown.addingTimeInterval(-600))
        expect(rewound.requestKey == key && rewound.receiptUnknownSince == firstUnknown.addingTimeInterval(-600),
               "a clock moved backwards restarts the window instead of extending it")
        expect(OmnixCloudPolicy.afterUnknownReceipt(pointer, answeredAt: firstUnknown) == pointer, "a pointer with a job id is not a pending receipt")
        let legacy = try JSONDecoder().decode(OmnixCloudPointer.self, from: Data("{\"sessionId\":\"\(session)\",\"requestKey\":\"\(key)\"}".utf8))
        expect(legacy.requestKey == key && legacy.receiptUnknownSince == nil, "pointers stored by earlier versions decode unchanged")
        expect(OmnixCloudPolicy.unsentTransportCodes.contains(URLError.Code.notConnectedToInternet.rawValue)
               && OmnixCloudPolicy.unsentTransportCodes.contains(URLError.Code.cannotConnectToHost.rawValue), "offline proves the request never left")
        expect(!OmnixCloudPolicy.unsentTransportCodes.contains(URLError.Code.timedOut.rawValue)
               && !OmnixCloudPolicy.unsentTransportCodes.contains(URLError.Code.networkConnectionLost.rawValue), "a timeout or a lost reply proves nothing")
        let statusJSON = """
        {"state":"ready","ready":true,"latestJob":{"jobId":"\(job)","sessionId":"\(session)","state":"completed","product":"code","requestKey":"\(key)"},"latestJobs":{"ai":{"jobId":"\(job)","sessionId":"\(session)","state":"running","product":"ai","requestKey":"\(key)"}}}
        """
        let status = try JSONDecoder().decode(OmnixCloudStatus.self, from: Data(statusJSON.utf8))
        expect(status.canRun, "readiness requires ready state")
        expect(status.latest(for: .ai)?.product == .ai, "AI recovery ignores newer Code latestJob")
        expect(status.latest(for: .code)?.product == .code, "Code can recover fallback pointer")
        let validID = String(repeating: "f", count: 64)
        for filename in ["../secret", "/private", "folder//file", "folder/./file", "folder\\file", "C:/file", "a\nfile"] {
            expect(!OmnixCloudFile(id: validID, name: filename, size: 10, modifiedAt: 1).isValid, "invalid artifact name rejected")
        }
        expect(OmnixCloudFile(id: validID, name: "notes/proof.txt", size: 25 * 1024 * 1024, modifiedAt: 1).isValid, "bounded file accepted")
        expect(!OmnixCloudFile(id: validID, name: "proof.txt", size: 25 * 1024 * 1024 + 1, modifiedAt: 1).isValid, "oversize file rejected")
        let step = OmnixCloudStep(id: "observed-1", title: "terminal", s: "unknown", observed: true, durationMs: nil, error: nil)
        let progress = OmnixCloudProgress(engine: "omnix", plan: [step, step], says: [], capture: nil)
        expect(progress.observedSteps.count == 1, "stable unique observed row identity")
        expect(progress.observedSteps[0].s == "unknown", "missing outcome never converted into success")
        expect(OmnixCloudProgress(engine: "other", plan: [step], says: [], capture: nil).observedSteps.isEmpty, "foreign progress source ignored")
        print("PASS: \(checks) Omnix cloud policy checks")
    }
}
