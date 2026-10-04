import Foundation
import SwiftUI
@preconcurrency import UIKit

struct ChatMessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            UserMessageRow(message: message)
        case .assistant:
            AssistantMessageRow(message: message)
        case .system, .unknown:
            SystemMessageRow(message: message)
        }
    }
}

private struct UserMessageRow: View {
    let message: ChatMessage

    @Environment(PreferencesStore.self) private var preferences
    @State private var selectedImage: ChatPreviewImage?

    var body: some View {
        VStack(alignment: .trailing, spacing: 7) {
            let imageSources = ChatImageSources.entries(thumbnails: message.imageThumbs, images: message.images)
            if !imageSources.isEmpty {
                ChatImageGrid(sources: imageSources) { image in
                    selectedImage = image
                }
            }

            if !message.content.isEmpty {
                ChatFormattedText(
                    message.content,
                    style: .message(color: preferences.palette.textPrimary)
                )
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(
                    preferences.palette.surface,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(preferences.palette.border, lineWidth: 1)
                }
            }

            if let files = message.files, !files.isEmpty {
                AttachmentChips(files: files)
            }
        }
        .frame(maxWidth: 620, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(ChatStrings.you))
        .sheet(item: $selectedImage) { preview in
            ChatImagePreview(image: preview.image, source: preview.source)
                .id(preview.id)
        }
    }
}

private struct ChatPreviewImage: Identifiable {
    let id = UUID()
    let image: UIImage
    let source: String
}

/// UIImage is immutable here and crosses the worker boundary only after downsampling.
private nonisolated struct DecodedChatImage: @unchecked Sendable, Identifiable {
    let source: ChatImageSource
    let image: UIImage
    var id: Int { source.id }
}

private nonisolated struct ChatImageDecodeResult: @unchecked Sendable {
    let image: UIImage?
}

private struct DecodedChatImageBatch {
    let sources: [ChatImageSource]
    let images: [DecodedChatImage]
}

private struct ChatImageGrid: View {
    let sources: [ChatImageSource]
    let onOpen: (ChatPreviewImage) -> Void

    @Environment(PreferencesStore.self) private var preferences
    @State private var decoded: DecodedChatImageBatch?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 7)]
    }

    private var visibleImages: [DecodedChatImage] {
        guard let decoded, decoded.sources == sources else { return [] }
        return decoded.images
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .trailing, spacing: 7) {
            ForEach(visibleImages) { decoded in
                Button {
                    onOpen(ChatPreviewImage(image: decoded.image, source: decoded.source.fullSize))
                } label: {
                    Image(uiImage: decoded.image)
                        .resizable()
                        .scaledToFill()
                        .frame(minWidth: 104, idealWidth: 138, maxWidth: 180, minHeight: 112, maxHeight: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .stroke(preferences.palette.border, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(ChatStrings.contextRecentPhoto))
                .accessibilityValue(Text(verbatim: "\(decoded.source.id + 1)"))
            }
        }
        .frame(maxWidth: 440, alignment: .trailing)
        .task(id: sources) {
            await decodeThumbnailImages()
        }
    }

    private func decodeThumbnailImages() async {
        let sourceCopies = sources
        let worker = Task.detached(priority: .userInitiated) {
            sourceCopies.compactMap { source -> DecodedChatImage? in
                guard !Task.isCancelled else { return nil }
                guard let data = ChatImageSources.bytes(from: source.thumbnail),
                      let image = ChatAttachmentProcessor.downsampledImage(data: data, maximumEdge: 360)
                else { return nil }
                return DecodedChatImage(source: source, image: image)
            }
        }
        let images = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return }
        decoded = DecodedChatImageBatch(sources: sourceCopies, images: images)
    }
}

private struct ChatImagePreview: View {
    let image: UIImage
    let source: String

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    @State private var decodedImage: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                preferences.palette.background.ignoresSafeArea()
                Image(uiImage: decodedImage ?? image)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            }
            .task(id: source) {
                let sourceCopy = source
                let worker = Task.detached(priority: .userInitiated) {
                    guard !Task.isCancelled, let bytes = ChatImageSources.bytes(from: sourceCopy) else {
                        return ChatImageDecodeResult(image: nil)
                    }
                    return ChatImageDecodeResult(image: ChatAttachmentProcessor.downsampledImage(
                        data: bytes, maximumEdge: 1_600))
                }
                let fullImage = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                decodedImage = fullImage.image
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(Text("common.close"))
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .presentationBackground(preferences.palette.background)
    }
}

private struct AssistantMessageRow: View {
    let message: ChatMessage

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FirasBrandMark(size: 27)
                .frame(width: 28, height: 30, alignment: .top)

