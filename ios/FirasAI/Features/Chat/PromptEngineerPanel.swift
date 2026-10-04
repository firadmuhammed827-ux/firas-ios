import SwiftUI

enum PromptEngineerStrings {
    static let title = LocalizedStringResource("title", table: "PromptEngineer")
    static let arabic = LocalizedStringResource("arabic", table: "PromptEngineer")
    static let english = LocalizedStringResource("english", table: "PromptEngineer")
    static let choose = LocalizedStringResource("choose", table: "PromptEngineer")
    static let stop = LocalizedStringResource("stop", table: "PromptEngineer")
    static let apply = LocalizedStringResource("apply", table: "PromptEngineer")
    static let replaceHint = LocalizedStringResource("replaceHint", table: "PromptEngineer")
    static let partial = LocalizedStringResource("partial", table: "PromptEngineer")
    static let done = LocalizedStringResource("done", table: "PromptEngineer")
    static let reconnect = LocalizedStringResource("reconnect", table: "PromptEngineer")
    static let background = LocalizedStringResource("background", table: "PromptEngineer")
    static let applied = LocalizedStringResource("applied", table: "PromptEngineer")
    static let forget = LocalizedStringResource("forget", table: "PromptEngineer")
    static let forgetHint = LocalizedStringResource("forgetHint", table: "PromptEngineer")

    static func phase(_ phase: PromptEngineerPhase?) -> LocalizedStringResource {
        switch phase ?? .uncertain {
        case .preparing: LocalizedStringResource("preparing", table: "PromptEngineer")
        case .queued: LocalizedStringResource("queued", table: "PromptEngineer")
        case .processing: LocalizedStringResource("processing", table: "PromptEngineer")
        case .uncertain: LocalizedStringResource("uncertain", table: "PromptEngineer")
        case .stopping: LocalizedStringResource("stopping", table: "PromptEngineer")
        case .completed: LocalizedStringResource("completed", table: "PromptEngineer")
        case .failed: LocalizedStringResource("failed", table: "PromptEngineer")
        case .stopped: LocalizedStringResource("stopped", table: "PromptEngineer")
        }
    }

    static func problem(_ code: String) -> LocalizedStringResource {
        switch code {
        case "input_invalid": LocalizedStringResource("input_invalid", table: "PromptEngineer")
        case "storage_unavailable": LocalizedStringResource("storage_unavailable", table: "PromptEngineer")
        case "output_too_large": LocalizedStringResource("output_too_large", table: "PromptEngineer")
        case "stop_unconfirmed": LocalizedStringResource("stop_unconfirmed", table: "PromptEngineer")
        case "generation_failed", "admission_rejected": LocalizedStringResource("generation_failed", table: "PromptEngineer")
        case "stopped": LocalizedStringResource("stopped", table: "PromptEngineer")
        default: LocalizedStringResource("receipt_unavailable", table: "PromptEngineer")
        }
    }
}

/// The chooser lives in the actual composer action slot only for the command.
struct PromptEngineerLanguageActions: View {
    let isEnabled: Bool
    let onChoose: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button { onChoose("ar") } label: { Text(PromptEngineerStrings.arabic).font(.subheadline.weight(.semibold)).padding(.horizontal, 10).frame(minHeight: 44) }
                .modifier(FirasGlassControlStyle(prominent: true))
            Button { onChoose("en") } label: { Text(PromptEngineerStrings.english).font(.subheadline.weight(.semibold)).padding(.horizontal, 10).frame(minHeight: 44) }
                .modifier(FirasGlassControlStyle())
        }
        .disabled(!isEnabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(PromptEngineerStrings.choose))
    }
}

struct PromptEngineerStatusControl: View {
    let onOpen: () -> Void
    @Environment(PromptEngineerStore.self) private var store
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 9) {
                Image(systemName: "wand.and.stars").accessibilityHidden(true)
                Text(PromptEngineerStrings.title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                Text(PromptEngineerStrings.phase(store.phase)).font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.up").font(.caption2.weight(.bold)).accessibilityHidden(true)
            }
            .foregroundStyle(preferences.palette.textPrimary)
            .padding(.horizontal, 14).frame(minHeight: 44)
        }
        .modifier(FirasGlassControlStyle())
    }
}

