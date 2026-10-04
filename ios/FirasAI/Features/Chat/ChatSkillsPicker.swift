import SwiftUI

struct ChatSkillsPicker: View {
    let ownerID: String?
    @Binding var selection: ChatSkillSelection
    @Environment(AccountSkillsStore.self) private var store
    @State private var didAttemptLoad = false
    @State private var hasLoadedCatalogue = false
    @State private var loadedEpoch: Int?
    @State private var loadTicket: AccountSkillsTicket?
    @State private var lifetime = UUID()
    @Environment(SessionStore.self) private var session
    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                FirasBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(ChatStrings.skillsDetail)
                            .font(.subheadline)
                            .foregroundStyle(preferences.palette.textMuted)

                        if ownerID == nil {
                            Text(ChatStrings.skillsSignIn)
                                .foregroundStyle(preferences.palette.textPrimary)
                        } else if store.isWorking || !didAttemptLoad {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 60)
                        } else if store.error != nil || !hasLoadedCatalogue {
                            Text(ChatStrings.skillsLoadFailed)
                                .foregroundStyle(preferences.palette.textMuted)
                            Button {
                                guard let ticket = store.operationTicket() else { return }
                                Task { await load(ticket: ticket) }
                            } label: {
                                Text(ChatStrings.skillsRetry).frame(minHeight: 44)
                            }
                        } else if enabledSkills.isEmpty {
                            Text(ChatStrings.skillsEmpty)
                                .foregroundStyle(preferences.palette.textMuted)
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(enabledSkills) { skill in
                                    skillRow(skill)
                                }
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(Text(ChatStrings.selectSkills))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text(ChatStrings.skillsDone).frame(minHeight: 44)
                    }
                }
            }
        }
        .environment(\.layoutDirection, preferences.language.layoutDirection)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: session.identityGeneration) {
            store.synchronizeOwner()
            guard let ticket = store.operationTicket() else { return }
            await load(ticket: ticket)
        }
        .onChange(of: session.isWorking) {
            store.synchronizeOwner()
            if !session.isWorking, let ticket = store.operationTicket() {
                Task { await load(ticket: ticket) }
            }
        }
        .onDisappear {
            lifetime = UUID()
            loadedEpoch = nil
            if let loadTicket { store.invalidate(ticket: loadTicket) }
        }
    }

    private var enabledSkills: [AccountSkill] {
        guard session.isAuthenticated, !session.isWorking, session.identityID == ownerID,
              loadedEpoch == session.identityGeneration, store.ownSkillsLoaded else { return [] }
        return store.skills.filter { $0.enabled && AccountSkillRequest.permitsID($0.id) }
    }

    private func skillRow(_ skill: AccountSkill) -> some View {
        let isSelected = selection.ids.contains(skill.id)
        return Button {
            guard let ownerID, session.isAuthenticated, !session.isWorking, session.identityID == ownerID,
                  loadedEpoch == session.identityGeneration, store.ownSkillsLoaded else { return }
            selection.toggle(skill, available: store.skills, expectedOwnerID: ownerID)
        } label: {
            GlassSurface(cornerRadius: 18, tintStrength: 0.035, usesLiquidGlass: false) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: skill.name).font(.body.weight(.semibold))
                        Text(verbatim: skill.cues.joined(separator: " · "))
                            .font(.caption).lineLimit(2)
                            .foregroundStyle(preferences.palette.textMuted)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? preferences.palette.accent : preferences.palette.textMuted)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(preferences.palette.textPrimary)
                .padding(14)
                .frame(minHeight: 58)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isSelected && selection.skills.count >= ChatSkillSelection.maximumCount)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func load(ticket: AccountSkillsTicket) async {
        guard let ownerID, session.isAuthenticated, session.identityID == ownerID else {
            store.synchronizeOwner()
            return
        }
        let capturedLifetime = lifetime
        loadTicket = ticket
        hasLoadedCatalogue = false
        loadedEpoch = nil
        let refreshed = await store.load(ticket: ticket)
        guard !Task.isCancelled, capturedLifetime == lifetime, session.identityID == ticket.ownerID,
              session.identityGeneration == ticket.identityGeneration else { return }
        didAttemptLoad = true
        guard refreshed else { return }
        hasLoadedCatalogue = true
        loadedEpoch = ticket.identityGeneration
        selection.reconcile(available: store.skills, expectedOwnerID: ownerID)
    }
}
