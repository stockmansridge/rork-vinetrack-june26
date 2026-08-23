import Foundation
import Testing
@testable import VineTrack

/// VineTrack's target vocabulary must never read as the regulator's record.
///
/// The Review Chemical screen listed every VineTrack target — Powdery Mildew,
/// Downy Mildew, Botrytis — as chips under EVERY authoritative APVMA registered
/// use. Nothing distinguished those words from the label's own target, so a use
/// being read as compliance evidence appeared to carry registrations the label
/// never granted.
///
/// The chips are an editing aid. These tests hold them to that: visible where
/// the operator is choosing a target, absent where the record is merely being
/// read.
struct ChemicalTargetSuggestionPolicyTests {

    // MARK: - Normal review mode

    /// The defect, stated as a rule: an authoritative use displays its own
    /// target and nothing of VineTrack's.
    @Test("A registered target shows no vocabulary suggestions in review")
    func authoritativeUseShowsNoSuggestions() {
        #expect(!ChemicalTargetSuggestionPolicy.showsVocabularySuggestions(
            targetRaw: "Powdery Mildew",
            isEditingTarget: false
        ))
    }

    /// Including a target VineTrack has no word for — the case that most
    /// obviously must not be surrounded by VineTrack's own vocabulary.
    @Test("A label target outside the vocabulary still shows no suggestions")
    func unknownLabelTargetShowsNoSuggestions() {
        #expect(!ChemicalTargetSuggestionPolicy.showsVocabularySuggestions(
            targetRaw: "Phomopsis cane and leaf spot",
            isEditingTarget: false
        ))
    }

    // MARK: - Edit / add-target mode

    /// Opening the target for editing is what makes the suggestions help
    /// rather than a claim.
    @Test("Editing a target reveals the vineyard vocabulary")
    func editingRevealsSuggestions() {
        #expect(ChemicalTargetSuggestionPolicy.showsVocabularySuggestions(
            targetRaw: "Powdery Mildew",
            isEditingTarget: true
        ))
    }

    /// A use with no target yet is an unanswered question, not a record to be
    /// protected, so the vocabulary is offered immediately.
    @Test("An empty target offers the vocabulary without an extra tap")
    func emptyTargetOffersSuggestions() {
        #expect(ChemicalTargetSuggestionPolicy.showsVocabularySuggestions(
            targetRaw: "",
            isEditingTarget: false
        ))
        #expect(ChemicalTargetSuggestionPolicy.showsVocabularySuggestions(
            targetRaw: "   ",
            isEditingTarget: false
        ))
    }

    // MARK: - Selected state

    /// Matching is forgiving because the field is free text and values arrive
    /// from imports: one target must not gain a second spelling because a chip
    /// failed to recognise its own label.
    @Test("Chip selection matches regardless of case and surrounding space")
    func selectionMatchingIsForgiving() {
        #expect(ChemicalTargetSuggestionPolicy.matches(
            targetRaw: "  powdery mildew ",
            target: .powderyMildew
        ))
        #expect(ChemicalTargetSuggestionPolicy.matches(
            targetRaw: SprayTarget.powderyMildew.label,
            target: .powderyMildew
        ))
    }

    /// Forgiving, but not loose: a different target is still a different
    /// target, and a partial word is not a match.
    @Test("Chip selection does not match a different or partial target")
    func selectionMatchingIsNotLoose() {
        #expect(!ChemicalTargetSuggestionPolicy.matches(
            targetRaw: "Downy Mildew",
            target: .powderyMildew
        ))
        #expect(!ChemicalTargetSuggestionPolicy.matches(
            targetRaw: "Powdery",
            target: .powderyMildew
        ))
        #expect(!ChemicalTargetSuggestionPolicy.matches(
            targetRaw: "",
            target: .powderyMildew
        ))
    }

    /// At most one chip can read as selected, so the row can never suggest a
    /// use carries two targets at once.
    @Test("Only one chip is selected for a given target")
    func onlyOneChipIsSelected() {
        let selected = SprayTarget.allCases.filter {
            ChemicalTargetSuggestionPolicy.matches(targetRaw: "Botrytis", target: $0)
        }
        #expect(selected.count <= 1)
    }
}
