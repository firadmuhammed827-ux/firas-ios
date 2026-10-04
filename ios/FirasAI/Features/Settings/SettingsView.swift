import SwiftUI

struct SettingsView: View {
    private let onAuthEntryCompleted: (AuthEntryOutcome) -> Void

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(
        onAuthEntryCompleted: @escaping (AuthEntryOutcome) -> Void = { _ in }
    ) {
        self.onAuthEntryCompleted = onAuthEntryCompleted
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                SettingsSplitView(onAuthEntryCompleted: onAuthEntryCompleted)
            } else {
                SettingsTabView(onAuthEntryCompleted: onAuthEntryCompleted)
            }
        }
        .tint(preferences.palette.accent)
        .preferredColorScheme(preferences.theme.isLight ? .light : .dark)
        .environment(\.locale, preferences.language.locale)
        .environment(\.layoutDirection, preferences.language.layoutDirection)
        .presentationSizing(.page)
    }
}

enum SettingsDestination: String, CaseIterable, Hashable, Identifiable {
    case account
    case appearance
    case chat
    case voice
    case data

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .account: "settings.account"
        case .appearance: "settings.appearance"
        case .chat: "settings.chat"
        case .voice: "settings.voice"
        case .data: "settings.data"
        }
    }

    var systemImage: String {
        switch self {
        case .account: "person.crop.circle"
        case .appearance: "paintpalette"
        case .chat: "bubble.left.and.text.bubble.right"
        case .voice: "waveform"
        case .data: "externaldrive"
        }
    }
}

private struct SettingsTabView: View {
    let onAuthEntryCompleted: (AuthEntryOutcome) -> Void
    @State private var selection: SettingsDestination = .account

    var body: some View {
        TabView(selection: $selection) {
            ForEach(SettingsDestination.allCases) { destination in
                NavigationStack {
                    SettingsPage(
                        destination: destination,
                        onAuthEntryCompleted: onAuthEntryCompleted
                    )
                }
                .tabItem {
                    Label(destination.titleKey, systemImage: destination.systemImage)
                }
                .tag(destination)
            }
        }
    }
}

private struct SettingsSplitView: View {
    let onAuthEntryCompleted: (AuthEntryOutcome) -> Void

    @Environment(PreferencesStore.self) private var preferences
    @State private var selection: SettingsDestination? = .account

    var body: some View {
        NavigationSplitView {
            List(SettingsDestination.allCases, selection: $selection) { destination in
                Label(destination.titleKey, systemImage: destination.systemImage)
                    .tag(destination)
                    .frame(minHeight: 44)
            }
            .navigationTitle("settings.title")
            .scrollContentBackground(.hidden)
            .background(preferences.palette.sidebar)
            .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 340)
            .safeAreaInset(edge: .bottom) {
                LocalPreferencesNote(compact: true)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
            }
        } detail: {
            SettingsPage(
                destination: selection ?? .account,
                onAuthEntryCompleted: onAuthEntryCompleted
            )
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct SettingsPage: View {
    let destination: SettingsDestination
    let onAuthEntryCompleted: (AuthEntryOutcome) -> Void

    @Environment(SessionStore.self) private var session

    var body: some View {
        ZStack {
            FirasBackground()

            ScrollView {
                SettingsGlassStack {
                    switch destination {
                    case .account:
                        AccountSettingsView(onAuthEntryCompleted: onAuthEntryCompleted)
                    case .appearance:
                        AppearanceSettingsView()
                    case .chat:
                        ChatSettingsView()
                    case .voice:
                        VoiceSettingsView()
                    case .data:
                        DataSettingsView()
                    }
                }
                .frame(maxWidth: 820)
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                guard destination == .account, session.isAuthenticated else { return }
                await session.refreshAccount()
            }
        }
        .navigationTitle(destination.titleKey)
        .navigationBarTitleDisplayMode(.large)
    }
}

struct SettingsGlassStack<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 16) {
                VStack(spacing: 16) {
                    content
                }
            }
        } else {
            VStack(spacing: 16) {
                content
            }
        }
    }
}

