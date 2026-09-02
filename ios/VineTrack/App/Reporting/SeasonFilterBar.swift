import SwiftUI

/// Season/Vintage selector for reporting screens — the same chip pattern the
/// Yield Reports screen uses, extracted so every dated function shares one
/// control instead of each inventing its own list.
///
/// The selection is a **date range**, not a stored column: callers take
/// `SeasonWindow` and filter their records by whichever event-date column they
/// already have. Changing the selection must refresh lists, totals, charts and
/// exports together — not just a heading.
struct SeasonFilterBar: View {

    /// Vintage in progress, from the vineyard's shared season start.
    let currentVintage: Int

    /// Currently displayed vintage.
    @Binding var selectedVintage: Int

    /// Oldest vintage with real data, so a young vineyard isn't offered 15
    /// empty seasons. `nil` offers the full previous-15 window.
    var earliestRecordVintage: Int?

    /// Season range for the current selection, shown under the chips so the
    /// operator can see exactly which dates are included.
    var window: SeasonWindow?

    private var vintages: [Int] {
        SeasonWindow.availableVintages(
            currentVintage: currentVintage,
            selected: selectedVintage,
            earliestRecordVintage: earliestRecordVintage
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Season", systemImage: "calendar")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(vintages, id: \.self) { vintage in
                        let isSelected = vintage == selectedVintage
                        Button {
                            guard vintage != selectedVintage else { return }
                            selectedVintage = vintage
                        } label: {
                            Text(SeasonWindow.label(for: vintage, currentVintage: currentVintage))
                                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 44)
                                .background(
                                    Capsule().fill(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Season \(String(vintage))")
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    }
                }
                .padding(.vertical, 2)
            }
            .contentMargins(.horizontal, 0, for: .scrollContent)

            if let window {
                Text(seasonRangeText(window))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "1 Jul 2026 – 30 Jun 2027" — the inclusive dates the operator sees, even
    /// though filtering itself uses the half-open range.
    private func seasonRangeText(_ window: SeasonWindow) -> String {
        let start = window.start.formatted(.dateTime.day().month(.abbreviated).year())
        let end = window.displayEnd.formatted(.dateTime.day().month(.abbreviated).year())
        return "\(start) – \(end)"
    }
}
