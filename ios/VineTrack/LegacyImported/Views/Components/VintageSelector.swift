import SwiftUI

/// Shared Vintage selector for every vintage-scoped list, summary and report.
///
/// The platform-wide Vintage audit found each screen inventing its own option
/// list (three to seven years, and in one case *calendar* years rather than
/// vintages). This is the single definition:
///
///   * the current vintage is the default and is labelled "Current";
///   * the previous 15 vintages are always offered;
///   * a screen that plans forward (grape allocation, for instance) may also
///     offer the next vintage by passing `includesNextVintage: true`;
///   * a vintage the user is already looking at is always present in the list
///     even when it falls outside that window, so an old record opened from a
///     deep link can never select an option that does not exist.
///
/// The current vintage itself must come from `VintageResolver` (the mirror of
/// the authoritative sql/119 resolver) — never from `Calendar.current.year`,
/// which is only correct for a 1 January season start.
nonisolated enum VintageWindow {

    /// Number of previous vintages offered alongside the current one.
    static let previousCount = 15

    /// Descending option list: optional next vintage, the current vintage,
    /// then the previous 15 — plus `selected` if it falls outside that range.
    static func options(
        currentVintage: Int,
        includesNextVintage: Bool = false,
        selected: Int? = nil
    ) -> [Int] {
        var years = Set<Int>()
        if includesNextVintage { years.insert(currentVintage + 1) }
        for offset in 0...previousCount {
            years.insert(currentVintage - offset)
        }
        if let selected { years.insert(selected) }
        return years.sorted(by: >)
    }

    /// "2027 · Current" for the current vintage, otherwise "2027".
    static func label(for vintage: Int, currentVintage: Int) -> String {
        vintage == currentVintage ? "\(String(vintage)) · Current" : String(vintage)
    }
}

/// Inline menu-style Vintage selector.
///
/// Changing the selection must refresh the screen's totals, charts, exports and
/// record lists — not just a heading. Callers drive that by keying their load
/// on the bound value (`.task(id: selection)` or an explicit reload in
/// `onChange`).
struct VintageSelector: View {
    @Binding var selection: Int
    let currentVintage: Int
    var includesNextVintage: Bool = false
    var title: String = "Vintage"

    private var options: [Int] {
        VintageWindow.options(
            currentVintage: currentVintage,
            includesNextVintage: includesNextVintage,
            selected: selection
        )
    }

    var body: some View {
        HStack {
            Label(title, systemImage: "calendar")
                .font(.subheadline)
            Spacer()
            Menu {
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.self) { vintage in
                        Text(VintageWindow.label(for: vintage, currentVintage: currentVintage))
                            .tag(vintage)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(VintageWindow.label(for: selection, currentVintage: currentVintage))
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))
            }
            .accessibilityLabel("\(title), currently \(String(selection))")
        }
    }
}
