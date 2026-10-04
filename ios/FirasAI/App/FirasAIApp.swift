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
    @State private var entryCoordinator: MentronXEntryCoordinator

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
        _entryCoordinator = State(initialValue: MentronXEntryCoordinator())
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
                .environment(entryCoordinator)
        }
    }
}

private struct FirasRootView: View {
    @Environment(MentronXEntryCoordinator.self) private var entryCoordinator
    @Environment(PromptEngineerStore.self) private var promptEngineerStore
    @Environment(\.scenePhase) private var scenePhase

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
        .onChange(of: scenePhase, initial: true) { _, phase in
            promptEngineerStore.setForeground(phase == .active)
        }
    }
}
