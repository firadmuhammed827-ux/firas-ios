import SwiftUI
import UIKit

enum ShellSheet: String, Identifiable {
    case settings
    case authentication

    var id: String { rawValue }

    /// Where an account button leads. A member's account lives in Settings,
    /// which opens on its Account page; a guest gets the sign-in sheet.
    static func account(isAuthenticated: Bool) -> ShellSheet {
        isAuthenticated ? .settings : .authentication
    }
}

struct FirasAppShell: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(SessionStore.self) private var session
    @Environment(ChatStore.self) private var chatStore
    @Environment(CodeStore.self) private var codeStore
    @Environment(BrainStore.self) private var brainStore
    @Environment(MediaStudioStore.self) private var mediaStudioStore
    @Environment(PromptEngineerStore.self) private var promptEngineerStore
    @Environment(NotificationCoordinator.self) private var notificationCoordinator
    @Environment(MentronXEntryCoordinator.self) private var entryCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedProduct: ProductKind = .ai
    @State private var compactSidebarPresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var compactColumn: NavigationSplitViewColumn = .detail
    @State private var presentedSheet: ShellSheet?
    @State private var showsVoiceCall = false
    @State private var opensSignInAfterCall = false
    @State private var mediaPresentationRequest: MediaPresentationRequest?
    @State private var returnsFromBackground = false

    private let loadsRemoteData: Bool

    init(loadsRemoteData: Bool = true) {
        self.loadsRemoteData = loadsRemoteData
    }

    var body: some View {
        Group {
            if usesSplitView {
                splitLayout
            } else {
                drawerLayout
            }
        }
        .tint(preferences.palette.accent)
        .preferredColorScheme(preferences.theme.isLight ? .light : .dark)
        .environment(\.locale, preferences.language.locale)
        .environment(\.layoutDirection, preferences.language.layoutDirection)
        // The entry intro covers the app; VoiceOver must not move under it.
        .accessibilityHidden(entryCoordinator.isPresented)
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .settings:
                SettingsView(onAuthEntryCompleted: handleAuthEntry)
            case .authentication:
                AuthView(onEntryCompleted: handleAuthEntry)
            }
        }
        .fullScreenCover(isPresented: $showsVoiceCall, onDismiss: { openSignInAfterCall() }) {
            VoiceCallView(onSignIn: signInFromCall)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { returnsFromBackground = true }
            guard phase == .active, returnsFromBackground else { return }
            returnsFromBackground = false
            reloadAfterReturningToForeground()
        }
        .task {
            guard loadsRemoteData, session.phase == .restoring else { return }
            await session.restore()
        }
        .task(id: session.identityID) {
            // Drop stale local product state on every identity change, even
            // when that product is not the visible screen. Jobs stay on cloud.
            codeStore.synchronizeOwner()
            brainStore.synchronizeOwner()
            mediaStudioStore.synchronizeOwner()
            promptEngineerStore.synchronizeOwner()
            guard loadsRemoteData, session.identityID != nil else { return }
            await chatStore.loadConversations()
        }
        .task(id: pendingNotificationRouteKey) {
            await routePendingNotification()
        }
        .onChange(of: session.isWorking) { _, working in
            guard loadsRemoteData, !working else { return }
            mediaStudioStore.resumeIfNeeded()
            promptEngineerStore.synchronizeOwner()
            promptEngineerStore.resumeIfNeeded()
            // The identity task above never reruns for the same account, so
            // Chat re-reads its list and re-observes a fenced answer here.
            Task { await chatStore.reloadAfterSessionOperationIfNeeded() }
        }
        .onChange(of: session.identityGeneration) { _, _ in
            promptEngineerStore.synchronizeOwner()
            // An operation that starts and ends within one main-actor turn
            // never shows isWorking changing, but its epoch still fenced Chat.
            // The store's pending-reload flag keeps both hooks to one load.
            if loadsRemoteData, !session.isWorking {
                Task { await chatStore.reloadAfterSessionOperationIfNeeded() }
            }
        }
    }

    /// Chosen by device, never by size class. Rotating a large iPhone or
    /// resizing an iPad window must not swap the view tree, which would close
    /// open sheets, drop typed text and retire a send still being prepared.
    /// The split view adapts to a narrow iPad window by itself.
    private var usesSplitView: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var splitLayout: some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: $compactColumn
        ) {
            ShellSidebar(
                selectedProduct: $selectedProduct,
                compactSidebarPresented: $compactSidebarPresented,
                presentedSheet: $presentedSheet,
                isCompact: false,
                floatsOverContent: horizontalSizeClass == .regular,
                onShowDetail: showDetailColumn
            )
            .navigationSplitViewColumnWidth(min: 270, ideal: 304, max: 360)
        } detail: {
            // The split view's own sidebar toggle and back button are the
            // only controls for the sidebar here.
            detailView(showsSidebarButton: false)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var drawerLayout: some View {
        GeometryReader { proxy in
            ZStack {
                detailView(showsSidebarButton: true)
                    .environment(\.layoutDirection, preferences.language.layoutDirection)
                    .allowsHitTesting(!compactSidebarPresented)
                    .accessibilityHidden(compactSidebarPresented)

                if compactSidebarPresented {
                    Button(action: closeCompactSidebar) {
                        Color.black.opacity(0.30)
                            .ignoresSafeArea()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(ShellStrings.dismissOverlay))

                    ShellSidebar(
                        selectedProduct: $selectedProduct,
                        compactSidebarPresented: $compactSidebarPresented,
                        presentedSheet: $presentedSheet,
                        isCompact: true
                    )
                    .environment(\.layoutDirection, preferences.language.layoutDirection)
                    .frame(width: min(360, max(0, proxy.size.width - 32)))
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: sidebarAlignment
                    )
                    .transition(.move(edge: sidebarEdge))
                    .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 8)
                }
            }
            // The drawer's edge is named explicitly below, so this layer is
            // measured left to right; its contents read in the app language.
            .environment(\.layoutDirection, .leftToRight)
        }
    }

    @ViewBuilder
    private func detailView(showsSidebarButton: Bool) -> some View {
        switch selectedProduct {
        case .ai:
            ChatScreen(
                showsSidebarButton: showsSidebarButton,
                onOpenSidebar: openCompactSidebar,
                onOpenProfile: openProfile,
                onOpenBrain: openBrain,
                onStartCall: startVoiceCall,
                mediaPresentationRequest: mediaPresentationRequest,
                onConsumeMediaPresentation: { mediaPresentationRequest = nil }
            )
        case .code:
            CodeScreen(
                store: codeStore,
                showsSidebarButton: showsSidebarButton,
                onOpenSidebar: openCompactSidebar,
                onOpenProfile: openProfile
            )
        case .brain:
            BrainScreen(
                store: brainStore,
                showsSidebarButton: showsSidebarButton,
                onOpenSidebar: openCompactSidebar,
                onOpenProfile: openProfile
            )
        }
    }

    /// Arabic opens the drawer from the right, where its reading starts.
    private var sidebarEdge: Edge {
        preferences.language.layoutDirection == .rightToLeft ? .trailing : .leading
    }

    private var sidebarAlignment: Alignment {
        preferences.language.layoutDirection == .rightToLeft ? .trailing : .leading
    }

    private var shellAnimation: Animation? {
        guard preferences.motionEnabled, !reduceMotion else { return nil }
        return .snappy(duration: 0.30, extraBounce: 0)
    }

    private func openCompactSidebar() {
        if usesSplitView {
            withAnimation(shellAnimation) {
                columnVisibility = .all
            }
            compactColumn = .sidebar
            return
        }
        withAnimation(shellAnimation) {
            compactSidebarPresented = true
        }
    }

    /// A choice in the split view's sidebar shows its result; this matters
    /// only while a narrow iPad window has collapsed the split view.
    private func showDetailColumn() {
        compactColumn = .detail
    }

    /// Re-reads the chat list and the open chat after the app was in the
    /// background, which also re-observes an answer still running on the
    /// server. It never cancels anything; a sign-in that could not finish at
    /// launch is tried again. A notice on screen stays: switching apps is not
    /// closing it.
    private func reloadAfterReturningToForeground() {
        guard loadsRemoteData, !session.isWorking else { return }
        guard session.identityID != nil else {
            if session.phase == .restoring {
                Task { await session.restore() }
            }
            return
        }
        Task {
            await chatStore.loadConversations(clearsError: false)
            await chatStore.refreshSelectedConversation()
        }
    }

    private func closeCompactSidebar() {
        withAnimation(shellAnimation) {
            compactSidebarPresented = false
        }
    }

    private func openProfile() {
        presentedSheet = ShellSheet.account(isAuthenticated: session.isAuthenticated)
    }

    private func openBrain() {
        selectedProduct = .brain
        closeCompactSidebar()
    }

    private func startVoiceCall() {
        showsVoiceCall = true
    }

    /// A call that needs an account closes first; sign-in opens once the
    /// call's cover has gone, so the two never present at once.
    private func signInFromCall() {
        opensSignInAfterCall = true
        showsVoiceCall = false
    }

    private func openSignInAfterCall() {
        guard opensSignInAfterCall else { return }
        opensSignInAfterCall = false
        presentedSheet = .authentication
    }

    /// The intro greets a sign-in, the way the web plays it at its sign-in
    /// door. Staying a guest opens nothing new here: a guest session already
    /// starts on its own at launch.
    private func handleAuthEntry(_ outcome: AuthEntryOutcome) {
        presentedSheet = nil
        switch outcome {
        case .authenticated:
            entryCoordinator.present()
        case .guest:
            break
        }
    }

    private func routePendingNotification() async {
        guard let destination = notificationCoordinator.pendingDestination else { return }
        guard !session.isWorking else { return }
        guard session.isAuthenticated else {
            if session.phase != .restoring {
                presentedSheet = .authentication
            }
            return
        }

        selectedProduct = destination.product
        compactSidebarPresented = false
        compactColumn = .detail
        if horizontalSizeClass == .regular {
            columnVisibility = .detailOnly
        }

        switch destination.product {
        case .ai:
            if destination.chatID == nil, promptEngineerStore.matchesNotification(jobID: destination.jobID) {
                promptEngineerStore.requestPresentation()
                promptEngineerStore.resumeIfNeeded()
            } else if let mediaKind = destination.mediaKind
                ?? mediaStudioStore.kind(forNotificationJobID: destination.jobID) {
                mediaStudioStore.resumeNotificationJob(
                    jobID: destination.jobID,
                    kind: mediaKind
                )
                mediaPresentationRequest = MediaPresentationRequest(
                    kind: mediaKind,
                    focusedJobID: destination.jobID
                )
            } else if let chatID = destination.chatID {
                await chatStore.select(chatID)
            }
        case .code:
            codeStore.resumeIfNeeded()
        case .brain:
            await brainStore.loadLibrary()
        }

        notificationCoordinator.consumePendingDestination(id: destination.id)
    }

    private var pendingNotificationRouteKey: String {
        let destination = notificationCoordinator.pendingDestination?.id ?? "none"
        let identity = session.identityID ?? "restoring"
        return "\(destination)|\(identity)|\(session.identityGeneration)|\(session.isAuthenticated)|\(session.isWorking)"
    }
}
