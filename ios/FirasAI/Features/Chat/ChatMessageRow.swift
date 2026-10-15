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
                .dynamicTypeSize(preferences.resolvedTypeSize)
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
                    ChatTextBlockView(segment: segment, style: style)
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
        // Copy takes the source, so steps, code and formulas paste intact
        // rather than as the text of whichever block was pressed. Share is kept
        // from the text-selection menu this replaced, under the system's label.
        .contextMenu {
            Button {
                UIPasteboard.general.string = text
            } label: {
                Label {
                    Text(ChatStrings.copy)
                } icon: {
                    Image(systemName: "doc.on.doc")
                }
            }
            ShareLink(item: text)
        } preview: {
            // A long answer lifted whole would be screens tall; the preview
            // shows its opening, while Copy and Share still take all of it.
            Text(verbatim: previewText)
                .font(style.font)
                .foregroundStyle(Color(uiColor: .label))
                .multilineTextAlignment(.leading)
                .lineLimit(12)
                .padding(16)
                .frame(maxWidth: 340, alignment: .leading)
                .background(Color(uiColor: .systemBackground))
                .environment(\.layoutDirection, previewIsRightToLeft ? .rightToLeft : .leftToRight)
        }
        .task(id: text) {
            guard let segments = try? await ChatTextRenderer.shared.render(text),
                  !Task.isCancelled else { return }
            rendered = RenderedText(source: text, segments: segments)
        }
    }

    /// The answer's opening, found without counting the whole (still growing)
    /// answer on every render. Right-to-left text starts with a right-to-left
    /// mark so a Latin first word does not flip the paragraph.
    private var previewText: String {
        let opening: String
        if let end = text.index(text.startIndex, offsetBy: 420, limitedBy: text.endIndex), end < text.endIndex {
            opening = String(text[..<end]) + "…"
        } else {
            opening = text
        }
        return previewIsRightToLeft ? "\u{200F}" + opening : opening
    }

    /// The preview reads right to left when Arabic letters at least match the
    /// other letters in the answer's opening.
    private var previewIsRightToLeft: Bool {
        var arabic = 0
        var other = 0
        for scalar in text.unicodeScalars.prefix(600) {
            if (0x0600...0x06FF).contains(scalar.value) {
                arabic += 1
            } else if scalar.properties.isAlphabetic {
                other += 1
            }
        }
        return arabic > 0 && arabic >= other
    }

    private struct RenderedText {
        let source: String
        let segments: [ChatTextSegment]
    }

    struct Style {
        let font: Font
        let color: Color
        /// Answers lay every block across the column so the block's own
        /// direction aligns it; a user bubble keeps hugging its text.
        let fillsWidth: Bool
        /// Levels 1 and 2; deeper headings are the body font, semibold.
        let titleFont: Font
        /// A display formula, one step larger than the body.
        let mathFont: Font

        func headingFont(_ level: Int) -> Font {
            level <= 2 ? titleFont : font.weight(.semibold)
        }

        static func message(color: Color) -> Style {
            Style(font: .body, color: color, fillsWidth: false, titleFont: .title3.weight(.semibold), mathFont: .title3)
        }

        static func assistant(color: Color) -> Style {
            Style(font: .body, color: color, fillsWidth: true, titleFont: .title3.weight(.semibold), mathFont: .title3)
        }

        static func reasoning(color: Color) -> Style {
            Style(
                font: .subheadline, color: color, fillsWidth: true,
                titleFont: .subheadline.weight(.semibold), mathFont: .body
            )
        }

        static func system(color: Color) -> Style {
            Style(font: .caption, color: color, fillsWidth: true, titleFont: .caption.weight(.semibold), mathFont: .footnote)
        }
    }
}

