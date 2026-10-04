import SwiftUI

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

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The field stays on a quiet material surface; only its controls are
        // glass, so one glass layer never has to sample another.
        GlassSurface(cornerRadius: 25, tintStrength: 0.045, usesLiquidGlass: false) {
            VStack(spacing: 4) {
                if !selectedSkills.isEmpty {
                    selectedSkillRow
                }
                messageField
                FirasGlassControlGroup(spacing: 8) {
                    actionRow
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 7)
            .frame(maxWidth: 760)
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
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
            .disabled(isPreparing)
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
                modelButton
                Spacer(minLength: 8)
                primaryAction
                    .animation(primaryActionAnimation, value: primaryActionState)
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
