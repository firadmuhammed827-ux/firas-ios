import Foundation

// Run with Xcode 26's Swift compiler; this exercises production value types, not a reimplemented router.
@main
enum ClientPolicyTests {
    static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), label)
            checks += 1
        }
        func decision(_ kind: String, _ target: String, _ language: String, classified: Bool = true) -> IntentDecision {
            IntentDecision(ok: true, kind: kind, requirements: "Respect the current request.", classified: classified,
                           codeTarget: target, codeLanguage: language)
        }
        for language in ["html", "css", "javascript", "typescript", "unknown"] {
            expect(decision("code", "web", language).permitsBrowserBuild, "validated web build \(language)")
        }
        for sample in [decision("chat", "unknown", "unknown"), decision("code", "source", "python"),
                       decision("code", "source", "unknown"), decision("code", "unknown", "html"),
                       decision("code", "web", "python"), decision("pdf", "web", "html"),
                       decision("code", "web", "html", classified: false), .unavailable] {
            expect(!sample.permitsBrowserBuild, "non-web, uncertain and failed decisions cannot build HTML")
        }
        expect(!decision("site", "web", "html").isValidated, "unrecognized kind fails closed")
        expect(!decision("code", "native", "python").isValidated, "unrecognized target fails closed")
        expect(!decision("code", "source", "arbitrary").isValidated, "unrecognized language fails closed")
        for kind in ["image", "video", "song"] {
            let media = decision(kind, "unknown", "unknown")
            expect(media.nativeMediaKind(hasAttachedImage: false, hasPriorImage: false)?.rawValue == kind, "validated \(kind) can use native creation")
            expect(media.nativeMediaKind(hasAttachedImage: true, hasPriorImage: false) == nil, "attached image prevents new media interpretation")
            expect(media.nativeMediaKind(hasAttachedImage: false, hasPriorImage: true) == nil, "prior image reference prevents new media interpretation")
            expect(media.nativeMediaKind(hasAttachedImage: false, hasPriorImage: false, hasFileContext: true) == nil, "file context is never silently dropped for media generation")
        }
        for ordinary in [decision("chat", "unknown", "unknown"), decision("edit-image", "unknown", "unknown"),
                         decision("image", "unknown", "unknown", classified: false),
                         decision("image", "unrecognized", "unknown"), .unavailable] {
            expect(ordinary.nativeMediaKind(hasAttachedImage: false, hasPriorImage: false) == nil,
                   "questions, negation, image editing and unavailable classification stay conversational")
        }
        let longPrompt = String(repeating: "س", count: 59_930) + " لا تنشئ HTML؛ اشرح فقط"
        let references = (0..<9).map { IntentReference(role: $0 == 0 ? "system" : "user", content: String(repeating: "界", count: 3_000)) }
        let request = IntentRequest(text: longPrompt, context: IntentContext(product: "code", history: references,
            hasAttachedImage: true, projectFiles: (0..<100).map { "file-\($0).swift" }))
        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        expect(object["text"] as? String == longPrompt, "full multilingual request including tail is preserved")
        expect(request.context.history.count == 6, "history is bounded")
        expect(request.context.history.allSatisfy { $0.role != "system" && $0.content.count <= 2_100 }, "untrusted history cannot inject a system role")
        expect(request.context.projectFiles.count == 80, "file references are bounded")
        let malformed = Data(#"{"ok":true,"kind":"code"}"#.utf8)
        expect((try? JSONDecoder().decode(IntentDecision.self, from: malformed)) == nil, "partial response fails decoding")
        for status in ["not_requested", "rejected", "revoked", "pending", "approved"] {
            let record = OmnixAccessRecord(ok: true, status: status, reason: "", canRequest: true,
                canUse: false, available: false, requestedAt: nil, reviewedAt: nil)
            expect(record.acceptsRequest == ["not_requested", "rejected", "revoked"].contains(status), "access lifecycle \(status)")
        }
        expect(!OmnixAccessRequest(reason: String(repeating: " ", count: 20)).isValid, "blank reason is rejected")
        expect(!OmnixAccessRequest(reason: String(repeating: "a", count: 19)).isValid, "short reason is rejected")
        expect(OmnixAccessRequest(reason: String(repeating: "a", count: 20)).isValid, "minimum reason accepted")
        expect(!OmnixAccessRequest(reason: String(repeating: "😀", count: 601)).isValid, "server UTF-16 reason bound")
        for address in ["https://firasai.org", "https://www.firasai.org:443/"] {
            expect(CloudEndpointPolicy.permitsBaseURL(URL(string: address)!, development: false), "same website backend")
        }
        for address in ["http://firasai.org", "https://firasai.org.evil.example", "https://firasai.org:444", "https://other.example",
                        "https://user:password@firasai.org", "https://firasai.org/?token=value", "https://firasai.org/#key", "http://localhost:1988"] {
            expect(!CloudEndpointPolicy.permitsBaseURL(URL(string: address)!, development: false), "release endpoint rejects \(address)")
        }
        expect(CloudEndpointPolicy.permitsBaseURL(URL(string: "http://localhost:1988")!, development: true), "explicit local debug works")
        let origin = URL(string: "https://firasai.org")!
        expect(CloudEndpointPolicy.isSameOrigin(URL(string: "https://firasai.org:443/api/chats")!, as: origin), "same-origin redirect")
        for address in ["http://firasai.org/api", "https://other.example/api", "https://firasai.org:8443/api", "https://name@firasai.org/api"] {
            expect(!CloudEndpointPolicy.isSameOrigin(URL(string: address)!, as: origin), "redirect credentials remain on original origin")
        }
        print("PASS: \(checks) native client policy checks")
    }
}
