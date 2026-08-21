import SwiftUI

/// Program Step picker for the `+ → Plan from Program` route.
///
/// Selecting a row hands the step back to the caller, which runs the SAME
/// Program → Calculator action the Program tab uses. There is deliberately no
/// second prefill implementation: two routes into the calculator that build
/// their prefill differently is how the two drift apart.
struct SprayProgramStepPickerSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let steps: [SprayProgramStep]
    let onSelect: (SprayProgramStep) -> Void

    @State private var searchText: String = ""

    /// Always E-L ascending — the order a spray program is read in.
    private var visibleSteps: [SprayProgramStep] {
        SprayProgramCatalog.sorted(
            SprayProgramCatalog.filtered(steps, query: searchText),
            by: .elStageAscending
        )
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(visibleSteps) { step in
                    Button {
                        onSelect(step)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Text(step.elStageLabel ?? "—")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(
                                    step.elStageLabel == nil
                                        ? AnyShapeStyle(.tertiary)
                                        : AnyShapeStyle(VineyardTheme.leafGreen)
                                )
                                .frame(minWidth: 46)
                                .padding(.vertical, 5)
                                .background(
                                    (step.elStageLabel == nil
                                        ? Color(.tertiarySystemFill)
                                        : VineyardTheme.leafGreen.opacity(0.14)),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.name.isEmpty ? "Untitled Program Step" : step.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                if let subtitle = subtitle(for: step) {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Plan from Program")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search program")
            .overlay {
                if visibleSteps.isEmpty {
                    ContentUnavailableView {
                        Label("No Program Steps", systemImage: "list.bullet.rectangle.portrait")
                    } description: {
                        Text(
                            searchText.isEmpty
                                ? "Build your vineyard spray program by adding reusable spray steps, or create them in the Admin Portal."
                                : "No program steps match \u{201C}\(searchText)\u{201D}."
                        )
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// Target where the step states one, else its primary product — whichever
    /// actually helps the operator recognise the step.
    private func subtitle(for step: SprayProgramStep) -> String? {
        if let target = step.targetDisplay { return target }
        let products = step.products
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return products.first
    }
}
