import SwiftUI

/// Each label-rate option is a compact, independent choice. Long label directions
/// are kept behind See details so a long application note cannot fill a sheet.
struct SprayLabelRateSelectionView: View {
    let rates: [SpraySelectableRate]
    let selectedID: UUID?
    let onSelect: (SpraySelectableRate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var expandedRates: Set<UUID> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(rates) { rate in
                        let selected = selectedID == rate.id
                        let bandWithPoints = rate.requiresOperatorRate &&
                            rates.contains { $0.useTitle == rate.useTitle && $0.isRangePreset }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .center, spacing: 8) {
                                Button {
                                    onSelect(rate)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(rate.displayText)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                            .multilineTextAlignment(.leading)
                                        if selected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.tint)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!rate.isSelectable || bandWithPoints)
                                .accessibilityIdentifier("spray.labelRate.\(rate.id)")

                                Button {
                                    if expandedRates.contains(rate.id) {
                                        expandedRates.remove(rate.id)
                                    } else {
                                        expandedRates.insert(rate.id)
                                    }
                                } label: {
                                    Text(expandedRates.contains(rate.id) ? "Hide details" : "See details")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .frame(minHeight: 36)
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("spray.labelRate.details.\(rate.id)")
                            }

                            if bandWithPoints {
                                Text("Label range — choose a permitted rate below")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if !rate.isSelectable {
                                Text("Reference only — no usable application rate")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if expandedRates.contains(rate.id) {
                                Divider()
                                ForEach(rate.selectionDetails, id: \.self) { detail in
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            selected ? Color.accentColor.opacity(0.10) :
                                Color(.secondarySystemGroupedBackground)
                        )
                        .clipShape(.rect(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(selected ? Color.accentColor : Color(.separator),
                                              lineWidth: selected ? 1.5 : 0.5)
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
