import SwiftUI

struct DifficultySelectionSheet: View {
    let request: ChatDifficultyRequest<ChatDifficultyDraft>
    let onChoose: (Int) -> Void
    let onSkip: () -> Void
    let onCancel: () -> Void

    @Environment(PreferencesStore.self) private var preferences
    @State private var selectedLevel: Int

    init(request: ChatDifficultyRequest<ChatDifficultyDraft>, onChoose: @escaping (Int) -> Void,
         onSkip: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.request = request
        self.onChoose = onChoose
        self.onSkip = onSkip
        self.onCancel = onCancel
        _selectedLevel = State(initialValue: request.decision.calibration.level)
    }

    private var isArabic: Bool { preferences.language == .arabic }
    private var languageCode: String { preferences.language.rawValue }

    var body: some View {
        NavigationStack {
            ZStack {
                FirasBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(verbatim: subjectTitle)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(preferences.palette.textPrimary)
                        Text(verbatim: isArabic
                            ? "اختر مستوى هذا الطلب. اختيار المحادثة السابق محدد مسبقاً."
                            : "Choose the level for this request. The conversation’s previous choice is selected.")
                            .font(.subheadline)
                            .foregroundStyle(preferences.palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        FirasGlassControlGroup(spacing: 10) {
                            VStack(spacing: 10) {
                                ForEach(1...7, id: \.self) { level in
                                    levelButton(level)
                                }
                            }
                        }
                        FirasGlassControlGroup(spacing: 10) {
                            VStack(spacing: 10) {
                                Button { onChoose(selectedLevel) } label: {
                                    Text(verbatim: isArabic ? "اختيار وإرسال" : "Choose and send")
                                        .font(.body.weight(.semibold))
                                        .frame(maxWidth: .infinity, minHeight: 48)
                                }
                                .modifier(FirasGlassControlStyle(prominent: true))
                                Button(action: onSkip) {
                                    Text(verbatim: isArabic
                                        ? "استخدام \(DifficultyPolicy.label(level: request.decision.calibration.level, language: languageCode))"
                                        : "Use \(DifficultyPolicy.label(level: request.decision.calibration.level, language: languageCode))")
                                        .frame(maxWidth: .infinity, minHeight: 48)
                                }
                                .modifier(FirasGlassControlStyle())
                            }
                        }
                    }
                    .frame(maxWidth: 680)
                    .padding(18)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(isArabic ? "مستوى الأسئلة" : "Question difficulty")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onCancel) {
                        Text(verbatim: isArabic ? "إلغاء" : "Cancel").frame(minHeight: 44)
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(34)
        .presentationBackground(preferences.palette.background)
        .environment(\.layoutDirection, preferences.language.layoutDirection)
        .onDisappear { onCancel() }
    }

    private func levelButton(_ level: Int) -> some View {
        Button { selectedLevel = level } label: {
            HStack(spacing: 12) {
                Text(verbatim: "\(level)")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .environment(\.layoutDirection, .leftToRight)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: DifficultyPolicy.label(level: level, language: languageCode)
                        .split(separator: "—", maxSplits: 1).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "")
                        .font(.body.weight(.semibold))
                    Text(verbatim: DifficultyPolicy.hint(level: level, language: languageCode))
                        .font(.subheadline)
                        .foregroundStyle(preferences.palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if selectedLevel == level {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold)).accessibilityHidden(true)
                }
            }
            .foregroundStyle(preferences.palette.textPrimary)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        }
        .modifier(FirasGlassControlStyle(prominent: selectedLevel == level))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selectedLevel == level ? [.isSelected] : [])
    }

    private var subjectTitle: String {
        switch request.decision.subject {
        case "math": isArabic ? "الرياضيات" : "Mathematics"
        case "physics": isArabic ? "الفيزياء" : "Physics"
        case "chemistry": isArabic ? "الكيمياء" : "Chemistry"
        default: isArabic ? "الأسئلة والتمارين" : "Questions and exercises"
        }
    }
}
