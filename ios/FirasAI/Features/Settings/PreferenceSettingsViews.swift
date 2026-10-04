import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        SettingsPanel(
            "settings.theme",
            systemImage: "circle.lefthalf.filled",
            footer: "settings.theme.footer"
        ) {
            ThemePicker()
        }

        SettingsPanel("settings.reading", systemImage: "textformat.size") {
            VStack(spacing: 14) {
                SettingsSegmentedPicker(
                    title: "settings.textSize",
                    systemImage: "textformat.size",
                    selection: $preferences.fontScale,
                    values: FontScale.allCases,
                    label: { $0.settingsTitleKey }
                )

                SettingsDivider()

                SettingsSegmentedPicker(
                    title: "settings.readingWidth",
                    systemImage: "arrow.left.and.right",
                    selection: $preferences.contentWidth,
                    values: ContentWidth.allCases,
                    label: { $0.settingsTitleKey }
                )
            }
        }

        SettingsPanel("settings.interface", systemImage: "globe") {
            VStack(spacing: 14) {
                SettingsSegmentedPicker(
                    title: "settings.language",
                    systemImage: "character.bubble",
                    selection: $preferences.language,
                    values: AppLanguage.allCases,
                    label: { $0.titleKey }
                )

                SettingsDivider()

                SettingsSegmentedPicker(
                    title: "settings.motion",
                    systemImage: "wand.and.stars",
                    selection: $preferences.motionPreference,
                    values: MotionPreference.allCases,
                    label: { $0.settingsTitleKey }
                )
            }
        }

        LocalPreferencesNote(compact: false)
            .padding(.horizontal, 4)
    }
}

struct ChatSettingsView: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        SettingsPanel(
            "settings.model",
            systemImage: "cpu",
            footer: "settings.model.footer"
        ) {
            VStack(spacing: 14) {
                ModelGenerationPicker()
                SettingsDivider()
                ModelTierPicker(selection: $preferences.tier)
            }
        }

        SettingsPanel("settings.chat.behavior", systemImage: "slider.horizontal.3") {
            VStack(spacing: 12) {
                SettingsToggleRow(
                    title: "chat.thinking",
                    detail: "settings.thinking.footer",
                    systemImage: "brain.head.profile",
                    isOn: $preferences.thinkingEnabled
                )

                SettingsDivider()

                SettingsToggleRow(
                    title: "chat.webSearch",
                    detail: "settings.webSearch.footer",
                    systemImage: "globe.badge.chevron.backward",
                    isOn: $preferences.webSearchEnabled
                )

                SettingsDivider()

                SettingsToggleRow(
                    title: "settings.sendOnReturn",
                    detail: "settings.sendOnReturn.footer",
                    systemImage: "return",
                    isOn: $preferences.sendOnReturn
                )

                SettingsDivider()

                SettingsToggleRow(
                    title: "settings.sharpenImages",
                    detail: "settings.sharpenImages.footer",
                    systemImage: "photo.badge.checkmark",
                    isOn: $preferences.sharpenImages
                )
            }
        }

        LocalPreferencesNote(compact: false)
            .padding(.horizontal, 4)
    }
}

