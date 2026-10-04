import AVKit
import Combine
import CoreTransferable
import Foundation
import ImageIO
import PhotosUI
import UniformTypeIdentifiers
import SwiftUI
import UIKit

struct MediaStudioScreen: View {
    let store: MediaStudioStore
    let focusedJobID: String?
    let onOpenProfile: () -> Void

    @Environment(PreferencesStore.self) private var preferences
    @Environment(SessionStore.self) private var session
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @State private var selectedKind: MediaStudioKind = .image
    @State private var prompt = ""
    @State private var lyrics = ""
    @State private var aspect: ImageAspectPreset = .square
    @State private var videoSeconds = 10
    @State private var musicSeconds = 90
    @State private var kindFeedback = 0
    @State private var bindingOperationID: UUID?
    @State private var creationTask: Task<Void, Never>?
    @State private var sourceDraft = MediaSourceDraftState()
    @State private var sourcePickerTicket: MediaSourceImportTicket?
    @State private var showsSourcePicker = false
    @State private var sourceTask: Task<Void, Never>?
    @State private var sourceError: LocalizedStringResource?
    @State private var playbackLease = MediaPlaybackLease()

    /// Presented from Chat. Merely opening Studio does not create a turn or job.
    init(store: MediaStudioStore, initialKind: MediaStudioKind = .image,
         focusedJobID: String? = nil, onOpenProfile: @escaping () -> Void) {
        self.store = store
        self.focusedJobID = focusedJobID
        _selectedKind = State(initialValue: initialKind)
        self.onOpenProfile = onOpenProfile
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FirasBackground()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            MediaHeroCard()
                            kindPicker
                            creationCard
                            if store.isLoading {
                                Label(MediaStrings.preparingResult, systemImage: "arrow.down.circle")
                                    .font(.subheadline).foregroundStyle(preferences.palette.textSecondary)
                                    .frame(minHeight: 64)
                            }
                            if !ownedCreations.isEmpty { creationsSection }
                        }
                        .frame(maxWidth: min(900, preferences.contentWidth.maxWidth))
                        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 40)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .task(id: focusedJobID) { await scrollToFocusedCreation(using: proxy) }
                }
                .environment(\.layoutDirection, preferences.language.layoutDirection)
            }
            .navigationTitle(Text(MediaStrings.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { toolbarContent }
            .overlay(alignment: .top) { messageOverlay }
        }
        // iPhone header keeps Close on the left and Profile on the right.
        .environment(\.layoutDirection, .leftToRight)
        .background {
            if let ticket = sourcePickerTicket {
                MediaSourcePickerHost(ticket: ticket, isPresented: $showsSourcePicker,
                    selected: importSource, dismissed: finishSourcePicker)
                    .id(ticket.id)
            }
        }
        .task(id: session.identityGeneration) {
            bindDraftOwner()
            store.resumeIfNeeded()
        }
        .onChange(of: session.identityGeneration) { _, _ in
            cancelPreparation()
            cancelSourceImport()
            playbackLease.releaseAll()
            showsSourcePicker = false
            bindDraftOwner()
            store.synchronizeOwner()
        }
        .onDisappear {
            // These tasks prepare the draft only. Accepted jobs belong to Store.
            cancelPreparation()
            // The system photo presentation may temporarily hide its parent.
            if !showsSourcePicker { cancelSourceImport() }
            playbackLease.releaseAll()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.resumeIfNeeded() } else { playbackLease.releaseAll() }
        }
        .onChange(of: session.isWorking) { _, working in if !working { store.resumeIfNeeded() } }
        .transaction { if reduceMotion || !preferences.motionEnabled { $0.animation = nil; $0.disablesAnimations = true } }
        .sensoryFeedback(.selection, trigger: kindFeedback)
    }

    private var ownsDraft: Bool {
        sourceDraft.matches(ownerID: session.identityID, identityGeneration: session.identityGeneration)
    }

    private var editable: Bool { ownsDraft && session.isAuthenticated && !session.isWorking }

    private var ownedCreations: [MediaCreation] {
        guard editable, store.loadedOwnerID == session.identityID else { return [] }
        return store.creations.filter { $0.ownerID == session.identityID }
    }

    private var kindPicker: some View {
        MediaKindPicker(selection: Binding(get: { selectedKind }, set: { kind in
            guard kind != selectedKind else { return }
            reviseDraft()
            selectedKind = kind
            if kind == .music { sourceDraft.removeSource() }
        })) { kindFeedback &+= 1 }
    }

    private var promptBinding: Binding<String> {
        Binding(get: { ownsDraft ? prompt : "" }, set: { value in
            guard editable else { return }; reviseDraft(); prompt = value
        })
    }

    private var lyricsBinding: Binding<String> {
        Binding(get: { ownsDraft ? lyrics : "" }, set: { value in
            guard editable else { return }; reviseDraft(); lyrics = value
        })
    }

    private var creationCard: some View {
        GlassSurface(cornerRadius: 26, tintStrength: 0.055) {
            VStack(alignment: .leading, spacing: 15) {
                Label(MediaStrings.prompt, systemImage: promptIcon).font(.headline)
                    .foregroundStyle(preferences.palette.textPrimary)
                TextField(text: promptBinding, prompt: Text(promptPlaceholder), axis: .vertical) { Text(promptPlaceholder) }
                    .font(.body).foregroundStyle(preferences.palette.textPrimary)
                    .lineLimit(4...9).padding(14)
                    .background(preferences.palette.surfaceSunken.opacity(0.72), in: .rect(cornerRadius: 17))
                    .accessibilityLabel(Text(MediaStrings.prompt)).disabled(!editable)
                characterBudget(count: ownsDraft ? prompt.utf16.count : 0, limit: MediaRequestPolicy.promptLimit(selectedKind))

                switch selectedKind {
                case .image: aspectPicker
                case .video: durationPicker(values: [5, 10, 15, 30], selection: durationBinding(video: true))
                case .music: musicFields
                }
                if selectedKind != .music { sourceControls }
                if let sourceError { Text(sourceError).font(.caption).foregroundStyle(preferences.palette.error) }
                if store.isUnconfirmedSubmission {
                    Label(MediaStrings.unconfirmed, systemImage: "clock.badge.exclamationmark")
                        .font(.caption).foregroundStyle(preferences.palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(MediaStrings.runningCloud).font(.caption)
                    .foregroundStyle(preferences.palette.textSecondary).fixedSize(horizontal: false, vertical: true)

                FirasGlassControlGroup {
                    if session.isAuthenticated {
                        Button(action: create) {
                            Label(bindingOperationID == nil ? MediaStrings.create : MediaStrings.preparingSubmission, systemImage: "sparkles")
                                .font(.headline).frame(maxWidth: .infinity).frame(minHeight: 50)
                        }
                        .modifier(FirasGlassControlStyle(prominent: true)).disabled(!canCreate)
                        if bindingOperationID != nil, !store.isCreating {
                            Button(action: cancelPreparation) {
                                Label(MediaStrings.cancelPreparation, systemImage: "xmark").frame(minHeight: 44)
                            }.modifier(FirasGlassControlStyle())
                        }
                    } else {
                        Button(action: onOpenProfile) {
                            Label(MediaStrings.signIn, systemImage: "person.crop.circle.badge.checkmark")
                                .font(.headline).frame(maxWidth: .infinity).frame(minHeight: 50)
                        }.modifier(FirasGlassControlStyle(prominent: true))
                    }
                }
            }.padding(17)
        }
    }

    private func characterBudget(count: Int, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "\(count) / \(limit)").font(.caption.monospacedDigit())
                .environment(\.layoutDirection, .leftToRight)
            if count > limit { Text(MediaStrings.briefTooLong).font(.caption) }
        }
        .foregroundStyle(count > limit ? preferences.palette.error : preferences.palette.textMuted)
        .accessibilityElement(children: .combine)
    }

    private var sourceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(selectedKind == .image ? MediaStrings.imageSourceDetail : MediaStrings.videoSourceDetail)
                .font(.caption).foregroundStyle(preferences.palette.textSecondary)
            if let source = sourceDraft.source, ownsDraft {
                HStack(spacing: 10) {
                    MediaSourceThumbnail(source: source)
                    Text(MediaStrings.sourceImage).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    Button { reviseDraft(); sourceDraft.removeSource() } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }.modifier(FirasGlassControlStyle(circular: true))
                        .accessibilityLabel(Text(MediaStrings.removeSource)).disabled(!editable || bindingOperationID != nil)
                }
            }
            FirasGlassControlGroup {
                if sourceDraft.pending != nil {
                    HStack(spacing: 8) {
                        Label(MediaStrings.readingSource, systemImage: "photo.badge.arrow.down")
                            .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                        Button(action: cancelSourceImport) {
                            Image(systemName: "xmark").frame(width: 44, height: 44)
                        }.modifier(FirasGlassControlStyle(circular: true)).accessibilityLabel(Text(MediaStrings.cancelPreparation))
                    }
                } else {
                    Button(action: beginSourceSelection) {
                        Label(sourceDraft.source == nil ? MediaStrings.addSource : MediaStrings.replaceSource, systemImage: "photo.on.rectangle")
                            .font(.subheadline.weight(.semibold)).frame(minHeight: 44).padding(.horizontal, 12)
                    }.modifier(FirasGlassControlStyle()).disabled(!editable || bindingOperationID != nil || store.isCreating)
                }
            }
        }.foregroundStyle(preferences.palette.textPrimary)
    }

    private var aspectPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(MediaStrings.aspect).font(.subheadline.weight(.semibold)).foregroundStyle(preferences.palette.textSecondary)
            ScrollView(.horizontal) {
                FirasGlassControlGroup(spacing: 9) {
                    HStack(spacing: 9) {
                        ForEach(ImageAspectPreset.allCases) { preset in
                            AspectPresetButton(preset: preset, selected: aspect == preset) {
                                guard aspect != preset else { return }; reviseDraft(); aspect = preset
                            }
                        }
                    }.padding(.vertical, 2)
                }
            }.scrollIndicators(.hidden).disabled(!editable)
        }
    }

    private var musicFields: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(MediaStrings.lyrics).font(.subheadline.weight(.semibold)).foregroundStyle(preferences.palette.textSecondary)
            TextField(text: lyricsBinding, prompt: Text(MediaStrings.lyricsOptional), axis: .vertical) { Text(MediaStrings.lyricsOptional) }
                .font(.body).foregroundStyle(preferences.palette.textPrimary).lineLimit(3...8).padding(13)
                .background(preferences.palette.surfaceSunken.opacity(0.72), in: .rect(cornerRadius: 16))
                .accessibilityLabel(Text(MediaStrings.lyrics)).disabled(!editable)
            characterBudget(count: ownsDraft ? lyrics.utf16.count : 0, limit: 6_000)
            durationPicker(values: [30, 60, 90, 180], selection: durationBinding(video: false))
        }
    }

    private func durationBinding(video: Bool) -> Binding<Int> {
        Binding(get: { video ? videoSeconds : musicSeconds }, set: { value in
            reviseDraft(); if video { videoSeconds = value } else { musicSeconds = value }
        })
    }

    private func durationPicker(values: [Int], selection: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(MediaStrings.duration).font(.subheadline.weight(.semibold)).foregroundStyle(preferences.palette.textSecondary)
            FirasGlassControlGroup {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { durationButtons(values: values, selection: selection) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], spacing: 8) {
                        durationButtons(values: values, selection: selection)
                    }
                }
            }.disabled(!editable)
        }
    }

    @ViewBuilder private func durationButtons(values: [Int], selection: Binding<Int>) -> some View {
        ForEach(values, id: \.self) { value in
            Button { if selection.wrappedValue != value { selection.wrappedValue = value } } label: {
                Text(durationLabel(value)).font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).frame(minHeight: 44).padding(.horizontal, 8)
            }
            .modifier(FirasGlassControlStyle(prominent: selection.wrappedValue == value))
            .accessibilityAddTraits(selection.wrappedValue == value ? .isSelected : [])
        }
    }

    private var creationsSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(MediaStrings.recent, systemImage: "square.stack.3d.up").font(.headline)
                .foregroundStyle(preferences.palette.textPrimary).padding(.horizontal, 4)
            ForEach(ownedCreations) { creation in
                MediaCreationCard(creation: creation,
                    isLoadingAsset: store.loadingAssetIDs.contains(creation.id),
                    localAssetURL: store.localAssetURL(for: creation),
                    playbackLease: playbackLease,
                    stop: { store.stop(creation, language: preferences.language) },
                    load: { store.loadAsset(creation, language: preferences.language) },
                    save: { store.saveToPhotos(creation, language: preferences.language) },
                    remove: { store.remove(creation) })
                .id(creation.id)
            }
        }
        // Retire local players/dialogs even when the same account signs in again.
        .id(store.ownerGeneration)
    }

    @ViewBuilder private var messageOverlay: some View {
        if ownsDraft, let error = store.errorMessage, !error.isEmpty {
            MediaMessageBanner(message: error, isError: true, dismiss: store.clearMessages).padding(.horizontal, 14).padding(.top, 8)
        } else if ownsDraft, let confirmation = store.confirmationMessage, !confirmation.isEmpty {
            MediaMessageBanner(message: confirmation, isError: false, dismiss: store.clearMessages).padding(.horizontal, 14).padding(.top, 8)
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: closeStudio) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                .accessibilityLabel(Text(MediaStrings.dismiss))
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(MediaStrings.title).font(.headline)
                Text(MediaStrings.subtitle).font(.caption2).foregroundStyle(preferences.palette.textMuted)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: onOpenProfile) { Image(systemName: "person.crop.circle").frame(width: 44, height: 44) }
                .accessibilityLabel(Text(MediaStrings.account))
        }
    }

    private var promptPlaceholder: LocalizedStringResource {
        switch selectedKind { case .image: MediaStrings.imagePrompt; case .video: MediaStrings.videoPrompt; case .music: MediaStrings.musicPrompt }
    }
    private var promptIcon: String {
        switch selectedKind { case .image: "photo.artframe"; case .video: "video"; case .music: "waveform" }
    }
    private var canCreate: Bool {
        guard editable, store.canCreate, !store.isLoading, bindingOperationID == nil, sourceDraft.pending == nil, !showsSourcePicker else { return false }
        // Source bytes are validated once off Main during import, never in body.
        return MediaRequestPolicy.validationProblem(kind: selectedKind, prompt: prompt,
            lyrics: selectedKind == .music ? lyrics : "", seconds: selectedKind == .video ? videoSeconds : musicSeconds) == nil
    }

    private func bindDraftOwner() {
        let owner = session.isAuthenticated ? session.identityID : nil
        if sourceDraft.bind(ownerID: owner, identityGeneration: session.identityGeneration) {
            prompt = ""; lyrics = ""; sourceError = nil
        }
    }

    private func reviseDraft() {
        sourceTask?.cancel(); sourceTask = nil; sourceDraft.revise(); sourceError = nil
    }

    private func beginSourceSelection() {
        guard editable, bindingOperationID == nil, !store.isCreating, selectedKind != .music,
              let owner = session.identityID else { return }
        guard sourcePickerTicket == nil else { return }
        sourceError = nil
        sourceDraft.begin(ownerID: owner, identityGeneration: session.identityGeneration, kind: selectedKind)
        sourcePickerTicket = sourceDraft.pending
        showsSourcePicker = sourceDraft.pending != nil
    }

    private func cancelSourceImport() {
        sourceTask?.cancel(); sourceTask = nil; sourceDraft.retireImport()
    }

    private func finishSourcePicker(_ ticket: MediaSourceImportTicket, _ hasSelection: Bool) {
        guard sourcePickerTicket?.id == ticket.id else { return }
        sourcePickerTicket = nil
        if !hasSelection, sourceDraft.pending?.id == ticket.id { cancelSourceImport() }
    }

    private func importSource(_ item: PhotosPickerItem, _ ticket: MediaSourceImportTicket) {
        guard acceptsSource(ticket) else { return }
        sourceTask?.cancel()
        sourceTask = Task {
            defer {
                if sourceDraft.pending?.id == ticket.id { sourceDraft.retireImport(); sourceTask = nil }
            }
            do {
                let data: Data
                switch ticket.kind {
                case .image:
                    guard let photo = try await item.loadTransferable(type: MediaPickedImageFile.self) else { throw ChatAttachmentError.unreadableImage }
                    data = photo.data
                case .video:
                    guard let photo = try await item.loadTransferable(type: MediaPickedVideoSourceFile.self) else { throw ChatAttachmentError.unreadableImage }
                    data = photo.data
                case .music: return
                }
                guard acceptsSource(ticket), !Task.isCancelled else { return }
                guard data.count <= (ticket.kind == .image ? 20_000_000 : 10_000_000) else {
                    sourceError = MediaStrings.sourceTooLarge; return
                }
                let draft = try await ChatAttachmentProcessor.draftImage(data: data, sourceID: ticket.id.uuidString)
                let prepared = try await ChatAttachmentProcessor.prepare(images: [draft], files: [])
                guard acceptsSource(ticket), !Task.isCancelled, let full = prepared.fullImages.first else { return }
                let dataURI = "data:image/jpeg;base64," + full
                // Decode/inspect the bounded source once outside the presentation actor.
                let validation = Task.detached(priority: .userInitiated) {
                    MediaRequestPolicy.validationProblem(kind: ticket.kind, prompt: "source", seconds: 10, sourceImage: dataURI)
                }
                let problem = await validation.value
                guard acceptsSource(ticket), !Task.isCancelled else { return }
                guard problem == nil, let thumbnailURI = prepared.imageThumbnails.first,
                      let comma = thumbnailURI.firstIndex(of: ","),
                      let thumbnail = Data(base64Encoded: String(thumbnailURI[thumbnailURI.index(after: comma)...])) else {
                    sourceError = MediaStrings.sourceUnreadable; return
                }
                if sourceDraft.accept(ticket, kind: selectedKind,
                    asset: MediaSourceImage(id: draft.id, dataURI: dataURI, thumbnailData: thumbnail)) {
                    sourceTask = nil
                }
            } catch MediaSourceFileError.tooLarge {
                if !Task.isCancelled, acceptsSource(ticket) { sourceError = MediaStrings.sourceTooLarge }
            } catch MediaSourceFileError.dimensionsTooLarge {
                if !Task.isCancelled, acceptsSource(ticket) { sourceError = MediaStrings.sourceDimensionsTooLarge }
            } catch {
                if !Task.isCancelled, acceptsSource(ticket) { sourceError = MediaStrings.sourceUnreadable }
            }
        }
    }

    private func acceptsSource(_ ticket: MediaSourceImportTicket) -> Bool {
        editable && sourceDraft.accepts(ticket, kind: selectedKind) &&
            session.identityID == ticket.ownerID && session.identityGeneration == ticket.identityGeneration
    }

    private func cancelPreparation() {
        creationTask?.cancel(); creationTask = nil; bindingOperationID = nil
    }

    private func closeStudio() {
        cancelPreparation()
        cancelSourceImport()
        sourcePickerTicket = nil
        showsSourcePicker = false
        playbackLease.releaseAll()
        dismiss()
    }

    private func create() {
        guard canCreate else { return }
        store.synchronizeOwner()
        guard canCreate, let ownerID = session.identityID else { return }
        let ownerGeneration = store.ownerGeneration
        let identityGeneration = session.identityGeneration
        let revision = sourceDraft.revision
        let source = selectedKind == .music ? nil : sourceDraft.source
        let kind = selectedKind, submittedPrompt = prompt, submittedLyrics = lyrics
        let submittedAspect = aspect, seconds = kind == .video ? videoSeconds : musicSeconds
        let tier = preferences.tier, modelGeneration = preferences.modelGeneration, language = preferences.language
        let operationID = UUID()
        bindingOperationID = operationID
        creationTask = Task {
            defer { if bindingOperationID == operationID { bindingOperationID = nil; creationTask = nil } }
            guard ownsCreation(operationID, ownerID, ownerGeneration, identityGeneration) else { return }
            let turnPrompt = kind == .music && !submittedLyrics.isEmpty ? submittedPrompt + "\n\n" + submittedLyrics : submittedPrompt
            guard let binding = await chatStore.prepareMediaTurn(
                prompt: turnPrompt, sourceImage: source?.dataURI, tier: tier, modelGeneration: modelGeneration,
                language: language, expectedOwnerID: ownerID, expectedIdentityGeneration: identityGeneration
            ) else {
                if ownsCreation(operationID, ownerID, ownerGeneration, identityGeneration) { store.errorMessage = chatStore.errorMessage }
                return
            }
            guard ownsCreation(operationID, ownerID, ownerGeneration, identityGeneration) else { return }
            let accepted: Bool
            switch kind {
            case .image:
                accepted = await store.createImage(prompt: submittedPrompt, preset: submittedAspect, sourceImage: source?.dataURI,
                    language: language, binding: binding, tier: tier, expectedOwnerID: ownerID,
                    expectedOwnerGeneration: ownerGeneration, expectedIdentityGeneration: identityGeneration)
            case .video:
                accepted = await store.createVideo(prompt: submittedPrompt, seconds: seconds, sourceImage: source?.dataURI,
                    language: language, binding: binding, tier: tier, expectedOwnerID: ownerID,
                    expectedOwnerGeneration: ownerGeneration, expectedIdentityGeneration: identityGeneration)
            case .music:
                accepted = await store.createMusic(prompt: submittedPrompt, lyrics: submittedLyrics, seconds: seconds,
                    language: language, binding: binding, tier: tier, expectedOwnerID: ownerID,
                    expectedOwnerGeneration: ownerGeneration, expectedIdentityGeneration: identityGeneration)
            }
            if accepted, ownsCreation(operationID, ownerID, ownerGeneration, identityGeneration),
               sourceDraft.consumeAccepted(ownerID: ownerID, identityGeneration: identityGeneration,
                   revision: revision, sourceID: source?.id) {
                prompt = ""; lyrics = ""
            }
        }
    }

    private func ownsCreation(_ operation: UUID, _ owner: String, _ storeEpoch: Int, _ identityEpoch: Int) -> Bool {
        !Task.isCancelled && bindingOperationID == operation && session.isAuthenticated && !session.isWorking &&
            session.identityID == owner && session.identityGeneration == identityEpoch && store.ownerGeneration == storeEpoch
    }

    private func durationLabel(_ seconds: Int) -> String {
        if seconds < 60 { return preferences.language == .arabic ? "\(seconds) ث" : "\(seconds)s" }
        let minutes = seconds / 60, remainder = seconds % 60
        if remainder == 0 { return preferences.language == .arabic ? "\(minutes) د" : "\(minutes)m" }
        return preferences.language == .arabic ? "\(minutes):\(String(format: "%02d", remainder)) د" : "\(minutes):\(String(format: "%02d", remainder))"
    }

    private func scrollToFocusedCreation(using proxy: ScrollViewProxy) async {
        guard let focusedJobID, !focusedJobID.isEmpty else { return }
        for _ in 0..<16 {
            if let creation = ownedCreations.first(where: { $0.jobID == focusedJobID }) {
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion || !preferences.motionEnabled ? nil : .snappy(duration: 0.4)) { proxy.scrollTo(creation.id, anchor: .top) }
                return
            }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        }
    }
}