            VStack(alignment: .leading, spacing: 10) {
                if message.content.isEmpty, message.state == .sending {
                    FirasActivityLabel(kind: activityKind, isActive: true)
                } else {
                    ChatFormattedText(message.content, style: .assistant(color: preferences.palette.textPrimary))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    DisclosureGroup {
                        ChatFormattedText(
                            reasoning,
                            style: .reasoning(color: preferences.palette.textSecondary)
                        )
                        .padding(.top, 6)
                    } label: {
                        Label("chat.reasoning", systemImage: "brain")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(preferences.palette.textSecondary)
                            .frame(minHeight: 44)
                    }
                    .tint(preferences.palette.accent)
                }

                if message.state == .failed {
                    Label {
                        Text(ChatStrings.failed)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .accessibilityHidden(true)
                    }
                    .font(.caption)
                    .foregroundStyle(preferences.palette.error)
                } else if message.state == .stopped {
                    Label {
                        Text(ChatStrings.stopped)
                    } icon: {
                        Image(systemName: "stop.circle")
                            .accessibilityHidden(true)
                    }
                    .font(.caption)
                    .foregroundStyle(preferences.palette.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("chat.assistant")
    }

    private var activityKind: FirasActivityKind {
        let mode = message.mode?.lowercased() ?? ""
        if mode.contains("search") || mode.contains("web") || mode.contains("brain") {
            return .searching
        }
        if mode.contains("code") || mode.contains("build") || mode.contains("agent") {
            return .building
        }
        if message.reasoning?.isEmpty == false || mode.contains("think") {
            return .thinking
        }
        return .writing
    }
}

private struct SystemMessageRow: View {
    let message: ChatMessage

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        if !message.content.isEmpty {
            ChatFormattedText(
                message.content,
                style: .system(color: preferences.palette.textMuted)
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                preferences.palette.surfaceSunken.opacity(0.75),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
    }
}

private struct AttachmentChips: View {
    let files: [ChatAttachment]

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                    Label {
                        Text(file.name)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "paperclip")
                            .accessibilityHidden(true)
                    }
                    .font(.caption)
                    .foregroundStyle(preferences.palette.textSecondary)
                    .padding(.horizontal, 9)
                    .frame(minHeight: 32)
                    .background(
                        preferences.palette.surfaceSunken,
                        in: Capsule()
                    )
                    .accessibilityLabel(Text(ChatStrings.attachment))
                    .accessibilityValue(Text(verbatim: file.name))
                }
            }
        }
    }
}

private struct ChatFormattedText: View {
    let text: String
    let style: Style
    @State private var rendered: RenderedText?

    init(_ text: String, style: Style) {
        self.text = text
        self.style = style
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let rendered, rendered.source == text || (!rendered.source.isEmpty && text.hasPrefix(rendered.source)) {
                ForEach(rendered.segments) { segment in
                    switch segment.kind {
                    case .markdown(let value, let attributed):
                        if let attributed {
                            Text(attributed)
                                .font(style.font)
                                .foregroundStyle(style.color)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(value)
                                .font(style.font)
                                .foregroundStyle(style.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    case .math(let value, let inline):
                        ChatMathBlock(value: value, inline: inline)
                    }
                }
            } else {
                // Show a new value immediately until its first rich snapshot
                // is ready. Growing answers keep their previous formatting
                // during parsing so Markdown does not flicker on every poll.
                Text(verbatim: text)
                    .font(style.font)
                    .foregroundStyle(style.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
        .task(id: text) {
            guard let segments = try? await ChatTextRenderer.shared.render(text),
                  !Task.isCancelled else { return }
            rendered = RenderedText(source: text, segments: segments)
        }
    }

    private struct RenderedText {
        let source: String
        let segments: [ChatTextSegment]
    }

    struct Style {
        let font: Font
        let color: Color

        static func message(color: Color) -> Style {
            Style(font: .body, color: color)
        }

        static func assistant(color: Color) -> Style {
            Style(font: .body, color: color)
        }

        static func reasoning(color: Color) -> Style {
            Style(font: .subheadline, color: color)
        }

        static func system(color: Color) -> Style {
            Style(font: .caption, color: color)
        }
    }
}

private struct ChatMathBlock: View {
    let value: String
    let inline: Bool

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Group {
            Text(value)
                .font(inline ? .system(.footnote, design: .monospaced) : .system(.body, design: .monospaced))
                .padding(.horizontal, inline ? 8 : 12)
                .padding(.vertical, inline ? 2 : 8)
                .frame(maxWidth: inline ? nil : .infinity, alignment: .leading)
                .environment(\.layoutDirection, .leftToRight)
        }
        .foregroundStyle(preferences.palette.textPrimary)
        .background(
            preferences.palette.surfaceSunken.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(preferences.palette.border, lineWidth: 1)
        }
    }
}
