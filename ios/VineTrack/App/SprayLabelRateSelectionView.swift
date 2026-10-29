import SwiftUI

/// Compact, read-only registered rate choices. Extensive label restrictions
/// remain available on demand without turning each rate into a page-long card.
struct SprayLabelRateSelectionView: View {
    let rates: [SpraySelectableRate]
    let selectedID: UUID?
    let onSelect: (SpraySelectableRate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var expandedDetails: Set<UUID> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(rates) { rate in
                        let selected = selectedID == rate.id
                        let bandWithPoints = rate.requiresOperatorRate &&
                            rates.contains { $0.useTitle == rate.useTitle && $0.isRangePreset }
                        let canChoose = rate.isSelectable && !bandWithPoints
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Button {
                                    onSelect(rate)
                                    dismiss()
                                } label: {
                                    HStack(alignment: .center, spacing: 8) {
                                        Text(rate.displayText)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                            .multilineTextAlignment(.leading)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        if selected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.tint)
                                        }
                                    }
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!canChoose)
                                .opacity(canChoose ? 1 : 0.6)
                                .accessibilityIdentifier("spray.labelRate.\(rate.id)")

                                if !rate.selectionDetails.isEmpty {
                                    Button {
                                        if expandedDetails.contains(rate.id) {
                                            expandedDetails.remove(rate.id)
                                        } else {
                                            expandedDetails.insert(rate.id)
                                        }
                                    } label: {
                                        Text(expandedDetails.contains(rate.id) ? "Hide details" : "See details")
                                            .font(.caption.weight(.semibold))
                                            .frame(minHeight: 44)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("spray.labelRate.details.\(rate.id)")
                                }
                            }
                            if bandWithPoints {
                                Text("Choose a rate inside this label range below.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if !rate.isSelectable {
                                Text("Reference only — not a resolved application rate.")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            if expandedDetails.contains(rate.id) {
                                Divider()
                                ForEach(rate.selectionDetails, id: \.self) { detail in
                                    Text(detail)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected ? Color.accentColor.opacity(0.10) : Color(.secondarySystemGroupedBackground))
                        .clipShape(.rect(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(selected ? Color.accentColor : Color(.separator), lineWidth: selected ? 1.5 : 0.5)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .navigationTitle("Select label rate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