/// The immutable presentation ticket stays with the actual system picker.
/// A late callback from a retired presentation cannot use a newer ticket.
private struct MediaSourcePickerHost: View {
    let ticket: MediaSourceImportTicket
    @Binding var isPresented: Bool
    let selected: (PhotosPickerItem, MediaSourceImportTicket) -> Void
    let dismissed: (MediaSourceImportTicket, Bool) -> Void
    @State private var item: PhotosPickerItem?

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .photosPicker(isPresented: $isPresented, selection: $item, matching: .images, preferredItemEncoding: .automatic)
            .onChange(of: item) { _, value in if let value { selected(value, ticket) } }
            .onChange(of: isPresented) { _, presented in if !presented { dismissed(ticket, item != nil) } }
    }
}

private struct MediaSourceThumbnail: View {
    let source: MediaSourceImage
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").resizable().scaledToFit().padding(10) }
        }
        .frame(width: 48, height: 48).clipShape(.rect(cornerRadius: 10)).accessibilityHidden(true)
        .task(id: source.id) { image = UIImage(data: source.thumbnailData) }
    }
}

private nonisolated struct MediaPickedImageFile: Transferable, Sendable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image, shouldAttemptToOpenInPlace: false) { received in
            Self(data: try await MediaLocalFileLoader.shared.sourceData(at: received.file, maximumBytes: 20_000_000))
        }
    }
}

