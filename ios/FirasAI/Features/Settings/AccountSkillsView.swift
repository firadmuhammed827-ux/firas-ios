import SwiftUI

enum SkillsStrings {
    static let title = LocalizedStringResource("skills.title", table: "Skills")
    static let detail = LocalizedStringResource("skills.detail", table: "Skills")
    static let create = LocalizedStringResource("skills.create", table: "Skills")
    static let edit = LocalizedStringResource("skills.edit", table: "Skills")
    static let enabled = LocalizedStringResource("skills.enabled", table: "Skills")
    static let disabled = LocalizedStringResource("skills.disabled", table: "Skills")
    static let automatic = LocalizedStringResource("skills.auto", table: "Skills")
    static let always = LocalizedStringResource("skills.always", table: "Skills")
    static let empty = LocalizedStringResource("skills.empty", table: "Skills")
    static let name = LocalizedStringResource("skills.name", table: "Skills")
    static let cues = LocalizedStringResource("skills.cues", table: "Skills")
    static let rules = LocalizedStringResource("skills.rules", table: "Skills")
    static let mode = LocalizedStringResource("skills.mode", table: "Skills")
    static let cuesHint = LocalizedStringResource("skills.cuesHint", table: "Skills")
    static let rulesHint = LocalizedStringResource("skills.rulesHint", table: "Skills")
    static let save = LocalizedStringResource("skills.save", table: "Skills")
    static let cancel = LocalizedStringResource("skills.cancel", table: "Skills")
    static let remove = LocalizedStringResource("skills.delete", table: "Skills")
    static let removeHint = LocalizedStringResource("skills.deleteHint", table: "Skills")
    static let signIn = LocalizedStringResource("skills.signIn", table: "Skills")
    static let retry = LocalizedStringResource("skills.retry", table: "Skills")
    static let unconfirmed = LocalizedStringResource("skills.unconfirmed", table: "Skills")
    static let review = LocalizedStringResource("skills.review", table: "Skills")
    static let reviewHint = LocalizedStringResource("skills.reviewHint", table: "Skills")
    static let savedList = LocalizedStringResource("skills.savedList", table: "Skills")
    static let acknowledge = LocalizedStringResource("skills.acknowledge", table: "Skills")

    static func problem(_ code: String) -> LocalizedStringResource {
        switch code.split(separator: ":").first.map(String.init) ?? code {
        case "name_length", "name_too_short", "name_too_long":
            LocalizedStringResource("skills.error.name", table: "Skills")
        case "cues_length", "cues_too_few", "cues_too_many", "cue_length":
            LocalizedStringResource("skills.error.cues", table: "Skills")
        case "rules_length", "rules_too_few", "rules_too_many", "rule_too_short", "rule_too_long":
            LocalizedStringResource("skills.error.rules", table: "Skills")
        case "rules_total", "rules_too_long_total":
            LocalizedStringResource("skills.error.total", table: "Skills")
        case "forbidden_phrase", "rejected":
            LocalizedStringResource("skills.error.safety", table: "Skills")
        case "account_full":
            LocalizedStringResource("skills.error.full", table: "Skills")
        case "skill_not_found":
            LocalizedStringResource("skills.error.missing", table: "Skills")
        case "skills_mutation_unconfirmed":
            unconfirmed
        default:
            LocalizedStringResource("skills.error.unavailable", table: "Skills")
        }
    }
}

