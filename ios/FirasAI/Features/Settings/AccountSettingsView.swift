import Foundation
import SwiftUI

struct AccountSettingsView: View {
    let onAuthEntryCompleted: (AuthEntryOutcome) -> Void

    @Environment(SessionStore.self) private var session
    @State private var presentedSheet: AccountSheet?

    var body: some View {
        VStack(spacing: 16) {
            if session.isAuthenticated, let user = session.user {
                AccountIdentityPanel(user: user)
                SubscriptionPanel(subscription: user.sub)
                NavigationLink {
                    AccountSkillsView().id(session.user?.id)
                } label: {
                    Label { Text(SkillsStrings.title) } icon: { Image(systemName: "sparkles.rectangle.stack") }
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(.horizontal, 18)
                }
                AccountSecurityPanel(presentedSheet: $presentedSheet)
            } else {
                SignedOutAccountPanel {
                    presentedSheet = .signIn
                }
            }

            if let errorMessage = session.errorMessage, !errorMessage.isEmpty {
                SettingsNoticeBanner(verbatim: errorMessage, kind: .error)
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            AccountSheetContent(
                sheet: sheet,
                onAuthEntryCompleted: onAuthEntryCompleted
            )
                .presentationDragIndicator(.visible)
                .presentationSizing(.form)
        }
        .onChange(of: session.isAuthenticated) {
            if session.isAuthenticated, presentedSheet == .signIn {
                presentedSheet = nil
            }
        }
    }
}

private enum AccountSheet: String, Identifiable {
    case signIn
    case changeEmail
    case changePassword
    case deleteAccount

    var id: String { rawValue }
}

private struct AccountSheetContent: View {
    let sheet: AccountSheet
    let onAuthEntryCompleted: (AuthEntryOutcome) -> Void

    var body: some View {
        switch sheet {
        case .signIn:
            AuthView(onEntryCompleted: onAuthEntryCompleted)
        case .changeEmail:
            ChangeEmailSheet()
        case .changePassword:
            ChangePasswordSheet()
        case .deleteAccount:
            DeleteAccountSheet()
        }
    }
}

private struct AccountIdentityPanel: View {
    let user: User

    @Environment(PreferencesStore.self) private var preferences
    @Environment(SessionStore.self) private var session

    private var initial: String {
        let trimmedName = user.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.first.map(String.init) ?? "F"
    }

    var body: some View {
        SettingsPanel("settings.account", systemImage: "person.crop.circle") {
            HStack(spacing: 14) {
                Text(initial)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(preferences.palette.onAccent)
                    .frame(width: 52, height: 52)
                    .background(preferences.palette.accent, in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(user.name)
                            .font(.headline)
                            .foregroundStyle(preferences.palette.textPrimary)
                            .lineLimit(1)

                        if user.admin {
                            Text("settings.account.admin")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(preferences.palette.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    preferences.palette.accent.opacity(0.12),
                                    in: Capsule()
                                )
                        }
                    }

                    Text(user.email)
                        .font(.subheadline)
                        .foregroundStyle(preferences.palette.textSecondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .environment(\.layoutDirection, .leftToRight)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                if session.settingsOperation == .refreshingAccount {
                    ProgressView()
                        .tint(preferences.palette.accent)
                        .accessibilityLabel("settings.account.refreshing")
                }
            }
        }
    }
}

private struct SubscriptionPanel: View {
    let subscription: Subscription

    @Environment(PreferencesStore.self) private var preferences

    private let columns = [
        GridItem(.adaptive(minimum: 132, maximum: 220), spacing: 10)
    ]