struct PromptEngineerPanel: View {
    @Environment(PromptEngineerStore.self) private var store
    @Environment(ChatStore.self) private var chatStore
    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    @State private var observationLease: UUID?

    var body: some View {
        NavigationStack {
            ZStack {
                FirasBackground()
                if store.isCurrentOwner { ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Label { Text(PromptEngineerStrings.phase(store.phase)) } icon: {
                            Image(systemName: store.phase == .completed ? "checkmark.circle" : "wand.and.stars")
                        }
                        .font(.headline)
                        Text(PromptEngineerStrings.background).font(.subheadline).foregroundStyle(.secondary)
                        if let problem = store.problem {
                            Text(PromptEngineerStrings.problem(problem)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if store.phase == .failed || store.phase == .stopped, !store.text.isEmpty {
                            Text(PromptEngineerStrings.partial).font(.subheadline.weight(.semibold))
                        }
                        if !store.text.isEmpty {
                            Text(verbatim: store.text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        } else if store.isObserving {
                            ProgressView().frame(maxWidth: .infinity).accessibilityLabel(Text(PromptEngineerStrings.phase(store.phase)))
                        }
                        if store.automaticallyApplied {
                            Label { Text(PromptEngineerStrings.applied) } icon: { Image(systemName: "checkmark") }
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(20).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                } } else { ProgressView() }
            }
            .navigationTitle(Text(PromptEngineerStrings.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Text(PromptEngineerStrings.done) } }
            }
            .safeAreaInset(edge: .bottom) {
                FirasGlassControlGroup(spacing: 10) {
                    VStack(spacing: 8) {
                        if store.canApply {
                            Text(PromptEngineerStrings.replaceHint).font(.caption).foregroundStyle(.secondary)
                            Button {
                                guard let snapshot = chatStore.snapshotDraft() else { return }
                                _ = store.apply(snapshot: snapshot)
                            } label: { Text(PromptEngineerStrings.apply).frame(maxWidth: .infinity, minHeight: 48) }
                                .modifier(FirasGlassControlStyle(prominent: true))
                        }
                        if store.blocksNewHelper, let saved = store.pointer, let owner = store.ownerID {
                            HStack(spacing: 10) {
                                Button { store.resumeIfNeeded() } label: { Text(PromptEngineerStrings.reconnect).frame(maxWidth: .infinity, minHeight: 44) }
                                    .modifier(FirasGlassControlStyle()).disabled(store.isObserving)
                                Button {
                                    store.stop(cid: saved.cid, expectedOwnerID: owner, expectedIdentityGeneration: store.identityGeneration)
                                } label: { Label { Text(PromptEngineerStrings.stop) } icon: { Image(systemName: "stop.fill") }.frame(maxWidth: .infinity, minHeight: 44) }
                                    .modifier(FirasGlassControlStyle())
                            }
                            if store.canForgetUnavailableReceipt {
                                Text(PromptEngineerStrings.forgetHint).font(.caption).foregroundStyle(.secondary)
                                Button {
                                    store.forgetUnavailableReceipt(cid: saved.cid, expectedOwnerID: owner,
                                        expectedIdentityGeneration: store.identityGeneration)
                                } label: { Text(PromptEngineerStrings.forget).frame(maxWidth: .infinity, minHeight: 44) }
                                    .modifier(FirasGlassControlStyle()).disabled(store.isObserving)
                            }
                        }
                    }
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .environment(\.layoutDirection, preferences.language.layoutDirection)
        .onAppear { if observationLease == nil { observationLease = store.acquireObservation() } }
        .onDisappear {
            if let observationLease { store.releaseObservation(observationLease) }
            observationLease = nil
        }
    }
}
