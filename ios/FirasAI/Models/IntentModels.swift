import Foundation

nonisolated struct IntentReference: Codable, Equatable, Sendable {
    let role: String
    let content: String
}

nonisolated struct IntentContext: Encodable, Sendable {
    let product: String
    let history: [IntentReference]
    let hasAttachedImage: Bool
    let hasPriorImage: Bool
    let projectFiles: [String]

    init(product: String, history: [IntentReference] = [], hasAttachedImage: Bool = false,
         hasPriorImage: Bool = false, projectFiles: [String] = []) {
        self.product = product == "code" ? "code" : "ai"
        self.history = history.filter { ["user", "assistant"].contains($0.role) }.suffix(6).map {
            IntentReference(role: $0.role, content: $0.content.count <= 2_000 ? $0.content
                : String($0.content.prefix(1_000)) + "\n[reference omitted]\n" + String($0.content.suffix(1_000)))
        }
        self.hasAttachedImage = hasAttachedImage
        self.hasPriorImage = hasPriorImage
        self.projectFiles = projectFiles.prefix(80).map { String($0.prefix(120)) }
    }
}

nonisolated struct IntentRequest: Encodable, Sendable {
    let text: String
    let context: IntentContext
}

nonisolated struct IntentDecision: Decodable, Equatable, Sendable {
    let ok: Bool
    let kind: String
    let requirements: String
    let classified: Bool
    let codeTarget: String
    let codeLanguage: String

    static let unavailable = IntentDecision(ok: false, kind: "chat", requirements: "",
        classified: false, codeTarget: "unknown", codeLanguage: "unknown")

    var isValidated: Bool {
        ok && classified && requirements.utf16.count <= 1_500 &&
        ["chat", "image", "edit-image", "video", "song", "pdf", "docx", "pptx", "xlsx", "csv", "code"].contains(kind) &&
        ["web", "source", "unknown"].contains(codeTarget) &&
        ["html", "python", "cpp", "java", "csharp", "rust", "go", "kotlin", "swift", "php", "typescript", "css", "javascript", "unknown"].contains(codeLanguage)
    }

    var permitsBrowserBuild: Bool {
        isValidated && kind == "code" && codeTarget == "web" &&
        ["html", "css", "javascript", "typescript", "unknown"].contains(codeLanguage)
    }

    func nativeMediaKind(hasAttachedImage: Bool, hasPriorImage: Bool, hasFileContext: Bool = false) -> NativeChatMediaKind? {
        guard isValidated, !hasAttachedImage, !hasPriorImage, !hasFileContext else { return nil }
        return NativeChatMediaKind(rawValue: kind)
    }

    var conversationInstruction: String {
        let base = "Answer the CURRENT user request in its language. Respect negation and quoted source material. " +
            "Use history only to resolve references; the latest request wins. Never substitute a website or HTML for an explanation, translation, native program or document. "
        guard isValidated else {
            return base + "The output type is unconfirmed. Answer ordinary questions normally; ask one concise clarification before assuming a downloadable artifact or project."
        }
        if kind == "code", codeTarget == "source", codeLanguage != "unknown" {
            return base + "The requested result is source code in \(codeLanguage). Show that source in a matching fenced block; do not claim it was executed or files were created. Constraints: \(requirements)"
        }
        if kind == "chat" {
            return base + "This turn requests an ordinary conversational answer, not an artifact. Constraints: \(requirements)"
        }
        return base + "The requested output is \(kind). This native conversation displays text and code; never claim a downloadable file or media was created without a real returned artifact. Explain the next supported step when needed. Constraints: \(requirements)"
    }
}

nonisolated enum NativeChatMediaKind: String, Equatable, Sendable {
    case image
    case video
    case music = "song"
}