struct VoiceSettingsView: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        @Bindable var preferences = preferences

        SettingsPanel(
            "settings.voice.call",
            systemImage: "phone.waveform",
            footer: "settings.voice.call.footer"
        ) {
            SettingsValueRow("settings.voice.call.picker", systemImage: "waveform") {
                Picker("settings.voice.call.picker", selection: $preferences.callVoice) {
                    ForEach(CallVoice.allCases) { voice in
                        Text(verbatim: voice.displayName).tag(voice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(preferences.palette.accent)
            }
        }

        SettingsPanel(
            "settings.voice.dictation",
            systemImage: "mic",
            footer: "settings.voice.dictation.footer"
        ) {
            if dynamicTypeSize.isAccessibilitySize {
                SettingsValueRow("settings.voice.dictation", systemImage: "mic") {
                    Picker("settings.voice.dictation", selection: $preferences.dictationDialect) {
                        ForEach(DictationDialect.allCases) { dialect in
                            Text(dialect.settingsTitleKey).tag(dialect)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(preferences.palette.accent)
                }
            } else {
                Picker("settings.voice.dictation", selection: $preferences.dictationDialect) {
                    ForEach(DictationDialect.allCases) { dialect in
                        Text(dialect.settingsTitleKey).tag(dialect)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(minHeight: 44)
            }
        }

        LocalPreferencesNote(compact: false)
            .padding(.horizontal, 4)
    }
}

private struct ThemePicker: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = [
        GridItem(.adaptive(minimum: 102, maximum: 170), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(FirasTheme.allCases) { theme in
                ThemeCell(
                    theme: theme,
                    isSelected: preferences.theme == theme,
                    action: { select(theme) }
                )
            }
        }
        .sensoryFeedback(.selection, trigger: preferences.theme)
    }

    private func select(_ theme: FirasTheme) {
        guard theme != preferences.theme else { return }

        if reduceMotion || !preferences.motionEnabled {
            preferences.theme = theme
        } else {
            withAnimation(.snappy(duration: 0.28)) {
                preferences.theme = theme
            }
        }
    }
}

private struct ThemeCell: View {
    let theme: FirasTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(theme.palette.background)
                        .frame(height: 58)
                        .overlay(alignment: .bottomLeading) {
                            HStack(spacing: 5) {
                                Circle().fill(theme.palette.accent)
                                Circle().fill(theme.palette.surface)
                                Circle().fill(theme.palette.textPrimary.opacity(0.72))
                            }
                            .frame(width: 50, height: 10)
                            .padding(9)
                        }

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(theme.palette.onAccent, theme.palette.accent)
                            .padding(7)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .accessibilityHidden(true)

                Text(theme.titleKey)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
            .background(
                theme.palette.surface,
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(
                        isSelected ? theme.palette.accent : theme.palette.border,
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ModelTierPicker: View {
    @Binding var selection: ModelTier

    @Environment(PreferencesStore.self) private var preferences

    private let columns = [
        GridItem(.adaptive(minimum: 132, maximum: 220), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(ModelTier.allCases) { tier in
                let isSelected = selection == tier

                Button {
                    selection = tier
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tier.systemImage)
                            .foregroundStyle(
                                isSelected
                                    ? preferences.palette.onAccent
                                    : preferences.palette.accent
                            )
                            .accessibilityHidden(true)

                        Text(verbatim: preferences.modelLabel(for: tier))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(
                                isSelected
                                    ? preferences.palette.onAccent
                                    : preferences.palette.textPrimary
                            )

                        Spacer(minLength: 4)

                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(preferences.palette.onAccent)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 13)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(
                        isSelected
                            ? preferences.palette.accent
                            : preferences.palette.surfaceSunken,
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(
                                isSelected
                                    ? preferences.palette.accent
                                    : preferences.palette.border,
                                lineWidth: 1
                            )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

private struct SettingsSegmentedPicker<Value: Hashable & Identifiable>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @Binding var selection: Value
    let values: [Value]
    let label: (Value) -> LocalizedStringKey

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(preferences.palette.textPrimary)

            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    ForEach(values) { value in
                        let isSelected = selection == value

                        Button {
                            selection = value
                        } label: {
                            HStack(spacing: 10) {
                                Text(label(value))
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(preferences.palette.textPrimary)
                                Spacer(minLength: 12)
                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(preferences.palette.accent)
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(.horizontal, 13)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(
                                isSelected
                                    ? preferences.palette.accent.opacity(0.12)
                                    : preferences.palette.surfaceSunken,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(
                                        isSelected
                                            ? preferences.palette.accent
                                            : preferences.palette.border,
                                        lineWidth: isSelected ? 1.5 : 1
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            } else {
                Picker(title, selection: $selection) {
                    ForEach(values) { value in
                        Text(label(value)).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(minHeight: 44)
            }
        }
    }
}

private extension ModelTier {
    var systemImage: String {
        switch self {
        case .mini: "bolt.fill"
        case .pro: "sparkles"
        case .ultra: "diamond.fill"
        case .max: "crown.fill"
        }
    }
}
