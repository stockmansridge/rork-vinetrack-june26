import SwiftUI

/// Read-only rate evidence with an explicit choice; opening/closing never seeds a rate.
struct SprayLabelRateSelectionView: View {
    let rates: [SpraySelectableRate]
    let selectedID: UUID?
    let onSelect: (SpraySelectableRate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(rates) { rate in
                        let selected = selectedID == rate.id
                        // Retain the existing iOS range/preset selection policy.
                        let bandWithPoints = rate.requiresOperatorRate && rates.contains { $0.useTitle == rate.useTitle && $0.isRangePreset }
                        Button {
                            onSelect(rate)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top) {
                                    Text(rate.displayText).font(.title2.weight(.bold))
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 8)
                                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                                }
                                ForEach(rate.selectionDetails, id: \.self) {
                                    Text($0).font(.subheadline).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if bandWithPoints { Text("Label range — choose a point below").font(.caption) }
                                else if !rate.isSelectable { Text("Reference only — not a resolved application rate").font(.caption) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(selected ? Color.accentColor.opacity(0.10) : Color(.secondarySystemGroupedBackground))
                            .clipShape(.rect(cornerRadius: 12))
                            .overlay { RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : Color(.separator), lineWidth: selected ? 2 : 0.5) }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .disabled(!rate.isSelectable || bandWithPoints)
                        .accessibilityIdentifier("spray.labelRate.\(rate.id)")
                    }
                }.padding(.horizontal).padding(.vertical, 12)
            }
            .navigationTitle("Select label rate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
