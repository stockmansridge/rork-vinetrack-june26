import SwiftUI

/// The one place VineTrack tells an operator how long a register lookup takes.
///
/// # Why this is a component and not a string in five views
///
/// A first-time structured lookup queries the national register, fetches the
/// approved label PDF, extracts its Directions For Use table and runs a
/// web-research pass. That is minutes, not seconds, and it is the CORRECT
/// behaviour — but an operator watching a spinner with no stated duration
/// reasonably concludes the app has hung, backs out, and thereby cancels the
/// very request that would have populated the product.
///
/// Five screens start that same request. If each carried its own wording they
/// would drift, and the screen that drifted into silence is the one where
/// somebody gives up. One component, one sentence, every entry point.
///
/// # Deliberately not a warning
///
/// No triangle, no amber, no `.warning` role. Nothing has gone wrong: the
/// lookup is working, and dressing "this is slow on purpose" as a fault
/// teaches operators to distrust a result that is about to be correct.
struct ChemicalLookupDurationNotice: View {

    /// Whether to append the second sentence about repeat lookups.
    ///
    /// Worth saying where the operator is about to WAIT (they are choosing a
    /// product, or already resolving one). Not worth saying on a screen that
    /// merely mentions lookups in passing.
    let showsRepeatHint: Bool

    init(showsRepeatHint: Bool = false) {
        self.showsRepeatHint = showsRepeatHint
    }

    /// The canonical copy. Exposed so tests can assert the SAME sentence
    /// reaches every entry point rather than five near-misses.
    static let primaryText: String =
        "Official register searches and product details can take a few minutes "
        + "the first time. Keep this screen open while VineTrack checks the product."

    static let repeatHintText: String =
        "Repeat lookups are usually faster once the product has been loaded."

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.primaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if showsRepeatHint {
                    Text(Self.repeatHintText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}