private nonisolated struct MediaPickedVideoSourceFile: Transferable, Sendable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image, shouldAttemptToOpenInPlace: false) { received in
            Self(data: try await MediaLocalFileLoader.shared.sourceData(at: received.file, maximumBytes: 10_000_000))
        }
    }
}

/// The lease is local to this Studio presentation. Preparing a preview does not
/// activate audio; only the person's actual playback request may claim it.
@MainActor
private final class MediaPlaybackLease {
    private var current: AVPlayer?

    func claim(_ player: AVPlayer, kind: MediaStudioKind) -> Bool {
        if current === player { return true }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: kind == .video ? .moviePlayback : .default)
            try audio.setActive(true)
        } catch {
            player.pause()
            return false
        }
        current?.pause()
        current = player
        return true
    }

    func release(_ player: AVPlayer) {
        guard current === player else { return }
        player.pause()
        current = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func releaseAll() {
        if let current { release(current) }
    }
}

private struct MediaHeroCard: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        GlassSurface(cornerRadius: 26, tintStrength: 0.065) {
            HStack(spacing: 15) {
                ZStack {
                    Circle()
                        .fill(preferences.palette.accent.opacity(0.13))
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(preferences.palette.accent)
                }
                .frame(width: 58, height: 58)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(MediaStrings.hero)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(preferences.palette.textPrimary)
                    Text(MediaStrings.heroDetail)
                        .font(.subheadline)
                        .foregroundStyle(preferences.palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(17)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MediaKindPicker: View {
    @Binding var selection: MediaStudioKind
    let didSelect: () -> Void

    @Environment(PreferencesStore.self) private var preferences
    var body: some View {
        FirasGlassControlGroup(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(spacing: 8) { buttons }
            }
        }
    }

    private var buttons: some View {
        ForEach(MediaStudioKind.allCases) { kind in
            Button {
                guard kind != selection else { return }
                selection = kind
                didSelect()
            } label: {
                Label(title(kind), systemImage: systemImage(kind))
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 10).frame(maxWidth: .infinity).frame(minHeight: 46)
            }
            .modifier(FirasGlassControlStyle(prominent: selection == kind))
            .accessibilityAddTraits(selection == kind ? .isSelected : [])
        }
    }

    private func title(_ kind: MediaStudioKind) -> LocalizedStringResource {
        switch kind {
        case .image: MediaStrings.image
        case .video: MediaStrings.video
        case .music: MediaStrings.music
        }
    }

    private func systemImage(_ kind: MediaStudioKind) -> String {
        switch kind {
        case .image: "photo"
        case .video: "video"
        case .music: "waveform"
        }
    }
}

private struct AspectPresetButton: View {
    let preset: ImageAspectPreset
    let selected: Bool
    let action: () -> Void

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(selected ? preferences.palette.onAccent.opacity(0.24) : .clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(
                                selected ? preferences.palette.onAccent : preferences.palette.textMuted,
                                lineWidth: selected ? 2 : 1
                            )
                    }
                    .aspectRatio(CGFloat(preset.ratio), contentMode: .fit)
                    .frame(width: 34, height: 30)