    var body: some View {
        SettingsPanel(
            "settings.account.plan",
            systemImage: "seal",
            footer: "settings.account.plan.footer"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: subscription.plan.systemImage)
                        .font(.title2)
                        .foregroundStyle(preferences.palette.accent)
                        .frame(width: 44, height: 44)
                        .background(
                            preferences.palette.accent.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(subscription.plan.titleKey)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(preferences.palette.textPrimary)

                        if subscription.plan == .unlimited {
                            Text("settings.account.unlimited")
                                .font(.subheadline)
                                .foregroundStyle(preferences.palette.textSecondary)
                        } else if let daysLeft = subscription.daysLeft {
                            HStack(spacing: 4) {
                                Text("settings.account.daysLeft")
                                Text(verbatim: "\(daysLeft)")
                            }
                            .font(.subheadline)
                            .foregroundStyle(preferences.palette.textSecondary)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)

                LazyVGrid(columns: columns, spacing: 10) {
                    UsageCounter(
                        title: "settings.quota.ai",
                        systemImage: "bubble.left.and.sparkles",
                        remaining: subscription.remaining.ai,
                        limit: subscription.limits.ai
                    )
                    UsageCounter(
                        title: "settings.quota.code",
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        remaining: subscription.remaining.code,
                        limit: subscription.limits.code
                    )
                    UsageCounter(
                        title: "settings.quota.brain",
                        systemImage: "brain.head.profile",
                        remaining: subscription.remaining.brain,
                        limit: subscription.limits.brain
                    )
                }
            }
        }
    }
}

private struct UsageCounter: View {
    let title: LocalizedStringKey
    let systemImage: String
    let remaining: Int
    let limit: Int

    @Environment(PreferencesStore.self) private var preferences

    private var isUnlimited: Bool { remaining < 0 || limit < 0 }

    var body: some View {
        GlassSurface(cornerRadius: 17, tintStrength: 0.035) {
            VStack(alignment: .leading, spacing: 9) {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(preferences.palette.textSecondary)

                if isUnlimited {
                    Text("settings.account.unlimited")
                        .font(.headline)
                        .foregroundStyle(preferences.palette.accent)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(verbatim: "\(max(remaining, 0))")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(preferences.palette.textPrimary)
                        Text("settings.quota.remaining")
                            .font(.caption)
                            .foregroundStyle(preferences.palette.textSecondary)
                    }

                    ProgressView(
                        value: Double(max(remaining, 0)),
                        total: Double(max(limit, 1))
                    )
                    .tint(preferences.palette.accent)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AccountSecurityPanel: View {
    @Binding var presentedSheet: AccountSheet?

    @Environment(SessionStore.self) private var session

    var body: some View {
        SettingsPanel(
            "settings.account.security",
            systemImage: "lock.shield",
            footer: "settings.account.security.footer"
        ) {
            VStack(spacing: 2) {
                AccountActionRow(
                    title: "settings.account.changeEmail",
                    detail: "settings.account.changeEmail.footer",
                    systemImage: "envelope",
                    action: { presentedSheet = .changeEmail }
                )

                SettingsDivider()

                AccountActionRow(
                    title: "settings.account.changePassword",
                    detail: "settings.account.changePassword.footer",
                    systemImage: "key",
                    action: { presentedSheet = .changePassword }
                )

                SettingsDivider()

                AccountActionRow(
                    title: "auth.signOut",
                    detail: "settings.account.signOut.footer",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    showsChevron: false,
                    isWorking: session.isWorking && session.settingsOperation == nil,
                    action: {
                        Task { await session.logout() }
                    }
                )
                .disabled(session.isWorking)
            }
        }

        SettingsPanel(
            "settings.account.danger",
            systemImage: "exclamationmark.shield",
            footer: "settings.account.danger.footer"
        ) {
            AccountActionRow(
                title: "settings.account.delete",
                detail: "settings.account.delete.footer",
                systemImage: "trash",
                isDestructive: true,
                action: { presentedSheet = .deleteAccount }
            )
        }
    }
}

private struct AccountActionRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let systemImage: String
    var isDestructive = false
    var showsChevron = true
    var isWorking = false
    let action: () -> Void

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: systemImage)
                    }
                }
                .foregroundStyle(
                    isDestructive
                        ? preferences.palette.error
                        : preferences.palette.accent
                )
                .frame(width: 24)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(
                            isDestructive
                                ? preferences.palette.error
                                : preferences.palette.textPrimary
                        )
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(preferences.palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if showsChevron {
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(preferences.palette.textMuted)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

private struct SignedOutAccountPanel: View {
    let signIn: () -> Void

    var body: some View {
        SettingsPanel(
            "settings.account.guest",
            systemImage: "person.crop.circle.badge.questionmark",
            footer: "settings.account.guest.footer"
        ) {
            SettingsSubmitButton(
                title: "auth.signIn",
                systemImage: "person.badge.key",
                action: signIn
            )
        }
    }
}

private struct ChangeEmailSheet: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var currentPassword = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case email
        case password
    }

    private var canSubmit: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && !currentPassword.isEmpty && !session.isWorking
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FirasBackground()

                ScrollView {
                    GlassSurface(cornerRadius: 24, tintStrength: 0.06) {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("settings.account.changeEmail.footer")
                                .font(.subheadline)
                                .foregroundStyle(preferences.palette.textSecondary)

                            TextField("settings.account.newEmail", text: $email)
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .environment(\.layoutDirection, .leftToRight)
                                .submitLabel(.next)
                                .focused($focusedField, equals: .email)
                                .onSubmit { focusedField = .password }
                                .settingsFieldStyle()

                            SecureField("settings.account.currentPassword", text: $currentPassword)
                                .textContentType(.password)
                                .submitLabel(.done)
                                .focused($focusedField, equals: .password)
                                .onSubmit(save)
                                .settingsFieldStyle()

                            if let error = session.errorMessage, !error.isEmpty {
                                SettingsNoticeBanner(verbatim: error, kind: .error)
                            }

                            SettingsSubmitButton(
                                title: "settings.account.saveEmail",
                                systemImage: "checkmark",
                                isWorking: session.settingsOperation == .changingEmail,
                                isDisabled: !canSubmit,
                                action: save
                            )
                        }
                        .padding(18)
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("settings.account.changeEmail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                        .foregroundStyle(preferences.palette.accent)
                }
            }
        }
        .onAppear {
            email = session.user?.email ?? ""
            focusedField = .email
            session.errorMessage = nil
        }
    }

