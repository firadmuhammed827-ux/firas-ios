import SwiftUI
@preconcurrency import UIKit

/// One attached photo or file as the composer lists it. The screen builds
/// these from its draft context; the composer only draws them and reports
/// which one the reader removed.
nonisolated struct ComposerAttachment: Identifiable, Sendable {
    nonisolated enum Kind: Equatable, Sendable {
        case image
        case file
    }

    let id: String
    let kind: Kind
    /// The file name; empty for a photo.
    let name: String
    /// The prepared JPEG of a photo; nil for a file or while still preparing.
    let imageData: Data?
    let isProcessing: Bool
}

struct ChatComposer: View {
    @Binding var draft: String
    @FocusState.Binding var isFocused: Bool
    let isSending: Bool
    let isPreparing: Bool
    let selectedTier: ModelTier
    let contextCount: Int
    let hasReadyContext: Bool
    let selectedSkills: [AccountSkill]
    let promptEngineerRecognized: Bool
    let promptEngineerReady: Bool
    let promptEngineerBusy: Bool
    let onPromptEngineerLanguage: (String) -> Void
    let onRemoveSkill: (String) -> Void
    let onAddContext: () -> Void
    let onDraftChanged: () -> Void
    let onSelectModel: () -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    let onStartCall: () -> Void
    /// The attached photos and files, each removable on its own. Defaulted so
    /// a caller that does not list them keeps the count badge alone.
    var attachments: [ComposerAttachment] = []
    var onRemoveAttachment: (String) -> Void = { _ in }

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var controlSpace

    /// At rest the composer is one capsule row: +, the field, the primary
    /// action. Focus, a draft, a pinned skill or an attachment opens it into
    /// the full card with the model button underneath.
    private var isExpanded: Bool {
        isFocused || !draft.isEmpty || !selectedSkills.isEmpty || !attachments.isEmpty
            || promptEngineerRecognized
    }

    var body: some View {
        // The field stays on a quiet material surface; only its controls are
        // glass, so one glass layer never has to sample another. The radius is
        // the 22pt control radius plus the 8pt inset, so corners stay concentric.
        GlassSurface(cornerRadius: 30, tintStrength: 0.045, usesLiquidGlass: false) {
            FirasGlassControlGroup(spacing: 8) {
                VStack(spacing: 4) {
                    if isExpanded && !selectedSkills.isEmpty {
                        selectedSkillRow
                    }
                    if isExpanded && !attachments.isEmpty {
                        attachmentRow
                    }
                    // messageField keeps one position in this row in both states,
                    // so expanding never replaces the field or drops the keyboard.
                    HStack(spacing: 4) {
                        if !isExpanded {
                            contextButton
                                .matchedGeometryEffect(id: ComposerSlot.context, in: controlSpace)
                        }
                        messageField
                        if !isExpanded {
                            primaryAction
                                .animation(primaryActionAnimation, value: primaryActionState)
                                .matchedGeometryEffect(id: ComposerSlot.primary, in: controlSpace)
                        }
                    }
                    if isExpanded {
                        actionRow
                    }
                }
                .padding(8)
            }
            .frame(maxWidth: 760)
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .animation(expansionAnimation, value: isExpanded)
    }

    private var messageField: some View {
        TextField("chat.placeholder", text: $draft, axis: .vertical)
            .font(.body)
            .foregroundStyle(preferences.palette.textPrimary)
            .tint(preferences.palette.accent)
            .lineLimit(1 ... 6)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minHeight: 44)
            .focused($isFocused)
            // Never disabled: a disabled field resigns focus, which closes the
            // keyboard and folds the card after every Send. The screen's draft
            // binding refuses edits while a Send is being prepared instead.
            .submitLabel(preferences.sendOnReturn ? .send : .return)
            .onSubmit {
                guard preferences.sendOnReturn, canSend, !isSending, !promptEngineerRecognized, !promptEngineerBusy else { return }
                onSend()
            }
            .onChange(of: draft) {
                onDraftChanged()
            }
    }

    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                contextButton
                    .matchedGeometryEffect(id: ComposerSlot.context, in: controlSpace)
                modelButton
                Spacer(minLength: 8)
                primaryAction
                    .animation(primaryActionAnimation, value: primaryActionState)
                    .matchedGeometryEffect(id: ComposerSlot.primary, in: controlSpace)
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    contextButton
                    modelButton
                    Spacer(minLength: 8)
                }
                HStack {
                    Spacer(minLength: 0)
                    primaryAction
                        .animation(primaryActionAnimation, value: primaryActionState)
                }
            }
        }
    }

    private var selectedSkillRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(selectedSkills) { skill in
                    Button { onRemoveSkill(skill.id) } label: {
                        HStack(spacing: 6) {
                            Text(verbatim: skill.name).lineLimit(1)
                            Image(systemName: "xmark").font(.caption2.weight(.bold))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(preferences.palette.accent)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .background(preferences.palette.accent.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending)
                    .accessibilityLabel(Text(verbatim: skill.name))
                    .accessibilityHint(Text(ChatStrings.removeSkill))
                }
            }
        }
        .padding(.horizontal, 8)
    }

    /// Built like the skill row: one chip per photo or file, and the chip
    /// itself removes that item only.
    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ComposerAttachmentChip(attachment: attachment) {
                        onRemoveAttachment(attachment.id)
                    }
                    .disabled(isSending)
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private var contextButton: some View {
        Button(action: onAddContext) {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
                .overlay(alignment: .topTrailing) {
                    if contextCount > 0 {
                        Text(verbatim: "\(contextCount)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(preferences.palette.onAccent)
                            .frame(minWidth: 17, minHeight: 17)
                            .background(preferences.palette.accent, in: Capsule())
                            .offset(x: 1, y: 1)
                            .accessibilityHidden(true)
                    } else if preferences.webSearchEnabled || preferences.thinkingEnabled {
                        Circle()
                            .fill(preferences.palette.accent)
                            .frame(width: 7, height: 7)
                            .offset(x: -4, y: 5)
                            .accessibilityHidden(true)
                    }
                }
        }
        .modifier(FirasGlassControlStyle(circular: true))
        .accessibilityLabel(Text(ChatStrings.context))
        .disabled(isPreparing)
        .accessibilityValue(
            contextCount > 0
                ? Text(verbatim: "\(contextCount)")
                : Text(verbatim: "")
        )
    }

    private var modelButton: some View {
        Button(action: onSelectModel) {
            HStack(spacing: 6) {
                Text(verbatim: preferences.modelLabel(for: selectedTier))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(preferences.palette.textPrimary)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(.capsule)
        }
        .modifier(FirasGlassControlStyle())
        .accessibilityLabel(Text(ChatStrings.selectModel))
        .accessibilityValue(Text(verbatim: preferences.modelLabel(for: selectedTier)))
    }

    @ViewBuilder
    private var primaryAction: some View {
        if promptEngineerBusy || isSending {
            ComposerCircleButton(
                title: LocalizedStringResource("chat.stop"),
                systemImage: "stop.fill",
                isProminent: true,
                action: onStop
            )
            .id(ComposerPrimaryAction.stop)
            .transition(.scale(scale: 0.84).combined(with: .opacity))
        } else if promptEngineerRecognized {
            PromptEngineerLanguageActions(isEnabled: promptEngineerReady, onChoose: onPromptEngineerLanguage)
        } else if canSend {
            ComposerCircleButton(
                title: LocalizedStringResource("chat.send"),
                systemImage: "arrow.up",
                isProminent: true,
                action: onSend
            )
            .id(ComposerPrimaryAction.send)
            .transition(.scale(scale: 0.84).combined(with: .opacity))
        } else {
            ComposerCircleButton(
                title: ChatStrings.startVoiceCall,
                systemImage: "waveform",
                isProminent: false,
                action: onStartCall
            )
            .id(ComposerPrimaryAction.call)
            .transition(.scale(scale: 0.84).combined(with: .opacity))
        }
    }

    private var canSend: Bool {
        ChatComposerContent.canSend(draft: draft, hasReadyContext: hasReadyContext)
    }

    private var primaryActionState: ComposerPrimaryAction {
        if isSending || promptEngineerBusy { return .stop }
        if promptEngineerRecognized { return .promptEngineer }
        return canSend ? .send : .call
    }

    private var primaryActionAnimation: Animation? {
        guard preferences.motionEnabled, !reduceMotion else { return nil }
        return .spring(duration: 0.28, bounce: 0.16)
    }

    private var expansionAnimation: Animation? {
        guard preferences.motionEnabled, !reduceMotion else { return nil }
        return .spring(duration: 0.32, bounce: 0.1)
    }
}

/// The two controls that move between the resting row and the open card.
private enum ComposerSlot: Hashable {
    case context
    case primary
}

private enum ComposerPrimaryAction: Hashable {
    case call
    case send
    case stop
    case promptEngineer
}

private struct ComposerCircleButton: View {
    let title: LocalizedStringResource
    let systemImage: String
    let isProminent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .modifier(FirasGlassControlStyle(prominent: isProminent, circular: true))
        .accessibilityLabel(Text(title))
    }
}

