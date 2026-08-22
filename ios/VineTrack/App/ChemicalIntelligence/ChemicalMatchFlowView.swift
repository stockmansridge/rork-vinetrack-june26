import SwiftUI

/// Add a chemical: **Search → Select → Review → Save**.
///
/// # Why this is two screens and not six
///
/// This flow used to run Search → Matched Product → Verify Chemical → Confirm,
/// with a warning on most of them. For the ordinary case that was four screens
/// to answer one question — "is this the product on my drum?" — and, worse, the
/// middle screens were READ-ONLY. When the resolver could not confirm a
/// registration it reported "no active ingredients were identified", the
/// operator could see Mancozeb on the search screen behind it, and there was
/// nothing they could do about it.
///
/// So the wizard is now a search screen that hands straight to the existing
/// Chemical Store editor, pre-populated with everything the lookup found. The
/// operator reviews real values, corrects anything wrong, and saves. Confirming
/// a product is an act of editing it, not an act of clicking through warnings
/// about it.
///
/// # It owns no lookup of its own
///
/// Search, ranking and resolution live in `ChemicalProductSearchSheet`; mapping
/// lives in `ChemicalReviewMerge`; editing and saving live in
/// `EditSavedChemicalSheet`. This type is the wiring between them and nothing
/// else, which is what keeps the Chemical Store, the Spray Calculator and the
/// Spray Program's "Add New Chemical" on genuinely the same path rather than on
/// three that merely look alike.
struct ChemicalMatchFlowView: View {
    /// Existing chemical being matched (legacy `needs_match` cleanup), or nil
    /// when adding something new.
    let existing: SavedChemical?
    /// Seeds the search box, so "Match & Verify" on a legacy record starts from
    /// the name the grower already uses.
    let prefillQuery: String
    /// Hands the persisted product back to whatever opened this flow — the
    /// Spray Program's product line, for instance, which binds it by id.
    let onSaved: ((SavedChemical) -> Void)?

    @Environment(\.dismiss) private var dismiss

    /// The populated, unsaved record under review. Presenting it IS the match
    /// step — there is no separate read-only confirmation of it.
    @State private var reviewDraft: SavedChemical?
    @State private var showManualEntry: Bool = false

    init(
        existing: SavedChemical? = nil,
        prefillQuery: String = "",
        onSaved: ((SavedChemical) -> Void)? = nil
    ) {
        self.existing = existing
        self.prefillQuery = prefillQuery
        self.onSaved = onSaved
    }

    var body: some View {
        ChemicalProductSearchSheet(
            initialQuery: prefillQuery,
            existing: existing,
            onManualEntry: { showManualEntry = true }
        ) { draft in
            // Resolved ONCE, here. The draft is a stable value from this moment
            // until Save or Cancel; nothing downstream re-runs the lookup.
            reviewDraft = draft
        }
        // ONE sheet presenter for both destinations. Two chained `.sheet`
        // modifiers on the same view share a presentation slot, and a rebuild
        // of this view while one was open could tear down the editor inside it.
        .sheet(item: editorTarget) { target in
            // THE Chemical Store editor. `chemical:` stays the record being
            // matched (nil when adding) so Save still takes the right
            // create/update path; `prefill:` is what to show. Same screen,
            // same Save, same `saved_chemicals` row.
            EditSavedChemicalSheet(
                chemical: existing,
                prefill: target.draft
            ) { saved in
                onSaved?(saved)
                dismiss()
            }
        }
    }

    /// What the single sheet should show: a reviewed draft, or a blank manual
    /// form. Modelled as one value so the two cannot both be presented.
    private struct EditorTarget: Identifiable {
        let draft: SavedChemical?
        var id: String { draft?.id.uuidString ?? "manual" }
    }

    private var editorTarget: Binding<EditorTarget?> {
        Binding(
            get: {
                if let reviewDraft { return EditorTarget(draft: reviewDraft) }
                if showManualEntry { return EditorTarget(draft: nil) }
                return nil
            },
            set: { newValue in
                if newValue == nil {
                    reviewDraft = nil
                    showManualEntry = false
                }
            }
        )
    }
}
