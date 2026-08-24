import Foundation
import Testing
@testable import VineTrack

/// The casing rule for chemical product names.
///
/// These fixtures are deliberately the SAME fixtures asserted by
/// `sql/tests/205_chemical_display_name_casing_tests.sql`. The database
/// function `public.vt_display_chemical_name(text)` is the source of truth —
/// a trigger on `saved_chemicals` applies it to every write from every
/// client — and `ChemicalDisplayName` exists only so an offline-first save
/// reads the same before it has ever reached Supabase. Pinning both to one set
/// of cases is what stops the two drifting.
struct ChemicalDisplayNameTests {

    // MARK: - Register capitals become readable

    @Test
    func shoutedRegisterNamesBecomeWords() {
        #expect(
            ChemicalDisplayName.cased("DITHANE RAINSHIELD NEO TEC FUNGICIDE")
                == "Dithane Rainshield Neo Tec Fungicide"
        )
        #expect(ChemicalDisplayName.cased("CUSTODIA FORTE FUNGICIDE") == "Custodia Forte Fungicide")
        #expect(
            ChemicalDisplayName.cased("SPRAYSEAL PRUNING WOUND TREATMENT")
                == "Sprayseal Pruning Wound Treatment"
        )
    }

    // MARK: - Capitals that carry meaning survive

    @Test
    func formulationCodesStayCapitals() {
        // EC and EO carry a vowel, so these only pass because the code list is
        // consulted BEFORE the no-vowel test. The first cut of this rule leaned
        // on "no vowel means it is a code" alone and produced "Topas 100 Ec".
        #expect(ChemicalDisplayName.cased("TOPAS 100 EC") == "Topas 100 EC")
        #expect(ChemicalDisplayName.cased("SUPERWAY GLYPHOSATE EO") == "Superway Glyphosate EO")
        // No vowel at all: covered by the general test.
        #expect(ChemicalDisplayName.cased("COPPER OXYCHLORIDE WG") == "Copper Oxychloride WG")
        #expect(ChemicalDisplayName.cased("MANCOZEB DF") == "Mancozeb DF")
        // Three-letter codes and acronym actives.
        #expect(ChemicalDisplayName.cased("GLYPHOSATE ULV") == "Glyphosate ULV")
        #expect(ChemicalDisplayName.cased("MCPA 750") == "MCPA 750")
    }

    @Test
    func anythingWithADigitIsKeptVerbatim() {
        #expect(ChemicalDisplayName.cased("PENNCOZEB 750DF") == "Penncozeb 750DF")
        #expect(ChemicalDisplayName.cased("CAVALIER 500SC") == "Cavalier 500SC")
        #expect(ChemicalDisplayName.cased("CONAN STICKS 720SC") == "Conan Sticks 720SC")
    }

    @Test
    func hyphenatedNamesAreCasedPartByPart() {
        // The single-letter D of an active's common name survives.
        #expect(ChemicalDisplayName.cased("2,4-D AMINE 625") == "2,4-D Amine 625")
        #expect(ChemicalDisplayName.cased("ROUND-UP ATTACK") == "Round-Up Attack")
    }

    // MARK: - Lower case is sacred

    @Test
    func anyLowerCaseLetterMeansHandsOff() {
        // A manufacturer's own styling.
        #expect(ChemicalDisplayName.cased("Kocide Blue Xtra") == "Kocide Blue Xtra")
        // A genuine acronym inside an already-cased name is not flattened.
        #expect(ChemicalDisplayName.cased("BASF Something Xtra") == "BASF Something Xtra")
        // Wording the operator typed on purpose, spacing and all.
        #expect(ChemicalDisplayName.cased("my shed  mix") == "my shed  mix")
        #expect(ChemicalDisplayName.cased("pHix") == "pHix")
    }

    @Test
    func emptyAndBlankAreReturnedUnchanged() {
        #expect(ChemicalDisplayName.cased("") == "")
        #expect(ChemicalDisplayName.cased("   ") == "   ")
    }

    @Test
    func whitespaceIsTidiedOnlyOnANameBeingRewritten() {
        #expect(ChemicalDisplayName.cased("  KOCIDE   BLUE  ") == "Kocide Blue")
    }

    @Test
    func ruleIsIdempotent() {
        for name in ["DITHANE RAINSHIELD NEO TEC FUNGICIDE", "TOPAS 100 EC", "2,4-D AMINE 625"] {
            let once = ChemicalDisplayName.cased(name)
            #expect(ChemicalDisplayName.cased(once) == once)
        }
    }

    // MARK: - The review draft stores the readable name

    /// A register name that nothing else restated used to be saved shouting.
    /// The draft now carries the same casing the database would apply, so the
    /// record reads identically offline and after sync.
    @Test
    func reviewDraftStoresTheReadableName() {
        let review = ChemicalReviewMerge.reviewChemical(
            lookup: nil,
            selected: ChemicalSearchResult(
                name: "DITHANE RAINSHIELD NEO TEC FUNGICIDE",
                activeIngredient: "Mancozeb 750 g/kg",
                chemicalGroup: "M3",
                brand: "UPL AUSTRALIA PTY LTD",
                primaryUse: "Downy Mildew (Grapevines)"
            ),
            existing: nil,
            countryCode: "AU",
            vineyardId: UUID()
        )

        #expect(review.name == "Dithane Rainshield Neo Tec Fungicide")
        // The registrant is NOT re-cased: company names are full of genuine
        // acronyms this rule would wrongly turn into words.
        #expect(review.manufacturer == "UPL AUSTRALIA PTY LTD")
    }
}
