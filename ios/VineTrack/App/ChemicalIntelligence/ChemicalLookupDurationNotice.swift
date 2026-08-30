import SwiftUI

/// The one place VineTrack tells an operator how long a chemical search takes.
///
/// # Why this is a component and not a string in five views
///
/// A first-time structured lookup queries the national register, fetches the
/// approved label PDF, extracts its Directions For Use table and runs a
/// web-research pass. That takes real time and it is the CORRECT behaviour —
/// but an operator watching a spinner with no stated duration reasonably
/// concludes the app has hung, backs out, and thereby cancels the very
/// request that would have populated the product.
///
/// Five screens start that same request. If each carried its own wording they
/// would drift, and the screen that drifted into silence is the one where
/// somebody gives up. One component, one sentence, every entry point — and
/// the SAME sentences on Android (`ChemicalLookupAdvisory`), word for word.
///
/// # Deliberately not a warning
///
/// No triangle, no amber, no `.warning` role. Nothing has gone wrong: the
/// lookup is working, so the advisory renders in VineTrack green — bold and
/// clearly visible, but never dressed as a fault. The clock (idle) or the
/// live spinner (searching) carries the meaning alongside the words, so
/// colour is never the only signal. It never shows a fake percentage or an
/// invented completion time, and a slow lookup is never auto-failed into
/// manual entry.
struct ChemicalLookupDurationNotice: View {

    /// True while a search or product-detail lookup is actively running —
    /// switches to the active wording and shows a live progress indicator.
    let isSearching: Bool

    /// Whether to append the second sentence about repeat lookups.
    ///
    /// Worth saying where the operator is about to WAIT. Shown in the idle
    /// state only — while a request runs, the active sentence is the message.
    let showsRepeatHint: Bool

    init(isSearching: Bool = false, showsRepeatHint: Bool = false) {
        self.isSearching = isSearching
        self.showsRepeatHint = showsRepeatHint
    }

    /// The canonical copy. Exposed so tests can assert the SAME sentence
    /// reaches every entry point rather than five near-misses — and that it
    /// matches Android's `ChemicalLookupAdvisory.IDLE_TEXT` exactly.
    static let primaryText: String =
        "Chemical search can take a little time while VineTrack checks current "
        + "registration and label information."

    /// The active wording, matching Android's
    /// `ChemicalLookupAdvisory.SEARCHING_TEXT` exactly.
    static let searchingText: String =
        "Searching current registration and label information — this can take a "
        + "little time. Please keep this screen open."

    static let repeatHintText: String =
        "Repeat lookups are usually faster once the product has been loaded."

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isSearching {
                ProgressView()
                    .controlSize(.small)
                    .tint(BrandColors.track)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "clock")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(BrandColors.track)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(isSearching ? Self.searchingText : Self.primaryText)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(BrandColors.track)
                if showsRepeatHint && !isSearching {
                    Text(Self.repeatHintText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A soft brand-green tile keeps the bold text readable in light and
        // dark mode without relying on colour alone for meaning.
        .background(BrandColors.track.opacity(0.12))
        .clipShape(.rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}