                Text(MediaStrings.aspect(preset))
                    .font(.caption2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 74).frame(minHeight: 70).padding(.vertical, 8)
        }
        .modifier(FirasGlassControlStyle(prominent: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct MediaCreationCard: View {
    let creation: MediaCreation
    let isLoadingAsset: Bool
    let localAssetURL: URL?
    let playbackLease: MediaPlaybackLease
    let stop: () -> Void
    let load: () -> Void
    let save: () -> Void
    let remove: () -> Void

    @Environment(PreferencesStore.self) private var preferences
    @State private var showsRemoveConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header

            if creation.phase.isActive {
                activeContent
            } else if creation.phase == .stopped {
                Label(MediaStrings.stopped, systemImage: "stop.circle")
                    .font(.subheadline).foregroundStyle(preferences.palette.textSecondary)
            } else if creation.phase == .failed {
                failedContent
            } else if let url = localAssetURL {
                resultContent(url)
                resultActions(url)
            } else {
                unloadedResult
            }
        }
        .padding(16)
        .background(preferences.palette.surface.opacity(0.65), in: .rect(cornerRadius: 25))
        .overlay { RoundedRectangle(cornerRadius: 25).stroke(preferences.palette.border) }
        .confirmationDialog(Text(MediaStrings.removeConfirm), isPresented: $showsRemoveConfirmation, titleVisibility: .visible) {
            Button(role: .destructive, action: remove) { Text(MediaStrings.remove) }
            Button(role: .cancel, action: {}) { Text(MediaStrings.cancel) }
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: kindIcon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(preferences.palette.accent)
                .frame(width: 38, height: 38)
                .background(preferences.palette.accent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: creation.prompt.isEmpty ? fallbackTitle : creation.prompt)
                    .font(.headline)
                    .foregroundStyle(preferences.palette.textPrimary)
                    .lineLimit(3)
                Text(creation.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(preferences.palette.textMuted)
                if creation.sourceWasProvided == true {
                    Text(MediaStrings.sourceUsed).font(.caption).foregroundStyle(preferences.palette.textSecondary)
                }
            }
            Spacer(minLength: 4)
            if !creation.phase.isActive {
                Menu {
                    Button(role: .destructive) { showsRemoveConfirmation = true } label: {
                        Label(MediaStrings.remove, systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text(MediaStrings.remove))
            }
        }
    }

    private var activeContent: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(creation.phase == .stopping ? MediaStrings.stopping : MediaStrings.creating,
                  systemImage: creation.phase == .stopping ? "stop.circle" : "wand.and.stars")
                .font(.subheadline.weight(.semibold)).foregroundStyle(preferences.palette.textSecondary)
            if creation.startAttempted == true, creation.jobID == nil || creation.errorCode == "media_receipt_mismatch" {
                Text(MediaStrings.unconfirmed).font(.caption).foregroundStyle(preferences.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if creation.phase != .stopping {
                HStack(spacing: 9) {
                    Image(systemName: "cloud")
                        .foregroundStyle(preferences.palette.accent)
                        .accessibilityHidden(true)
                    Text(MediaStrings.runningCloud)
                        .font(.caption)
                        .foregroundStyle(preferences.palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            FirasGlassControlGroup {
                Button(action: stop) {
                    Label(MediaStrings.stop, systemImage: "stop.fill")
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 44).padding(.horizontal, 12)
                }
                .modifier(FirasGlassControlStyle())
                .disabled(creation.stopRequested == true || creation.phase == .stopping)
            }
        }
        .padding(13)
        .background(
            preferences.palette.surfaceSunken.opacity(0.48),
            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
        )
    }

    private var failedContent: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(MediaStrings.failed, systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(preferences.palette.error)
        }
    }

    private var unloadedResult: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(MediaStrings.loadResultDetail).font(.caption)
                .foregroundStyle(preferences.palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            FirasGlassControlGroup {
                Button(action: load) {
                    Label(isLoadingAsset ? MediaStrings.preparingResult : MediaStrings.loadResult, systemImage: "arrow.down.circle")
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 46).padding(.horizontal, 12)
                }.modifier(FirasGlassControlStyle()).disabled(isLoadingAsset)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func resultContent(_ url: URL) -> some View {
        switch creation.kind {
        case .image:
            MediaResultImage(url: url, aspectRatio: creation.aspect?.ratio ?? 1)
        case .video, .music:
            MediaResultPlayback(url: url, kind: creation.kind, lease: playbackLease)
        }
    }

    private func resultActions(_ url: URL) -> some View {
        FirasGlassControlGroup(spacing: 9) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) { actionButtons(url) }
                VStack(spacing: 9) { actionButtons(url) }
            }
        }
    }

    @ViewBuilder
    private func actionButtons(_ url: URL) -> some View {
        if creation.kind != .music {
            Button(action: save) {
                Label(MediaStrings.save, systemImage: "square.and.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 46)
            }
            .modifier(FirasGlassControlStyle())
        }

        ShareLink(item: url) {
            Label(MediaStrings.share, systemImage: "square.and.arrow.up")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 46)
        }
        .modifier(FirasGlassControlStyle(prominent: true))
    }

    private var kindIcon: String {
        switch creation.kind {
        case .image: "photo"
        case .video: "video"
        case .music: "waveform"
        }
    }

    private var fallbackTitle: String {
        switch (creation.kind, preferences.language) {
        case (.image, .arabic): "صورة فِراس"
        case (.video, .arabic): "فيديو فِراس"
        case (.music, .arabic): "موسيقى فِراس"
        case (.image, .english): "Firas image"
        case (.video, .english): "Firas video"
        case (.music, .english): "Firas music"
        }
    }
}

private struct MediaImageLoadID: Equatable {
    let url: URL
    let maximumPixels: Int
}

private struct MediaResultImage: View {
    let url: URL
    let aspectRatio: Double

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var failed = false
    @State private var measuredWidth: CGFloat = 320

    private var loadID: MediaImageLoadID {
        MediaImageLoadID(url: url, maximumPixels: Int(min(1_200, max(64, measuredWidth * displayScale))))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                MediaPreviewStatus(failed: failed, systemImage: "photo")
            }
        }
        .aspectRatio(CGFloat(aspectRatio), contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(preferences.palette.surfaceSunken)
        .clipShape(.rect(cornerRadius: 19))
        .overlay { RoundedRectangle(cornerRadius: 19).stroke(preferences.palette.border) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if $0.isFinite && $0 > 0 { measuredWidth = $0 } }
        .task(id: loadID) {
            image = nil
            failed = false
            let requested = loadID
            guard let thumbnail = try? await MediaLocalFileLoader.shared.thumbnail(at: requested.url, maximumPixels: requested.maximumPixels),
                  !Task.isCancelled else {
                if !Task.isCancelled { failed = true }
                return
            }
            // CGImage is Sendable. Decoded pixels and alpha survive the actor
            // hop; wrapping them avoids recompression and another image decode.
            image = UIImage(cgImage: thumbnail)
        }
        .accessibilityLabel(Text(MediaStrings.result))
    }
}

private struct MediaPlaybackLoadID: Equatable {
    let url: URL
    let active: Bool
}

/// Native local-file playback. A row never opens a remote URL, autoplays, or
/// owns the render job. KVO owns immediate playback reactions; the visible task
/// samples readiness and progress without deciding which player may play.
private struct MediaResultPlayback: View {
    let url: URL
    let kind: MediaStudioKind
    let lease: MediaPlaybackLease

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer?
    @State private var loadedPlayerURL: URL?
    @State private var ready = false
    @State private var failed = false
    @State private var playbackStatus: AVPlayer.TimeControlStatus = .paused
    @State private var position = 0.0
    @State private var duration = 0.0