struct AccountSkillsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(PreferencesStore.self) private var preferences
    @Environment(AccountSkillsStore.self) private var store
    @State private var editor: SkillEditorSelection?
    @State private var deletion: SkillDeletionSelection?
    @State private var navigationLifetime = UUID()

    var body: some View {
        ZStack {
            FirasBackground()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text(SkillsStrings.detail)
                        .font(.subheadline)
                        .foregroundStyle(preferences.palette.textSecondary)
                    if session.isAuthenticated {
                        if store.mutationUncertain { SkillMutationReview(store: store) }
                        else if let error = store.error { SkillErrorNotice(error: error) }
                        if store.isWorking { ProgressView().frame(maxWidth: .infinity) }
                        if store.skills.isEmpty, !store.isWorking, store.error == nil {
                            ContentUnavailableView {
                                Label { Text(SkillsStrings.empty) } icon: { Image(systemName: "sparkles.rectangle.stack") }
                            }
                        }
                        ForEach(store.skills) { skill in
                            skillRow(skill)
                        }
                        if store.error != nil, !store.mutationUncertain {
                            Button {
                                guard let ticket = store.operationTicket() else { return }
                                Task { await store.load(ticket: ticket) }
                            } label: { Text(SkillsStrings.retry) }
                                .frame(minHeight: 44)
                                .disabled(store.isWorking)
                        }
                    } else {
                        Text(SkillsStrings.signIn)
                    }
                }
                .frame(maxWidth: 760)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await refresh() }
        }
        .navigationTitle(Text(SkillsStrings.title))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { openEditor(nil) } label: {
                    Label { Text(SkillsStrings.create) } icon: { Image(systemName: "plus") }
                }
                .disabled(!store.canMutate || store.skills.count >= 40)
            }
        }
        .task(id: session.identityGeneration) { await refresh() }
        .onChange(of: session.identityID) {
            editor = nil
            deletion = nil
            store.synchronizeOwner()
        }
        .onChange(of: session.identityGeneration) {
            deletion = nil
            store.synchronizeOwner()
        }
        .onChange(of: session.isWorking) {
            store.synchronizeOwner()
            if !session.isWorking, let ticket = store.operationTicket() {
                Task { await store.load(ticket: ticket) }
            }
        }
        .onDisappear {
            deletion = nil
            navigationLifetime = UUID()
            if editor == nil { store.invalidate() }
        }
        .sheet(item: $editor) { selection in
            AccountSkillEditor(skill: selection.skill, ownerID: selection.ownerID, store: store)
        }
        .confirmationDialog(Text(SkillsStrings.remove), isPresented: Binding(
            get: { deletion != nil }, set: { if !$0 { deletion = nil } }
        ), presenting: deletion) { pending in
            Button(role: .destructive) {
                deletion = nil
                guard pending.lifetime == navigationLifetime,
                      session.identityID == pending.ticket.ownerID,
                      session.identityGeneration == pending.ticket.identityGeneration,
                      store.canMutate else { return }
                Task { await store.delete(pending.skill, ticket: pending.ticket) }
            } label: { Text(SkillsStrings.remove) }
        } message: { pending in
            Text(pending.skill.name) + Text("\n") + Text(SkillsStrings.removeHint)
        }
        .tint(preferences.palette.accent)
    }

    private func skillRow(_ skill: AccountSkill) -> some View {
        // Skill content is reading content; glass is reserved for the controls.
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name).font(.headline)
                    Text(skill.mode == .always ? SkillsStrings.always : SkillsStrings.automatic)
                        .font(.caption).foregroundStyle(preferences.palette.textSecondary)
                }
                Spacer()
                Menu {
                    Button { openEditor(skill) } label: { Text(SkillsStrings.edit) }
                    Button(role: .destructive) {
                        guard store.canMutate, let ticket = store.operationTicket() else { return }
                        deletion = SkillDeletionSelection(skill: skill, ticket: ticket, lifetime: navigationLifetime)
                    } label: { Text(SkillsStrings.remove) }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel(Text(SkillsStrings.edit) + Text(" ") + Text(skill.name))
                .disabled(!store.canMutate)
            }
            Toggle(isOn: Binding(get: { skill.enabled }, set: { enabled in
                guard store.canMutate, let ticket = store.operationTicket() else { return }
                Task { await store.setEnabled(skill, enabled: enabled, ticket: ticket) }
            })) { Text(SkillsStrings.enabled) }
                .frame(minHeight: 44)
                .disabled(!store.canMutate)
        }
        .padding(18)
        .background(preferences.palette.surface, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(preferences.palette.border, lineWidth: 0.5))
    }

    private func openEditor(_ skill: AccountSkill?) {
        guard store.canMutate, let ticket = store.operationTicket() else { return }
        editor = SkillEditorSelection(skill: skill, ownerID: ticket.ownerID)
    }

    private func refresh() async {
        store.synchronizeOwner()
        guard !Task.isCancelled, let ticket = store.operationTicket() else { return }
        await store.load(ticket: ticket)
    }
}

private struct SkillEditorSelection: Identifiable {
    let id = UUID()
    let skill: AccountSkill?
    let ownerID: String
}

