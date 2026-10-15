import Observation
import SwiftUI

@MainActor
@Observable
final class MentronXEntryCoordinator {
    private(set) var isPresented = false

    func present() {
        isPresented = true
    }

    func finish() {
        isPresented = false
    }
}

@main
struct FirasAIApp: App {
    @UIApplicationDelegateAdaptor(FirasAppDelegate.self) private var appDelegate

    @State private var preferences: PreferencesStore
    @State private var session: SessionStore
    @State private var accountSkillsStore: AccountSkillsStore
    @State private var chatStore: ChatStore
    @State private var promptEngineerStore: PromptEngineerStore
    @State private var codeStore: CodeStore
    @State private var brainStore: BrainStore
    @State private var mediaStudioStore: MediaStudioStore
    @State private var notificationCoordinator: NotificationCoordinator

    init() {
        let api = FirasAPI(configuration: .live)
        let session = SessionStore(api: api)
        let chatStore = ChatStore(session: session, api: api)

        _preferences = State(initialValue: PreferencesStore())
        _session = State(initialValue: session)
        _accountSkillsStore = State(initialValue: AccountSkillsStore(session: session, api: api))
        _chatStore = State(initialValue: chatStore)
        _promptEngineerStore = State(initialValue: PromptEngineerStore(session: session, chatStore: chatStore, api: api))
        _codeStore = State(initialValue: CodeStore(session: session, api: api))
        _brainStore = State(initialValue: BrainStore(session: session, api: api))
        _mediaStudioStore = State(initialValue: MediaStudioStore(api: api, session: session))
        _notificationCoordinator = State(initialValue: NotificationCoordinator.shared)
    }

    var body: some Scene {
        WindowGroup {
            FirasRootView()
                .environment(preferences)
                .environment(session)
                .environment(accountSkillsStore)
                .environment(chatStore)
                .environment(promptEngineerStore)
                .environment(codeStore)
                .environment(brainStore)
                .environment(mediaStudioStore)
                .environment(notificationCoordinator)
        }
    }
}

private struct FirasRootView: View {
    // One per window: a sign-in in one iPad window plays the intro there only.
    @State private var entryCoordinator = MentronXEntryCoordinator()
    @Environment(PromptEngineerStore.self) private var promptEngineerStore
    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.scenePhase) private var scenePhase
    // This view sits outside its own .dynamicTypeSize override, so this is
    // always the size chosen in iOS Settings; Text size steps from it.
    @Environment(\.dynamicTypeSize) private var systemTypeSize

    var body: some View {
        ZStack {
            FirasAppShell()

            if entryCoordinator.isPresented {
                MentronXEntryView {
                    entryCoordinator.finish()
                }
                .zIndex(100)
                .transition(.opacity)
            }
        }
        .environment(entryCoordinator)
        // Equal to preferences.resolvedTypeSize, computed from the local read so
        // the first frame is already right. A presented sheet or cover is not
        // guaranteed to inherit it, so each one re-applies resolvedTypeSize at
        // its root, beside its layoutDirection.
        .dynamicTypeSize(preferences.fontScale.dynamicTypeSize(from: systemTypeSize))
        .onChange(of: systemTypeSize, initial: true) { _, size in
            preferences.systemTypeSize = size
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            promptEngineerStore.setForeground(phase == .active)
        }
    }
}