private struct ComposerAttachmentChip: View {
    let attachment: ComposerAttachment
    let onRemove: () -> Void

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: UIImage?

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 6) {
                preview
                if attachment.kind == .file {
                    Text(verbatim: attachment.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 150)
                }
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(preferences.palette.accent)
            .padding(.leading, attachment.kind == .image ? 6 : 10)
            .padding(.trailing, 10)
            .frame(minHeight: 44)
            .background(preferences.palette.accent.opacity(0.08), in: Capsule())
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            attachment.kind == .image ? Text(ChatStrings.attachedPhoto) : Text(verbatim: attachment.name)
        )
        .accessibilityValue(
            attachment.isProcessing ? Text(ChatStrings.attachmentPreparing) : Text(verbatim: "")
        )
        .accessibilityHint(Text(ChatStrings.removeAttachment))
        .task(id: ComposerThumbnailTarget(
            attachmentID: attachment.id,
            isReady: attachment.imageData != nil,
            scale: displayScale
        )) {
            await decodeThumbnail()
        }
    }

    @ViewBuilder
    private var preview: some View {
        if attachment.isProcessing {
            ProgressView()
                .controlSize(.small)
                .tint(preferences.palette.accent)
                .frame(width: 32, height: 32)
        } else if attachment.kind == .image {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    preferences.palette.surfaceSunken
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
        } else {
            Image(systemName: "doc.text")
                .accessibilityHidden(true)
        }
    }

    /// The prepared JPEG is up to 1,568 px; only a chip-sized copy is decoded,
    /// off the main actor, and a superseded decode never publishes.
    private func decodeThumbnail() async {
        guard let data = attachment.imageData else {
            thumbnail = nil
            return
        }
        let edge = 32 * displayScale
        let worker = Task.detached(priority: .userInitiated) {
            ComposerThumbnailResult(image: ChatAttachmentProcessor.downsampledImage(data: data, maximumEdge: edge))
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return }
        thumbnail = result.image
    }
}

private nonisolated struct ComposerThumbnailTarget: Equatable {
    let attachmentID: String
    let isReady: Bool
    let scale: CGFloat
}

/// UIImage is immutable here and crosses the worker boundary only after downsampling.
private nonisolated struct ComposerThumbnailResult: @unchecked Sendable {
    let image: UIImage?
}