/// One Markdown block. Text draws no block structure, so headings, list
/// markers, quotes, code and tables are laid out here around inline Text.
private struct ChatTextBlockView: View {
    let segment: ChatTextSegment
    let style: ChatFormattedText.Style

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.layoutDirection) private var readerDirection

    var body: some View {
        content
            .frame(maxWidth: style.fillsWidth ? CGFloat.infinity : nil, alignment: .leading)
            .environment(\.layoutDirection, direction)
    }

    private var direction: LayoutDirection {
        guard let rightToLeft = segment.rightToLeft else { return readerDirection }
        return rightToLeft ? .rightToLeft : .leftToRight
    }

    @ViewBuilder
    private var content: some View {
        switch segment.kind {
        case .paragraph(let pieces):
            ChatTextPieces(pieces: pieces, font: style.font, style: style)
        case .heading(let level, let pieces):
            ChatTextPieces(pieces: pieces, font: style.headingFont(level), style: style)
                .accessibilityAddTraits(.isHeader)
        case .listItem(let marker, let depth, let pieces):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ZStack(alignment: .trailing) {
                    // Every marker column is two digits wide, so the text of
                    // "9.", "10.", a bullet and a later paragraph of the same
                    // item all start on one line.
                    Text(verbatim: "00.")
                        .hidden()
                        .accessibilityHidden(true)
                    // The marker is its own left-to-right run, as on the website,
                    // so "1." keeps its period after the digit in Arabic too.
                    Text(verbatim: "\u{200E}" + marker)
                }
                .font(style.font.monospacedDigit())
                .foregroundStyle(style.color)
                .frame(minWidth: 20, alignment: .trailing)
                .accessibilityHidden(marker.isEmpty)
                ChatTextPieces(pieces: pieces, font: style.font, style: style)
            }
            .padding(.leading, CGFloat(min(depth, 4)) * 20)
        case .quote(let pieces):
            ChatTextPieces(pieces: pieces, font: style.font, style: style)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(preferences.palette.border)
                        .frame(width: 3)
                }
        case .code(let language, let code):
            ChatCodeBlock(language: language, code: code, color: style.color)
        case .table(let rows):
            ChatTableBlock(rows: rows, font: style.font, headerFont: style.headingFont(3), color: style.color)
        case .rule:
            Rectangle()
                .fill(preferences.palette.border)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
    }
}

/// A block's text. Inline formulas stay inside their sentence as one Text;
/// only a display formula takes a line of its own.
private struct ChatTextPieces: View {
    let pieces: [ChatTextPiece]
    let font: Font
    let style: ChatFormattedText.Style

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(ChatTextParser.lines(pieces)) { line in
                switch line.kind {
                case .text(let attributed):
                    Text(attributed)
                        .font(font)
                        .foregroundStyle(style.color)
                        .fixedSize(horizontal: false, vertical: true)
                case .display(let formula):
                    ChatDisplayMath(
                        formula: formula,
                        font: style.mathFont,
                        color: style.color,
                        fillsWidth: style.fillsWidth
                    )
                }
            }
        }
    }
}

/// Fenced code keeps its own lines: monospaced, never reflowed, scrolled
/// sideways, and read left to right inside an Arabic answer.
private struct ChatCodeBlock: View {
    let language: String
    let code: String
    let color: Color

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !language.isEmpty {
                Text(verbatim: language)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(preferences.palette.textMuted)
            }
            ScrollView(.horizontal) {
                Text(verbatim: code)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(color)
                    .fixedSize()
                    .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            preferences.palette.surfaceSunken.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(preferences.palette.border, lineWidth: 1)
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// Pipe tables keep one line per row and one column per cell; a wide table
/// scrolls sideways instead of wrapping every word.
private struct ChatTableBlock: View {
    let rows: [ChatTableRow]
    let font: Font
    let headerFont: Font
    let color: Color

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                ForEach(rows) { row in
                    GridRow {
                        ForEach(row.cells.indices, id: \.self) { index in
                            Text(row.cells[index])
                                .font(row.isHeader ? headerFont : font)
                                .foregroundStyle(color)
                                .fixedSize()
                        }
                    }
                }
            }
            .padding(.bottom, 2)
        }
    }
}

/// A display formula owns its line: readable Unicode in the reading font,
/// centred, left to right inside an Arabic answer, and scrolled sideways
/// rather than wrapped when it is wider than the column.
private struct ChatDisplayMath: View {
    let formula: String
    let font: Font
    let color: Color
    /// A user bubble hugs its text, so the formula is not stretched there.
    let fillsWidth: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line
            ScrollView(.horizontal) {
                line
                    .padding(.bottom, 2)
            }
        }
        .frame(maxWidth: fillsWidth ? CGFloat.infinity : nil)
        .padding(.vertical, 4)
        .environment(\.layoutDirection, .leftToRight)
    }

    private var line: some View {
        // Every line starts left to right, even one of symbols alone.
        Text(verbatim: "\u{200E}" + formula.replacingOccurrences(of: "\n", with: "\n\u{200E}"))
            .font(font)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .fixedSize()
    }
}
