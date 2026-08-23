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
/// Chemical Store editor, pre-populated with everything the lookup found.
///
/// # It owns the SESSION, not the screens
///
/// The lookup session — query, results, in-flight tasks and the resolved draft
/// — lives in a `ChemicalLookupCoordinator` held here in `@State`. SwiftUI
/// keeps that object alive across every reconstruction of the views below, so
/// rotating the phone or taking a screenshot cannot cancel a resolve or send a
/// populated Review Chemical back to Add Chemical.
///
/// Previously the resolved draft was `@State` here and the editor was presented
/// through a Binding whose setter cleared it. Any dismissal SwiftUI decided to
/// perform — including one the operator never asked for — ran that setter and
/// silently discarded the draft. Now the draft belongs to the coordinator and
/// is cleared only by Save or an explicit Cancel.
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

    /// THE session. Created once, survives every redraw below it.
    @State private var coordinator = ChemicalLookupCoordinator()

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
            coordinator: coordinator,
            initialQuery: prefillQuery,
            existing: existing,
            onManualEntry: { coordinator.showManualEntry = true }
        ) { _ in
            // The coordinator already holds the draft. Nothing to copy — a
            // second copy is exactly what used to go missing.
        }
        // ONE sheet presenter for both destinations, driven by coordinator
        // state so a rebuild of this view cannot tear the editor down.
        .sheet(item: editorTarget) { target in
            // THE Chemical Store editor. `chemical:` stays the record being
            // matched (nil when adding) so Save still takes the right
            // create/update path; `prefill:` is what to show.
            EditSavedChemicalSheet(
                chemical: existing,
                prefill: target.draft
            ) { saved in
                onSaved?(saved)
                coordinator.finishReview()
                dismiss()
            }
            // A review session ends because the operator ended it. Interactive
            // swipe-to-dismiss is the one gesture indistinguishable from an
            // accidental drag while scrolling a long form, and it was the most
            // likely way a populated Review Chemical vanished mid-inspection.
            .interactiveDismissDisabled()
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
                if let draft = coordinator.reviewDraft { return EditorTarget(draft: draft) }
                if coordinator.showManualEntry { return EditorTarget(draft: nil) }
                return nil
            },
            set: { newValue in
                // Reached only after `interactiveDismissDisabled`, i.e. from
                // the editor's own Cancel or Save.
                if newValue == nil { coordinator.finishReview() }
            }
        )
    }
}