struct SettingsPanel<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let footer: LocalizedStringKey?
    let content: Content

    @Environment(PreferencesStore.self) private var preferences

    init(
        _ title: LocalizedStringKey,
        systemImage: String,
        footer: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        GlassSurface(cornerRadius: 24, tintStrength: 0.055) {
            VStack(alignment: .leading, spacing: 16) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(preferences.palette.textPrimary)

                content

                if let footer {
                    Text(footer)
                        .font(.footnote)
                        .foregroundStyle(preferences.palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsToggleRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let systemImage: String
    @Binding var isOn: Bool

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Toggle(isOn: $isOn) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(preferences.palette.textPrimary)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(preferences.palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(preferences.palette.accent)
                    .frame(width: 24)
            }
        }
        .tint(preferences.palette.accent)
        .frame(minHeight: 52)
    }
}

struct SettingsValueRow<Value: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let value: Value

    @Environment(PreferencesStore.self) private var preferences

    init(
        _ title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder value: () -> Value
    ) {
        self.title = title
        self.systemImage = systemImage
        self.value = value()
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(preferences.palette.accent)
                .frame(width: 24)
                .accessibilityHidden(true)

            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(preferences.palette.textPrimary)

            Spacer(minLength: 12)
            value
        }
        .frame(minHeight: 48)
    }
}

struct SettingsDivider: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Divider()
            .overlay(preferences.palette.border)
    }
}

struct SettingsNoticeBanner: View {
    private let message: Text
    let kind: Kind

    @Environment(PreferencesStore.self) private var preferences

    enum Kind: Equatable {
        case success
        case error

        var systemImage: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .error: "exclamationmark.triangle.fill"
            }
        }
    }

    init(_ messageKey: LocalizedStringKey, kind: Kind) {
        message = Text(messageKey)
        self.kind = kind
    }

    init(verbatim message: String, kind: Kind) {
        self.message = Text(verbatim: message)
        self.kind = kind
    }

    init(message: Text, kind: Kind) {
        self.message = message
        self.kind = kind
    }

    var body: some View {
        let color = kind == .success ? preferences.palette.success : preferences.palette.error

        Label {
            message
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: kind.systemImage)
                .accessibilityHidden(true)
        }
        .foregroundStyle(color)
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct SettingsSubmitButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isDestructive = false
    var prominent = true
    var isWorking = false
    var isDisabled = false
    let action: () -> Void

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Group {
            if #available(iOS 26, *) {
                if prominent {
                    button
                        .buttonStyle(.glassProminent)
                } else {
                    button
                        .buttonStyle(.glass)
                }
            } else {
                if prominent {
                    button
                        .buttonStyle(.borderedProminent)
                } else {
                    button
                        .buttonStyle(.bordered)
                }
            }
        }
        .tint(isDestructive ? preferences.palette.error : preferences.palette.accent)
        .disabled(isDisabled || isWorking)
    }

    @ViewBuilder
    private var button: some View {
        if isDestructive {
            Button(role: .destructive, action: action) {
                buttonLabel
            }
        } else {
            Button(action: action) {
                buttonLabel
            }
        }
    }

    private var buttonLabel: some View {
        HStack(spacing: 9) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .tint(prominent ? preferences.palette.onAccent : preferences.palette.accent)
            } else {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }

            Text(title)
                .font(.body.weight(.semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 48)
    }
}

struct LocalPreferencesNote: View {
    let compact: Bool

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Label {
            Text("settings.localOnly")
                .font(compact ? .caption : .footnote)
                .foregroundStyle(preferences.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "iphone.and.arrow.forward")
                .foregroundStyle(preferences.palette.accent)
        }
        .accessibilityElement(children: .combine)
    }
}

extension FontScale {
    var settingsTitleKey: LocalizedStringKey {
        switch self {
        case .small: "settings.textSize.small"
        case .medium: "settings.textSize.medium"
        case .large: "settings.textSize.large"
        }
    }
}

extension ContentWidth {
    var settingsTitleKey: LocalizedStringKey {
        switch self {
        case .normal: "settings.readingWidth.normal"
        case .wide: "settings.readingWidth.wide"
        }
    }
}

extension MotionPreference {
    var settingsTitleKey: LocalizedStringKey {
        switch self {
        case .full: "settings.motion.full"
        case .reduced: "settings.motion.reduced"
        }
    }
}

extension DictationDialect {
    var settingsTitleKey: LocalizedStringKey {
        switch self {
        case .automatic: "settings.voice.dictation.auto"
        case .arabic: "language.arabic"
        case .english: "language.english"
        }
    }
}

extension ModelTier {
    var settingsTitleKey: LocalizedStringKey {
        switch self {
        case .mini: "tier.mini"
        case .pro: "tier.pro"
        case .ultra: "tier.ultra"
        case .max: "tier.max"
        }
    }
}