    var body: some View {
        Group {
            if let engine = player, !failed {
                playbackContent(engine)
                    .onReceive(engine.publisher(for: \.timeControlStatus, options: [.initial, .new])
                        .receive(on: DispatchQueue.main)) { status in
                        playbackChanged(status, engine: engine)
                    }
            } else {
                MediaPreviewStatus(failed: failed, systemImage: kind == .video ? "video" : "waveform")
                    .frame(minHeight: 160)
            }
        }
        .frame(maxWidth: .infinity)
        .background(preferences.palette.surfaceSunken)
        .clipShape(.rect(cornerRadius: 19))
        .overlay { RoundedRectangle(cornerRadius: 19).stroke(preferences.palette.border) }
        .task(id: MediaPlaybackLoadID(url: url, active: scenePhase == .active)) {
            guard scenePhase == .active else { return }
            failed = false
            ready = false
            playbackStatus = .paused
            position = 0
            duration = 0
            guard let local = try? await MediaLocalFileLoader.shared.readableURL(at: url, maximumBytes: kind == .video ? 200_000_000 : 30_000_000),
                  !Task.isCancelled else {
                if !Task.isCancelled { failed = true }
                return
            }
            let engine = AVPlayer(url: local)
            player = engine
            loadedPlayerURL = url
            ready = false
            playbackStatus = .paused
            let readinessDeadline = Date.now.addingTimeInterval(15)
            defer {
                engine.pause()
                lease.release(engine)
                engine.replaceCurrentItem(with: nil)
                if player === engine { player = nil; loadedPlayerURL = nil; ready = false; playbackStatus = .paused }
            }
            while !Task.isCancelled, !failed, player === engine, scenePhase == .active {
                let item = engine.currentItem
                ready = item?.status == .readyToPlay
                failed = item?.status == .failed || engine.status == .failed
                if !ready, Date.now >= readinessDeadline { failed = true }
                let current = engine.currentTime().seconds
                if current.isFinite { position = max(0, current) }
                let total = item?.duration.seconds ?? 0
                if total.isFinite { duration = max(0, total) }
                if failed { break }
                do { try await Task.sleep(for: .milliseconds(playbackStatus == .playing || !ready ? 250 : 1_000)) }
                catch { break }
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { releasePlayer() } }
        .onDisappear { releasePlayer() }
        .accessibilityLabel(Text(MediaStrings.result))
    }

    private func playbackContent(_ engine: AVPlayer) -> some View {
        Group {
            if kind == .video {
                VideoPlayer(player: engine).aspectRatio(16.0 / 9.0, contentMode: .fit)
            } else {
                audioControls
            }
        }
    }

    private func playbackChanged(_ status: AVPlayer.TimeControlStatus, engine: AVPlayer) {
        guard player === engine, scenePhase == .active,
              loadedPlayerURL == url,
              engine.timeControlStatus == status else { return }
        // Main-queue delivery can contain an event queued before another player
        // paused this engine. Only its current state may claim the live lease.
        playbackStatus = status
        if status == .paused {
            lease.release(engine)
        } else if !lease.claim(engine, kind: kind) {
            failed = true
            playbackStatus = .paused
            engine.pause()
        }
    }

    private var audioControls: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(preferences.palette.accent)
                .accessibilityHidden(true)
            if duration > 0 {
                Slider(value: Binding(get: { min(position, duration) }, set: { seek($0) }), in: 0...duration)
                    .tint(preferences.palette.accent)
                    .frame(minHeight: 44)
                    .disabled(!ready)
                    .accessibilityLabel(Text(MediaStrings.playbackPosition))
                Text(verbatim: "\(timeLabel(position)) / \(timeLabel(duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(preferences.palette.textSecondary)
                    .environment(\.layoutDirection, .leftToRight)
            } else {
                Text(MediaStrings.preparingResult).font(.caption).foregroundStyle(preferences.palette.textSecondary)
            }
            Button {
                guard let player, ready else { return }
                if player.timeControlStatus != .paused {
                    player.pause()
                    lease.release(player)
                } else {
                    guard lease.claim(player, kind: kind) else { failed = true; return }
                    if duration > 0, position >= duration - 0.1 { seek(0) }
                    player.play()
                }
            } label: {
                Label(playbackStatus == .paused ? MediaStrings.pausedPlayback : MediaStrings.pausePlayback,
                      systemImage: playbackStatus == .paused ? "play.fill" : "pause.fill")
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 48)
            }
            .modifier(FirasGlassControlStyle(prominent: true))
            .disabled(!ready || player == nil)
        }
        .padding(22)
    }

