import SwiftUI

enum ShellSheet: String, Identifiable {
    case settings
    case authentication

    var id: String { rawValue }
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

    @State private var selectedProduct: ProductKind = .ai
    @State private var compactSidebarPresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var presentedSheet: ShellSheet?
    @State private var showsVoiceCall = false
    @State private var mediaPresentationRequest: MediaPresentationRequest?

    private let loadsRemoteData: Bool

    init(loadsRemoteData: Bool = true) {
        self.loadsRemoteData = loadsRemoteData
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .tint(preferences.palette.accent)
        .preferredColorScheme(preferences.theme.isLight ? .light : .dark)
        .environment(\.locale, preferences.language.locale)
        .environment(\.layoutDirection, .leftToRight)
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .settings:
                SettingsView(onAuthEntryCompleted: handleAuthEntry)
            case .authentication:
                AuthView(onEntryCompleted: handleAuthEntry)
            }
        }
        .fullScreenCover(isPresented: $showsVoiceCall) {
            VoiceCallView()
        }
        .onChange(of: horizontalSizeClass) { _, sizeClass in
            if sizeClass == .regular {
                compactSidebarPresented = false
            }
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
        }
        .onChange(of: session.identityGeneration) { _, _ in promptEngineerStore.synchronizeOwner() }
    }

    private var regularLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ShellSidebar(
                selectedProduct: $selectedProduct,
                compactSidebarPresented: $compactSidebarPresented,
                presentedSheet: $presentedSheet,
                isCompact: false,
                onCloseSidebar: hideRegularSidebar
            )
            .navigationSplitViewColumnWidth(min: 270, ideal: 304, max: 360)
        } detail: {
            detailView(showsSidebarButton: columnVisibility == .detailOnly)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var compactLayout: some View {
        GeometryReader { proxy in
            ZStack {
                detailView(showsSidebarButton: true)
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
                    .frame(width: min(360, max(0, proxy.size.width - 32)))
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .leading
                    )
                    .transition(.move(edge: sidebarEdge))
                    .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 8)
                }
            }
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

    private var sidebarEdge: Edge { .leading }

    private var shellAnimation: Animation? {
        guard preferences.motionEnabled, !reduceMotion else { return nil }
        return .snappy(duration: 0.30, extraBounce: 0)
    }

    private func openCompactSidebar() {
        if horizontalSizeClass == .regular {
            withAnimation(shellAnimation) {
                columnVisibility = .all
            }
            return
        }
        withAnimation(shellAnimation) {
            compactSidebarPresented = true
        }
    }

    private func hideRegularSidebar() {
        withAnimation(shellAnimation) {
            columnVisibility = .detailOnly
        }
    }

    private func closeCompactSidebar() {
        withAnimation(shellAnimation) {
            compactSidebarPresented = false
        }
    }

    private func openProfile() {
        presentedSheet = .authentication
    }

    private func openBrain() {
        selectedProduct = .brain
        closeCompactSidebar()
    }

    private func startVoiceCall() {
        showsVoiceCall = true
    }

    private func handleAuthEntry(_ outcome: AuthEntryOutcome) {
        presentedSheet = nil
        switch outcome {
        case .authenticated, .guest:
            entryCoordinator.present()
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