private struct SkillDeletionSelection {
    let skill: AccountSkill
    let ticket: AccountSkillsTicket
    let lifetime: UUID
}

private struct AccountSkillEditor: View {
    let skill: AccountSkill?
    let ownerID: String
    let store: AccountSkillsStore
    @Environment(SessionStore.self) private var session
    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var cues: String
    @State private var rules: String
    @State private var mode: AccountSkillMode
    @State private var enabled: Bool
    @State private var committedID: String?
    @State private var attemptedSave = false
    @State private var draftRevision = 0
    @State private var isVisible = false
    @State private var submissionID: UUID?
    @State private var submissionTicket: AccountSkillsTicket?
    @State private var submissionTask: Task<Void, Never>?

    init(skill: AccountSkill?, ownerID: String, store: AccountSkillsStore) {
        self.skill = skill
        self.ownerID = ownerID
        self.store = store
        // These values seed a separate draft; editing never mutates a server row.
        _name = State(initialValue: skill?.name ?? "")
        _cues = State(initialValue: skill?.cues.joined(separator: "\n") ?? "")
        _rules = State(initialValue: skill?.rules.joined(separator: "\n") ?? "")
        _mode = State(initialValue: skill?.mode ?? .auto)
        _enabled = State(initialValue: skill?.enabled ?? true)
        _committedID = State(initialValue: skill?.id)
    }

    private var request: AccountSkillRequest {
        AccountSkillRequest(id: committedID, name: name,
            cues: cues.components(separatedBy: .newlines), rules: rules.components(separatedBy: .newlines),
            mode: mode, enabled: enabled)
    }

    var body: some View {
        NavigationStack {
            Group {
                if session.isAuthenticated, session.identityID == ownerID {
                    Form {
                        Section {
                            TextField(String(localized: SkillsStrings.name), text: revisedBinding($name))
                                .textInputAutocapitalization(.sentences)
                            Picker(selection: revisedBinding($mode)) {
                                Text(SkillsStrings.automatic).tag(AccountSkillMode.auto)
                                Text(SkillsStrings.always).tag(AccountSkillMode.always)
                            } label: { Text(SkillsStrings.mode) }
                            Toggle(isOn: revisedBinding($enabled)) { Text(SkillsStrings.enabled) }
                        }
                        Section {
                            TextEditor(text: revisedBinding($cues)).frame(minHeight: 110)
                                .accessibilityLabel(Text(SkillsStrings.cues))
                        } header: { Text(SkillsStrings.cues) } footer: { Text(SkillsStrings.cuesHint) }
                        Section {
                            TextEditor(text: revisedBinding($rules)).frame(minHeight: 200)
                                .accessibilityLabel(Text(SkillsStrings.rules))
                        } header: { Text(SkillsStrings.rules) } footer: { Text(SkillsStrings.rulesHint) }
                        if attemptedSave, !request.validationProblems.isEmpty {
                            ForEach(request.validationProblems, id: \.self) { problem in
                                Text(SkillsStrings.problem(problem)).foregroundStyle(preferences.palette.error)
                            }
                        }
                        if store.mutationUncertain { SkillMutationReview(store: store) }
                        else if let error = store.error { SkillErrorNotice(error: error) }
                    }
                } else {
                    Text(SkillsStrings.signIn)
                }
            }
            .navigationTitle(Text(skill == nil ? SkillsStrings.create : SkillsStrings.edit))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        retireSubmission()
                        dismiss()
                    } label: { Text(SkillsStrings.cancel) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        attemptedSave = true
                        let draft = request
                        guard draft.validationProblems.isEmpty, store.canMutate,
                              session.identityID == ownerID, let ticket = store.operationTicket() else { return }
                        let revision = draftRevision
                        let operation = UUID()
                        submissionID = operation
                        submissionTicket = ticket
                        submissionTask = Task {
                            let accepted = await store.save(draft, ticket: ticket)
                            guard submissionID == operation else { return }
                            submissionID = nil
                            submissionTask = nil
                            submissionTicket = nil
                            guard let accepted, !Task.isCancelled, isVisible,
                                  session.isAuthenticated, session.identityID == ticket.ownerID,
                                  session.identityGeneration == ticket.identityGeneration else { return }
                            // A newer edit stays open, but subsequent Save edits the
                            // actual accepted row instead of creating another skill.
                            committedID = accepted.id
                            guard revision == draftRevision else { return }
                            dismiss()
                        }
                    } label: {
                        if store.isWorking { ProgressView() } else { Text(SkillsStrings.save) }
                    }
                    .disabled(!store.canMutate || session.identityID != ownerID || submissionID != nil)
                }
            }
            .interactiveDismissDisabled(store.isWorking)
        }
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            retireSubmission()
        }
        .onChange(of: session.identityID) {
            guard session.identityID != ownerID else { return }
            retireSubmission()
            name = ""
            cues = ""
            rules = ""
            dismiss()
        }
        .onChange(of: session.identityGeneration) {
            retireSubmission()
            store.synchronizeOwner()
        }
        .tint(preferences.palette.accent)
        .presentationDragIndicator(.visible)
    }

    private func retireSubmission() {
        submissionTask?.cancel()
        submissionTask = nil
        submissionID = nil
        if let ticket = submissionTicket { store.invalidate(ticket: ticket) }
        submissionTicket = nil
    }

    private func revisedBinding<Value: Equatable>(_ field: Binding<Value>) -> Binding<Value> {
        Binding(get: { field.wrappedValue }, set: { value in
            guard field.wrappedValue != value else { return }
            // Count at the actual edit, including edit-and-back before SwiftUI
            // renders again; onChange can coalesce those updates.
            draftRevision &+= 1
            field.wrappedValue = value
        })
    }
}