    private func save() {
        guard canSubmit else { return }
        focusedField = nil
        Task {
            if await session.changeEmail(
                currentPassword: currentPassword,
                newEmail: email
            ) {
                dismiss()
            }
        }
    }
}

private struct ChangePasswordSheet: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case current
        case new
        case confirmation
    }

    private var canSubmit: Bool {
        !currentPassword.isEmpty
            && (8...200).contains(newPassword.count)
            && newPassword == confirmation
            && !session.isWorking
    }

    private var passwordHintKey: LocalizedStringKey {
        newPassword == confirmation
            ? "auth.password.minimum"
            : "auth.password.mismatch"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FirasBackground()

                ScrollView {
                    GlassSurface(cornerRadius: 24, tintStrength: 0.06) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("settings.account.changePassword.footer")
                                .font(.subheadline)
                                .foregroundStyle(preferences.palette.textSecondary)

                            SecureField("settings.account.currentPassword", text: $currentPassword)
                                .textContentType(.password)
                                .submitLabel(.next)
                                .focused($focusedField, equals: .current)
                                .onSubmit { focusedField = .new }
                                .settingsFieldStyle()

                            SecureField("settings.account.newPassword", text: $newPassword)
                                .textContentType(.newPassword)
                                .submitLabel(.next)
                                .focused($focusedField, equals: .new)
                                .onSubmit { focusedField = .confirmation }
                                .settingsFieldStyle()

                            SecureField("settings.account.confirmPassword", text: $confirmation)
                                .textContentType(.newPassword)
                                .submitLabel(.done)
                                .focused($focusedField, equals: .confirmation)
                                .onSubmit(save)
                                .settingsFieldStyle(
                                    isInvalid: !confirmation.isEmpty && newPassword != confirmation
                                )

                            Text(passwordHintKey)
                            .font(.caption)
                            .foregroundStyle(
                                newPassword == confirmation
                                    ? preferences.palette.textSecondary
                                    : preferences.palette.error
                            )

                            if let error = session.errorMessage, !error.isEmpty {
                                SettingsNoticeBanner(verbatim: error, kind: .error)
                            }

                            SettingsSubmitButton(
                                title: "settings.account.savePassword",
                                systemImage: "checkmark",
                                isWorking: session.settingsOperation == .changingPassword,
                                isDisabled: !canSubmit,
                                action: save
                            )
                        }
                        .padding(18)
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("settings.account.changePassword")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                        .foregroundStyle(preferences.palette.accent)
                }
            }
        }
        .onAppear {
            focusedField = .current
            session.errorMessage = nil
        }
    }

    private func save() {
        guard canSubmit else { return }
        focusedField = nil
        Task {
            if await session.changePassword(
                currentPassword: currentPassword,
                newPassword: newPassword
            ) {
                dismiss()
            }
        }
    }
}

