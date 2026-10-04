import Foundation
import SwiftUI

enum AuthEntryOutcome: Equatable, Sendable {
    case authenticated(User)
    case guest
}

struct AuthView: View {
    private let onContinueAsGuest: () -> Void
    private let googleOAuthProvider: GoogleOAuthProvider?
    private let onEntryCompleted: (AuthEntryOutcome) -> Void

    @Environment(PreferencesStore.self) private var preferences
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var hidesPendingSignup = false
    @State private var isContinuingAsGuest = false
    @State private var isGoogleWorking = false
    @State private var didReportEntry = false

    init(
        onContinueAsGuest: @escaping () -> Void = {},
        googleOAuthProvider: GoogleOAuthProvider? = GoogleOAuthProvider.shared,
        onEntryCompleted: @escaping (AuthEntryOutcome) -> Void = { _ in }
    ) {
        self.onContinueAsGuest = onContinueAsGuest
        self.googleOAuthProvider = googleOAuthProvider
        self.onEntryCompleted = onEntryCompleted
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FirasBackground()

                ScrollView {
                    VStack(spacing: 26) {
                        AuthHeader()

                        if session.isAuthenticated, let user = session.user {
                            AuthenticatedCard(user: user) {
                                reportEntry(.authenticated(user))
                                dismiss()
                            }
                        } else if let pendingSignup = session.pendingSignup,
                                  !hidesPendingSignup {
                            VerificationCard(email: pendingSignup.email) {
                                session.errorMessage = nil
                                hidesPendingSignup = true
                            }
                        } else {
                            CredentialsCard(
                                googleOAuthProvider: googleOAuthProvider,
                                isGoogleWorking: $isGoogleWorking
                            )

                            if session.pendingSignup != nil, hidesPendingSignup {
                                Button {
                                    session.errorMessage = nil
                                    hidesPendingSignup = false
                                } label: {
                                    Label("auth.verify.title", systemImage: "envelope.badge")
                                        .frame(minHeight: 44)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(preferences.palette.accent)
                            }
                        }

                        Button(action: continueAsGuest) {
                            HStack(spacing: 8) {
                                if isContinuingAsGuest {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text("auth.continueGuest")
                                    .font(.body.weight(.medium))
                            }
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(preferences.palette.textSecondary)
                        .disabled(session.isWorking || isGoogleWorking)

                        Label("auth.secure", systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(preferences.palette.textMuted)
                            .accessibilityElement(children: .combine)
                    }
                    .frame(maxWidth: 540)
                    .padding(.horizontal, 20)
                    .padding(.top, 30)
                    .padding(.bottom, 42)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("app.name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close", systemImage: "xmark") {
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("common.close")
                }
            }
        }
        .tint(preferences.palette.accent)
        .preferredColorScheme(preferences.theme.isLight ? .light : .dark)
        .environment(\.locale, preferences.language.locale)
        .environment(\.layoutDirection, preferences.language.layoutDirection)
        .presentationSizing(.form)
        .task {
            guard case .restoring = session.phase else { return }
            await session.restore()
        }
        .onChange(of: session.isAuthenticated) {
            if session.isAuthenticated, let user = session.user {
                reportEntry(.authenticated(user))
                dismiss()
            }
        }
        .onChange(of: session.pendingSignup) { oldValue, newValue in
            if oldValue?.pid != newValue?.pid {
                hidesPendingSignup = false
            }
        }
    }

    private func continueAsGuest() {
        guard !session.isWorking else { return }

        if session.isGuest {
            reportEntry(.guest)
            dismiss()
            return
        }

        isContinuingAsGuest = true
        Task {
            await session.continueAsGuest()
            isContinuingAsGuest = false

            if session.isGuest {
                reportEntry(.guest)
                dismiss()
            }
        }
    }

    private func reportEntry(_ outcome: AuthEntryOutcome) {
        guard !didReportEntry else { return }
        didReportEntry = true
        if outcome == .guest {
            onContinueAsGuest()
        }
        onEntryCompleted(outcome)
    }
}

private struct AuthHeader: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        VStack(spacing: 15) {
            FirasBrandMark(size: 52, showsWordmark: true)

            Text("auth.subtitle")
                .font(.body)
                .foregroundStyle(preferences.palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private enum AuthMode: String, CaseIterable, Hashable, Identifiable {
    case signIn
    case signUp

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .signIn: "auth.signIn"
        case .signUp: "auth.createAccount"
        }
    }
}

private enum AuthField: Hashable {
    case name
    case email
    case password
    case passwordConfirmation
}

private enum GoogleAuthFeedback: Equatable {
    case unavailable
    case failed

    var messageKey: LocalizedStringKey {
        switch self {
        case .unavailable: "auth.google.unavailable"
        case .failed: "auth.google.error"
        }
    }
}

private struct AuthModeSelector: View {
    @Binding var mode: AuthMode

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                ForEach(AuthMode.allCases) { option in
                    Button {
                        mode = option
                    } label: {
                        HStack(spacing: 10) {
                            Text(option.titleKey)
                                .font(.body.weight(.semibold))
                            Spacer(minLength: 12)
                            if mode == option {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(preferences.palette.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.horizontal, 13)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(
                            mode == option
                                ? preferences.palette.accent.opacity(0.12)
                                : preferences.palette.surfaceSunken,
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(
                                    mode == option
                                        ? preferences.palette.accent
                                        : preferences.palette.border,
                                    lineWidth: mode == option ? 1.5 : 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(mode == option ? .isSelected : [])
                }
            }
        } else {
            Picker("auth.signIn", selection: $mode) {
                ForEach(AuthMode.allCases) { option in
                    Text(option.titleKey).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)
        }
    }
}

private struct CredentialsCard: View {
    let googleOAuthProvider: GoogleOAuthProvider?
    @Binding var isGoogleWorking: Bool

    @Environment(PreferencesStore.self) private var preferences
    @Environment(SessionStore.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var mode: AuthMode = .signIn
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var passwordConfirmation = ""
    @State private var googleFeedback: GoogleAuthFeedback?
    @FocusState private var focusedField: AuthField?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var passwordsMismatch: Bool {
        mode == .signUp
            && !passwordConfirmation.isEmpty
            && password != passwordConfirmation
    }

    private var passwordHintKey: LocalizedStringKey {
        passwordsMismatch ? "auth.password.mismatch" : "auth.password.minimum"
    }

    private var canSubmit: Bool {
        guard !trimmedEmail.isEmpty, !password.isEmpty else { return false }

        switch mode {
        case .signIn:
            return true
        case .signUp:
            return !trimmedName.isEmpty
                && password.count >= 8
                && !passwordsMismatch
                && !passwordConfirmation.isEmpty
        }
    }

    private var stateAnimation: Animation? {
        reduceMotion || !preferences.motionEnabled ? nil : .snappy(duration: 0.28)
    }

    var body: some View {
        GlassSurface(cornerRadius: 26, tintStrength: 0.07) {
            VStack(spacing: 20) {
                AuthModeSelector(mode: $mode)
                    .disabled(isGoogleWorking || session.isWorking)

                VStack(spacing: 14) {
                    GoogleSignInButton(
                        isWorking: isGoogleWorking,
                        action: signInWithGoogle
                    )
                    .disabled(isGoogleWorking || session.isWorking)

                    AuthDivider()
                }

                VStack(spacing: 12) {
                    if mode == .signUp {
                        TextField("auth.name", text: $name)
                            .textContentType(.name)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.next)
                            .focused($focusedField, equals: .name)
                            .onSubmit { focusedField = .email }
                            .authFieldStyle()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    TextField("auth.email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .environment(\.layoutDirection, .leftToRight)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focusedField, equals: .email)
                        .onSubmit { focusedField = .password }
                        .authFieldStyle()

                    SecureField("auth.password", text: $password)
                        .textContentType(mode == .signIn ? .password : .newPassword)
                        .submitLabel(mode == .signIn ? .go : .next)
                        .focused($focusedField, equals: .password)
                        .onSubmit {
                            if mode == .signIn {
                                submit()
                            } else {
                                focusedField = .passwordConfirmation
                            }
                        }
                        .authFieldStyle()

                    if mode == .signUp {
                        SecureField("auth.passwordConfirm", text: $passwordConfirmation)
                            .textContentType(.newPassword)
                            .submitLabel(.go)
                            .focused($focusedField, equals: .passwordConfirmation)
                            .onSubmit(submit)
                            .authFieldStyle(isInvalid: passwordsMismatch)
                            .transition(.move(edge: .bottom).combined(with: .opacity))

                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: passwordsMismatch ? "exclamationmark.circle.fill" : "info.circle")
                                .accessibilityHidden(true)
                            Text(passwordHintKey)
                        }
                        .font(.caption)
                        .foregroundStyle(
                            passwordsMismatch
                                ? preferences.palette.error
                                : preferences.palette.textSecondary
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .disabled(isGoogleWorking || session.isWorking)
                .animation(stateAnimation, value: mode)

                if let googleFeedback {
                    AuthErrorBanner(messageKey: googleFeedback.messageKey)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let errorMessage = session.errorMessage, !errorMessage.isEmpty {
                    AuthErrorBanner(message: errorMessage)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Button(action: submit) {
                    HStack(spacing: 9) {
                        if session.isWorking {
                            ProgressView()
                                .tint(preferences.palette.onAccent)
                        } else {
                            Image(systemName: mode == .signIn ? "arrow.right.circle.fill" : "person.crop.circle.badge.plus")
                                .accessibilityHidden(true)
                        }

                        Text(mode.titleKey)
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(preferences.palette.accent)
                .disabled(!canSubmit || session.isWorking || isGoogleWorking)
            }
            .padding(20)
        }
        .defaultFocus($focusedField, .email)
        .animation(stateAnimation, value: session.errorMessage)
        .animation(stateAnimation, value: googleFeedback)
        .onChange(of: mode) {
            session.errorMessage = nil
            googleFeedback = nil
            password = ""
            passwordConfirmation = ""
            focusedField = mode == .signUp ? .name : .email
        }
    }

    private func submit() {
        guard canSubmit, !session.isWorking, !isGoogleWorking else { return }
        focusedField = nil
        session.errorMessage = nil
        googleFeedback = nil

        Task {
            switch mode {
            case .signIn:
                await session.login(email: trimmedEmail, password: password)
            case .signUp:
                await session.signup(
                    name: trimmedName,
                    email: trimmedEmail,
                    password: password
                )
            }
        }
    }

    private func signInWithGoogle() {
        guard !isGoogleWorking, !session.isWorking else { return }

        focusedField = nil
        session.errorMessage = nil
        googleFeedback = nil

        guard let googleOAuthProvider else {
            googleFeedback = .unavailable
            return
        }

        isGoogleWorking = true
        Task { @MainActor in
            defer { isGoogleWorking = false }

            await session.signInWithGoogle(using: googleOAuthProvider)
            if !session.isAuthenticated, session.errorMessage != nil {
                session.errorMessage = nil
                googleFeedback = .failed
            }
        }
    }
}

private struct GoogleSignInButton: View {
    let isWorking: Bool
    let action: () -> Void

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Button(action: action) {
            ZStack {
                Group {
                    if isWorking {
                        Text("auth.google.loading")
                    } else {
                        Text("auth.google")
                    }
                }
                .font(.headline)
                .foregroundStyle(preferences.palette.textPrimary)

                HStack {
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                            .tint(preferences.palette.accent)
                            .accessibilityHidden(true)
                    } else {
                        Text(verbatim: "G")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundStyle(preferences.palette.accent)
                            .accessibilityHidden(true)
                    }

                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                preferences.palette.surface,
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(preferences.palette.borderStrong, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct AuthDivider: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        HStack(spacing: 12) {
            dividerLine

            Text("auth.or")
                .font(.caption.weight(.medium))
                .foregroundStyle(preferences.palette.textMuted)

            dividerLine
        }
        .accessibilityElement(children: .combine)
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(preferences.palette.border)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

private struct VerificationCard: View {
    let email: String
    let useAnotherAccount: () -> Void

    @Environment(PreferencesStore.self) private var preferences
    @Environment(SessionStore.self) private var session

    var body: some View {
        GlassSurface(cornerRadius: 26, tintStrength: 0.07) {
            VStack(spacing: 19) {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .font(.system(size: 42, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(preferences.palette.accent)
                    .accessibilityHidden(true)

                VStack(spacing: 7) {
                    Text("auth.verify.title")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(preferences.palette.textPrimary)

                    Text("auth.verify.body")
                        .font(.body)
                        .foregroundStyle(preferences.palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(email)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(preferences.palette.accent)
                        .textSelection(.enabled)
                        .environment(\.layoutDirection, .leftToRight)
                }
                .accessibilityElement(children: .combine)

                if let errorMessage = session.errorMessage, !errorMessage.isEmpty {
                    AuthErrorBanner(message: errorMessage)
                }

                Button {
                    session.errorMessage = nil
                    Task {
                        await session.checkVerification()
                    }
                } label: {
                    HStack(spacing: 9) {
                        if session.isWorking {
                            ProgressView()
                                .tint(preferences.palette.onAccent)
                        } else {
                            Image(systemName: "checkmark.seal.fill")
                                .accessibilityHidden(true)
                        }
                        Text("auth.verify.check")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(preferences.palette.accent)
                .disabled(session.isWorking)

                Button("auth.back", action: useAnotherAccount)
                    .buttonStyle(.plain)
                    .foregroundStyle(preferences.palette.textSecondary)
                    .frame(minHeight: 44)
            }
            .padding(22)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct AuthenticatedCard: View {
    let user: User
    let done: () -> Void

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        GlassSurface(cornerRadius: 26, tintStrength: 0.07) {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 46))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(preferences.palette.success)
                    .accessibilityHidden(true)

                VStack(spacing: 5) {
                    Text("auth.signedIn")
                        .font(.title2.weight(.semibold))
                    Text(user.name)
                        .font(.headline)
                        .foregroundStyle(preferences.palette.accent)
                    Text("auth.signedIn.footer")
                        .font(.subheadline)
                        .foregroundStyle(preferences.palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .accessibilityElement(children: .combine)

                Button("common.done", action: done)
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
            }
            .padding(22)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct AuthErrorBanner: View {
    private let message: Text

    @Environment(PreferencesStore.self) private var preferences

    init(message: String) {
        self.message = Text(verbatim: message)
    }

    init(messageKey: LocalizedStringKey) {
        self.message = Text(messageKey)
    }

    var body: some View {
        Label {
            message
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
        }
        .foregroundStyle(preferences.palette.error)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(preferences.palette.error.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

private struct AuthFieldModifier: ViewModifier {
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

private extension View {
    func authFieldStyle(isInvalid: Bool = false) -> some View {
        modifier(AuthFieldModifier(isInvalid: isInvalid))
    }
}
