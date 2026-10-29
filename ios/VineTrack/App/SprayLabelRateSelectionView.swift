import SwiftUI

/// Show label rate choices first. Long label directions remain available on demand,
/// not as a multi-screen card that hides the next rate option.
/// Selecting a rate is a separate action from reading its full label evidence.
struct SprayLabelRateSelectionView: View {
    let rates: [SpraySelectableRate]
    let selectedID: UUID?
    let onSelect: (SpraySelectableRate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var expandedRateIDs: Set<UUID> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(rates) { rate in
                        let selected = selectedID == rate.id
                        // Preserve the existing range/preset policy; a displayed
                        // label band isn't itself an operator-selected dose.
                        let bandWithPoints = rate.requiresOperatorRate && rates.contains {
                            $0.useTitle == rate.useTitle && $0.isRangePreset
                        }
                        let canChoose = rate.isSelectable && !bandWithPoints
                        let expanded = expandedRateIDs.contains(rate.id)

                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                guard canChoose else { return }
                                onSelect(rate)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Text(rate.displayText)
                                        .font(.headline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if selected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.tint)
                                    } else if canChoose {
                                        Image(systemName: "circle")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!canChoose)
                            .accessibilityIdentifier("spray.labelRate.\(rate.id)")

                            if bandWithPoints {
                                Text("Label range — choose a rate within this range")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if !rate.isSelectable {
                                Text("Reference only — not a selectable application rate")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Button {
                                if expanded {
                                    expandedRateIDs.remove(rate.id)
                                } else {
                                    expandedRateIDs.insert(rate.id)
                                }
                            } label: {
                                Label(expanded ? "Hide details" : "See details",
                                      systemImage: expanded ? "chevron.up" : "info.circle")
                                    .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("spray.labelRate.details.\(rate.id)")

                            if expanded {
                                Divider()
                                ForEach(rate.selectionDetails, id: \.self) { detail in
                                    Text(detail)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(selected ? Color.accentColor.opacity(0.10) : Color(.secondarySystemGroupedBackground))
                        .clipShape(.rect(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(selected ? Color.accentColor : Color(.separator), lineWidth: selected ? 2 : 0.5)
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
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
