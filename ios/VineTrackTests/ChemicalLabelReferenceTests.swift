import Foundation
import Testing
@testable import VineTrack

/// ONE Official Label link, resolved from every place the response can state it.
///
/// The defect these tests lock down: the Review screen's Official Label field
/// stayed blank on lookups that had genuinely located the label document. The
/// backend states a label address in more than one place by design — the
/// register portal's confirmed document URL lands in
/// `registration.label_reference`, and a completed extraction pass reports the
/// document it actually read in `label_extraction.document_url` — and iOS
/// decoded only the first. A response carrying the second reached the operator
/// with an empty field while the URL sat in the payload, decoded by nobody.
///
/// "No label was returned" and "a label was returned and we dropped it" must
/// never look the same on screen, so these tests assert BOTH the URL and the
/// tier that supplied it.
struct ChemicalLabelReferenceTests {

    private static let vineyardId = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!

    private func decode(_ json: String) throws -> ChemicalStructuredLookup {
        try JSONDecoder().decode(ChemicalStructuredLookup.self, from: Data(json.utf8))
    }

    /// A register-RESOLVED Dithane-shaped response. `registration` fields and
    /// the envelope keys are filled in per test through string interpolation of
    /// the two label-bearing slots.
    private func lookupJSON(
        labelReference: String? = nil,
        labelProvenance: String? = nil,
        labelExtractionURL: String? = nil,
        sources: String = "[]"
    ) -> String {
        let reference = labelReference.map { "\"\($0)\"" } ?? "null"
        let provenance = labelProvenance.map {
            "\"field_provenance\": { \"label_reference\": \"\($0)\" },"
        } ?? ""
        let extraction = labelExtractionURL.map {
            """
            "label_extraction": {
              "document_url": "\($0)",
              "document_sha256": "abc123",
              "parser_version": "1"
            },
            """
        } ?? ""
        return """
        {
          "product_name": "DITHANE RAINSHIELD NEOTEC FUNGICIDE",
          "product_category": "Fungicide",
          "form_type": "Water dispersible granule",
          "registration": {
            "country_code": "AU",
            "scheme": "apvma",
            "registration_number": "34540",
            "registrant": "Corteva Agriscience Australia Pty Ltd",
            "registered_product_name": "DITHANE RAINSHIELD NEOTEC FUNGICIDE",
            "label_reference": \(reference)
          },
          "active_ingredients": [
            { "name": "Mancozeb", "concentration": 750, "concentration_unit": "g/kg" }
          ],
          "registered_uses": [],
          \(extraction)
          \(provenance)
          "verification": {
            "status": "partially_verified",
            "sources": \(sources),
            "conflicts": [],
            "unresolved_fields": []
          },
          "match_source": "authoritative_candidate"
        }
        """
    }

    private func merged(_ lookup: ChemicalStructuredLookup?, existing: SavedChemical? = nil)
        -> SavedChemical
    {
        ChemicalReviewMerge.reviewChemical(
            lookup: lookup,
            selected: ChemicalSearchResult(name: "Dithane Rainshield"),
            existing: existing,
            countryCode: "AU",
            vineyardId: Self.vineyardId
        )
    }

    // MARK: - 1. registration.label_reference populates Official Label

    @Test("registration.label_reference populates the Official Label field")
    func registrationLabelReferencePopulatesOfficialLabel() throws {
        let lookup = try decode(
            lookupJSON(labelReference: "https://elabels.apvma.gov.au/34540ELBL.pdf")
        )
        let choice = try #require(
            ChemicalLabelReference.resolve(
                lookup: lookup, existingStructured: nil, existingRecordURL: nil
            )
        )
        #expect(choice.url == "https://elabels.apvma.gov.au/34540ELBL.pdf")
        #expect(choice.origin == .structuredRegistration)

