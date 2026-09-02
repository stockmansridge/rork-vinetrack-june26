import SwiftUI

/// Season/Vintage selector for reporting screens — the same chip pattern the
/// Yield Reports screen uses, extracted so every dated function shares one
/// control instead of each inventing its own list.
///
/// Contract (identical on Android):
/// * **All vintages** is always first and removes the date restriction entirely.
/// * Only vintages that actually hold non-deleted records for this vineyard and
///   surface are offered — no fixed span, no empty seasons.
/// * Every represented vintage appears, however far back it goes.
/// * The current season is selected by default only when it holds records;
///   otherwise the screen opens on All.
///
/// The selection is a **date range**, not a stored column: callers take the
/// resolved `SeasonScope` and filter records by whichever event-date column they
/// already have. Changing the selection refreshes lists, totals, charts and
/// exports together, because they all read the same scope.
struct SeasonFilterBar: View {

    /// Resolved scope — option list, effective window and current season.
    let scope: SeasonScope

    /// The operator's choice. Bound so a screen can reset it to `.automatic`.
    @Binding var selection: SeasonSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Season", systemImage: "calendar")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(
                        title: SeasonScope.allTitle,
                        isSelected: scope.isAll,
                        accessibilityLabel: "All vintages"
                    ) {
                        selection = .all
                    }

                    ForEach(scope.available, id: \.self) { vintage in
                        chip(
                            title: SeasonWindow.label(for: vintage, currentVintage: scope.currentVintage),
                            isSelected: scope.vintage == vintage,
                            accessibilityLabel: "Season \(String(vintage))"
                        ) {
                            // Choosing the current season returns the screen to
                            // its automatic state, so it keeps rolling over into
                            // the next season by itself.
                            selection = vintage == scope.currentVintage ? .automatic : .vintage(vintage)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .contentMargins(.horizontal, 0, for: .scrollContent)

            Text(rangeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func chip(
        title: String,
        isSelected: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard !isSelected else { return }
            action()
        } label: {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(
                    Capsule().fill(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// "1 Jul 2026 – 30 Jun 2027" — the inclusive dates the operator sees, even
    /// though filtering itself uses the half-open range.
    private var rangeText: String {
        guard let window = scope.window else {
            return scope.available.isEmpty
                ? "No dated records yet"
                : "Every record, all seasons"
        }
        let start = window.start.formatted(.dateTime.day().month(.abbreviated).year())
        let end = window.displayEnd.formatted(.dateTime.day().month(.abbreviated).year())
        return "\(start) – \(end)"
    }
}
