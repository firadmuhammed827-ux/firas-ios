import SwiftUI

/// A shared native selector so Chat and Settings always use the same preference.
struct ModelGenerationPicker: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringResource("modelGeneration.title", table: "ModelGeneration"))
                .font(.body.weight(.semibold))
                .foregroundStyle(preferences.palette.textPrimary)

            Picker(
                selection: $preferences.modelGeneration,
                label: Text(LocalizedStringResource("modelGeneration.title", table: "ModelGeneration"))
            ) {
                ForEach(ModelGeneration.allCases) { generation in
                    Text(verbatim: generation.displayVersion).tag(generation)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(minHeight: 44)
            .environment(\.layoutDirection, .leftToRight)

            Text(LocalizedStringResource("modelGeneration.newAnswers", table: "ModelGeneration"))
                .font(.caption)
                .foregroundStyle(preferences.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .tint(preferences.palette.accent)
        .sensoryFeedback(.selection, trigger: preferences.modelGeneration)
    }
}