private struct DeleteAccountSheet: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var currentPassword = ""
    @State private var confirmsDeletion = false

    var body: some View {
        NavigationStack {
            ZStack {
                FirasBackground()

                ScrollView {
                    GlassSurface(cornerRadius: 24, tintStrength: 0.06) {
                        VStack(alignment: .leading, spacing: 16) {
                            Label {
                                Text("settings.account.delete.warning")
                                    .font(.body)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .accessibilityHidden(true)
                            }
                            .foregroundStyle(preferences.palette.error)

                            SecureField(
                                "settings.account.currentPassword.optional",
                                text: $currentPassword
                            )
                            .textContentType(.password)
                            .submitLabel(.done)
                            .settingsFieldStyle()

                            Text("settings.account.delete.passwordNote")
                                .font(.footnote)
                                .foregroundStyle(preferences.palette.textSecondary)

                            if let error = session.errorMessage, !error.isEmpty {
                                SettingsNoticeBanner(verbatim: error, kind: .error)
                            }

                            SettingsSubmitButton(
                                title: "settings.account.delete.confirmTitle",
                                systemImage: "trash",
                                isDestructive: true,
                                isWorking: session.settingsOperation == .deletingAccount,
                                isDisabled: session.isWorking,
                                action: { confirmsDeletion = true }
                            )
                        }
                        .padding(18)
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("settings.account.delete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                        .foregroundStyle(preferences.palette.accent)
                }
            }
            .alert("settings.account.delete.final", isPresented: $confirmsDeletion) {
                Button("common.cancel", role: .cancel) {}
                Button("common.delete", role: .destructive, action: deleteAccount)
            } message: {
                Text("settings.account.delete.confirmMessage")
            }
        }
        .onAppear {
            session.errorMessage = nil
        }
    }

    private func deleteAccount() {
        Task {
            if await session.deleteAccount(currentPassword: currentPassword) {
                dismiss()
            }
        }
    }
}

private struct SettingsFieldModifier: ViewModifier {
    let isInvalid: Bool

    @Environment(PreferencesStore.self) private var preferences

    func body(content: Content) -> some View {
        content
            .font(.body)
            .foregroundStyle(preferences.palette.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .background(
                preferences.palette.surfaceSunken,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isInvalid ? preferences.palette.error : preferences.palette.border,
                        lineWidth: isInvalid ? 1.5 : 1
                    )
            }
    }
}

extension View {
    fileprivate func settingsFieldStyle(isInvalid: Bool = false) -> some View {
        modifier(SettingsFieldModifier(isInvalid: isInvalid))
    }
}

private extension SubscriptionPlan {
    var titleKey: LocalizedStringKey {
        switch self {
        case .guest: "settings.plan.guest"
        case .free: "settings.plan.free"
        case .gold: "settings.plan.gold"
        case .diamond: "settings.plan.diamond"
        case .unlimited: "settings.plan.unlimited"
        }
    }

    var systemImage: String {
        switch self {
        case .guest: "person.crop.circle.badge.questionmark"
        case .free: "leaf.fill"
        case .gold: "star.fill"
        case .diamond: "diamond.fill"
        case .unlimited: "infinity.circle.fill"
        }
    }
}