/// An uncertain write is reviewed using GET only; the user's draft remains in
/// the editor until they deliberately acknowledge the account's saved list.
private struct SkillMutationReview: View {
    let store: AccountSkillsStore
    @Environment(SessionStore.self) private var session
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsNoticeBanner(message: Text(SkillsStrings.unconfirmed), kind: .error)
            Text(SkillsStrings.reviewHint)
                .font(.subheadline)
                .foregroundStyle(preferences.palette.textSecondary)
            Button {
                guard let ticket = store.operationTicket() else { return }
                Task { await store.load(ticket: ticket) }
            } label: { Text(SkillsStrings.review).frame(minHeight: 44) }
                .disabled(store.isWorking || session.isWorking)
            if store.ownSkillsLoaded, store.uncertaintyReviewed {
                Text(SkillsStrings.savedList).font(.headline)
                if store.skills.isEmpty { Text(SkillsStrings.empty) }
                ForEach(store.skills) { skill in
                    DisclosureGroup {
                        Text(verbatim: skill.cues.joined(separator: " · "))
                            .font(.caption)
                        Text(verbatim: skill.rules.joined(separator: "\n"))
                            .font(.subheadline)
                        Text(skill.mode == .always ? SkillsStrings.always : SkillsStrings.automatic)
                            .font(.caption)
                        HStack {
                            Text(SkillsStrings.enabled)
                            Image(systemName: skill.enabled ? "checkmark.circle" : "circle")
                                .accessibilityLabel(Text(skill.enabled ? SkillsStrings.enabled : SkillsStrings.disabled))
                        }
                    } label: { Text(verbatim: skill.name) }
                }
                Button {
                    guard let ticket = store.operationTicket() else { return }
                    store.acknowledgeUncertainMutation(ticket: ticket)
                } label: { Text(SkillsStrings.acknowledge).frame(minHeight: 44) }
                    .disabled(store.isWorking || session.isWorking)
            }
        }
    }
}

private struct SkillErrorNotice: View {
    let error: APIError
    var body: some View {
        if case .skillValidation(let problems) = error {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(Set(problems)).sorted(), id: \.self) { problem in
                    SettingsNoticeBanner(message: Text(SkillsStrings.problem(problem)), kind: .error)
                }
            }
        } else if case .httpStatus(_, let code) = error {
            SettingsNoticeBanner(message: Text(SkillsStrings.problem(code)), kind: .error)
        } else if case .invalidRequest(let code) = error {
            SettingsNoticeBanner(message: Text(SkillsStrings.problem(code)), kind: .error)
        } else {
            SettingsNoticeBanner(message: Text(SkillsStrings.problem("unavailable")), kind: .error)
        }
    }
}