    private func seek(_ value: Double) {
        guard let player, ready, value.isFinite else { return }
        let bounded = min(max(0, value), duration)
        player.seek(to: CMTime(seconds: bounded, preferredTimescale: 600))
        position = bounded
    }

    private func releasePlayer() {
        player?.pause()
        if let player { lease.release(player) }
        player?.replaceCurrentItem(with: nil)
        player = nil
        loadedPlayerURL = nil
        ready = false
        playbackStatus = .paused
    }

    private func timeLabel(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

private struct MediaPreviewStatus: View {
    let failed: Bool
    let systemImage: String
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.title2).accessibilityHidden(true)
            Text(failed ? MediaStrings.previewUnavailable : MediaStrings.preparingResult)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(preferences.palette.textSecondary)
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 96)
    }
}

private struct MediaMessageBanner: View {
    let message: String
    let isError: Bool
    let dismiss: () -> Void

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        GlassSurface(cornerRadius: 16, tintStrength: 0.055) {
            HStack(spacing: 10) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? preferences.palette.error : preferences.palette.success)
                    .accessibilityHidden(true)
                Text(verbatim: message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(preferences.palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(MediaStrings.dismiss))
            }
            .padding(.leading, 13)
            .padding(.trailing, 2)
        }
    }
}

private actor MediaLocalFileLoader {
    static let shared = MediaLocalFileLoader()

    func sourceData(at url: URL, maximumBytes: Int) throws -> Data {
        // The system-selected file is read during its transfer lifetime. No
        // original photo is copied into app history or retained on disk here.
        let bytes = try MediaSourceFileReader.read(at: url, maximumBytes: maximumBytes)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try validateDimensions(source)
        return bytes
    }

    func readableURL(at url: URL, maximumBytes: Int) throws -> URL {
        guard url.isFileURL else { throw CocoaError(.fileReadNoPermission) }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let roots = [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory, .documentDirectory]
            .compactMap { FileManager.default.urls(for: $0, in: .userDomainMask).first }
            + [FileManager.default.temporaryDirectory]
        guard roots.contains(where: { resolved.path.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/") }) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maximumBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return resolved
    }

    func thumbnail(at url: URL, maximumPixels: Int) throws -> CGImage {
        try Task.checkCancellation()
        let local = try readableURL(at: url, maximumBytes: 25_000_000)
        guard let source = CGImageSourceCreateWithURL(local as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try validateDimensions(source)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: min(1_200, max(64, maximumPixels)),
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        try Task.checkCancellation()
        return image
    }

    private func validateDimensions(_ source: CGImageSource) throws {
        guard let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = values[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = values[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard MediaSourcePixelPolicy.accepts(width: width.intValue, height: height.intValue) else {
            throw MediaSourceFileError.dimensionsTooLarge
        }
        try Task.checkCancellation()
    }
}