        // And it reaches the ONE visible field, through the merge and the
        // session the Review screen actually binds to.
        let draft = merged(lookup)
        let session = ChemicalReviewSession.make(
            chemical: nil, prefill: draft, fallbackCountry: "AU"
        )
        #expect(session.labelURL == "https://elabels.apvma.gov.au/34540ELBL.pdf")
        #expect(draft.chemicalIntelligence?.registration?.labelReference
                == "https://elabels.apvma.gov.au/34540ELBL.pdf")
    }

    // MARK: - 2. register label_document.url reaches Official Label

    @Test("A register-confirmed label document outranks every weaker tier")
    func registerConfirmedDocumentWins() throws {
        // Stage LD-1: the portal's confirmed document URL is served AS
        // `registration.label_reference` with authoritative provenance. It must
        // beat an extraction URL and an older value on the record.
        let lookup = try decode(lookupJSON(
            labelReference: "https://elabels.apvma.gov.au/34540ELBL.pdf",
            labelProvenance: "manufacturer_label",
            labelExtractionURL: "https://elabels.apvma.gov.au/older-34540.pdf"
        ))
        let choice = try #require(
            ChemicalLabelReference.resolve(
                lookup: lookup,
                existingStructured: "https://stale.example.test/label.pdf",
                existingRecordURL: "https://older.example.test/label.pdf"
            )
        )
        #expect(choice.url == "https://elabels.apvma.gov.au/34540ELBL.pdf")
        #expect(choice.origin == .registerConfirmedDocument)
    }

    // MARK: - 3. label_extraction.document_url reaches Official Label

    @Test("label_extraction.document_url fills the field when the register found no document")
    func labelExtractionDocumentReachesOfficialLabel() throws {
        // THE regression: document discovery came back empty, the extraction
        // pass did not. The URL was in the response the whole time and iOS
        // never decoded the key it arrived under.
        let lookup = try decode(lookupJSON(
            labelReference: nil,
            labelExtractionURL: "https://elabels.apvma.gov.au/34540ELBL.pdf"
        ))
        #expect(lookup.labelExtraction?.documentURL == "https://elabels.apvma.gov.au/34540ELBL.pdf")

        let choice = try #require(
            ChemicalLabelReference.resolve(
                lookup: lookup, existingStructured: nil, existingRecordURL: nil
            )
        )
        #expect(choice.url == "https://elabels.apvma.gov.au/34540ELBL.pdf")
        #expect(choice.origin == .labelExtractionDocument)

        let session = ChemicalReviewSession.make(
            chemical: nil, prefill: merged(lookup), fallbackCountry: "AU"
        )
        #expect(session.labelURL == "https://elabels.apvma.gov.au/34540ELBL.pdf")
    }

    // MARK: - 4. Manufacturer-label evidence, only when it is a label

    @Test("A manufacturer-label source is used only when its reference is a label document")
    func manufacturerLabelEvidenceUsedOnlyWhenItIsALabel() throws {
        let labelSource = """
        [{
          "kind": "manufacturer_label",
          "name": "Approved label",
          "reference": "https://cdn.corteva.com/labels/dithane-rainshield-neotec.pdf"
        }]
        """
        let realLabel = try decode(lookupJSON(sources: labelSource))
        let choice = try #require(
            ChemicalLabelReference.resolve(
                lookup: realLabel, existingStructured: nil, existingRecordURL: nil
            )
        )
        #expect(choice.url == "https://cdn.corteva.com/labels/dithane-rainshield-neotec.pdf")
        #expect(choice.origin == .labelEvidenceSource)

        // Same source KIND, but the reference is the brand's product page. A
        // label-kind citation does not make a brochure a label.
        let brochureSource = """
        [{
          "kind": "manufacturer_label",
          "name": "Product information",
          "reference": "https://www.corteva.com.au/dithane-rainshield-neotec.html"
        }]
        """
        let brochure = try decode(lookupJSON(sources: brochureSource))
        #expect(ChemicalLabelReference.resolve(
            lookup: brochure, existingStructured: nil, existingRecordURL: nil
        ) == nil)

        // And an AI-interpretation source citing a genuine-looking PDF is not
        // label EVIDENCE, whatever the URL looks like.
        let aiSource = """
        [{
          "kind": "ai_interpretation",
          "name": "Search reading",
          "reference": "https://random.example.test/labels/something.pdf"
        }]
        """
        let ai = try decode(lookupJSON(sources: aiSource))
        #expect(ChemicalLabelReference.resolve(
            lookup: ai, existingStructured: nil, existingRecordURL: nil
        ) == nil)
    }

    // MARK: - 5. A marketing page is never the Official Label

    @Test("A generic product or marketing URL never becomes the Official Label")
    func marketingURLNeverBecomesOfficialLabel() throws {
        for marketing in [
            "https://www.corteva.com.au/products/dithane-rainshield.html",
            "https://www.corteva.com.au",
            "https://www.corteva.com.au/",
            "https://www.corteva.com.au/search?q=dithane",
            "https://www.corteva.com.au/category/fungicides"
        ] {
            #expect(!ChemicalLabelReference.looksLikeLabelDocument(marketing),
                    "\(marketing) must not read as a label document")
            let lookup = try decode(lookupJSON(labelReference: marketing))
            #expect(ChemicalLabelReference.resolve(
                lookup: lookup, existingStructured: nil, existingRecordURL: nil
            ) == nil, "\(marketing) reached the Official Label field")
        }

        // The Product Page field still exists for exactly these URLs — the
        // point is that they never occupy the LABEL field.
        #expect(ChemicalLabelReference.looksLikeLabelDocument(
            "https://elabels.apvma.gov.au/34540ELBL.pdf"))
        #expect(ChemicalLabelReference.looksLikeLabelDocument(
            "https://cdn.example.test/labels/product.pdf"))
    }

    // MARK: - 6. Save → reload retains the Official Label

    @Test("Save and reopen keeps the same Official Label URL")
    func saveAndReloadRetainsOfficialLabel() throws {
        let lookup = try decode(lookupJSON(
            labelReference: "https://elabels.apvma.gov.au/34540ELBL.pdf",
            labelProvenance: "manufacturer_label"
        ))
        var draft = merged(lookup)
        var session = ChemicalReviewSession.make(
            chemical: nil, prefill: draft, fallbackCountry: "AU"
        )
        #expect(session.labelURL == "https://elabels.apvma.gov.au/34540ELBL.pdf")

        // Save: the structured record is what persists.
        let persisted = try #require(session.intelligenceToPersist)
        draft.chemicalIntelligence = persisted
        draft.labelURL = session.legacyProjection().labelURL

        // Reload across the wire.
        let data = try JSONEncoder().encode(persisted)
        let reloaded = try JSONDecoder().decode(ChemicalIntelligence.self, from: data)
        #expect(reloaded.registration?.labelReference
                == "https://elabels.apvma.gov.au/34540ELBL.pdf")

        var stored = draft
        stored.chemicalIntelligence = reloaded
        let reopened = ChemicalReviewSession.make(
            chemical: stored, prefill: nil, fallbackCountry: "AU"
        )
        #expect(reopened.labelURL == "https://elabels.apvma.gov.au/34540ELBL.pdf")

        // A later lookup that finds NO label must not erase the saved one.
        let empty = try decode(lookupJSON())
        let rematched = merged(empty, existing: stored)
        #expect(rematched.chemicalIntelligence?.registration?.labelReference
                == "https://elabels.apvma.gov.au/34540ELBL.pdf")

        // Silence the unused-write warning while keeping the save shape honest.
        session.labelURL = reopened.labelURL
    }

    // MARK: - 7. Blank means "none returned", never "decoded and dropped"

    @Test("Blank means the response carried no label address at all")
    func blankMeansNoLabelWasReturned() throws {
        let bare = try decode(lookupJSON())
        // The diagnostic list is the proof: nothing to choose from, so nothing
        // was lost. This is the only honest reason the field can be empty.
        #expect(ChemicalLabelReference.candidates(
            lookup: bare, existingStructured: nil, existingRecordURL: nil
        ).isEmpty)
        #expect(ChemicalLabelReference.resolve(
            lookup: bare, existingStructured: nil, existingRecordURL: nil
        ) == nil)

        let session = ChemicalReviewSession.make(
            chemical: nil, prefill: merged(bare), fallbackCountry: "AU"
        )
        #expect(session.labelURL.isEmpty)

        // Whereas a response that DOES carry one must never present as blank —
        // the failure this whole type exists to make impossible.
        let carrying = try decode(lookupJSON(
            labelExtractionURL: "https://elabels.apvma.gov.au/34540ELBL.pdf"
        ))
        #expect(!ChemicalLabelReference.candidates(
            lookup: carrying, existingStructured: nil, existingRecordURL: nil
        ).isEmpty)
        let carried = ChemicalReviewSession.make(
            chemical: nil, prefill: merged(carrying), fallbackCountry: "AU"
        )
        #expect(!carried.labelURL.isEmpty)
    }
}
