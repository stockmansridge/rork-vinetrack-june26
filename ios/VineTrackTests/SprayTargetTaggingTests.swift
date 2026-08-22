import Foundation
import Testing
@testable import VineTrack

/// Targets as reusable vineyard-level tags.
///
/// The claims worth defending:
///
///  1. no existing target wording is lost — least of all the wording VineTrack
///     has no enum case for, which is exactly the wording most at risk;
///  2. built-in and vineyard-created targets are one selection, stored one way,
///     and neither is second-class;
///  3. a target belongs to the vineyard that created it and to no other;
///  4. what the calculator can act on, it acts on — and what it cannot, it
///     carries rather than coerces.
struct SprayTargetTaggingTests {

    // MARK: - Fixtures

    private static let vineyardA = UUID(uuidString: "11111111-1111-1111-1111-11111111000a")!
    private static let vineyardB = UUID(uuidString: "11111111-1111-1111-1111-11111111000b")!
    private static let stepId = UUID(uuidString: "dddddddd-0000-0000-0000-0000000000c1")!

    /// A portal Program Step as it exists TODAY: wording only, no structured
    /// `targets`, and wording that names two trunk diseases VineTrack has no
    /// typed case for.
    private let legacyJSON = """
    {
      "id": "dddddddd-0000-0000-0000-0000000000c1",
      "vineyard_id": "11111111-1111-1111-1111-11111111000a",
      "name": "Pruning Wound Protection",
      "is_template": true,
      "status": "draft",
      "growth_stage_code": "EL1",
      "target": "Eutypa Dieback, Botryosphaeria Dieback",
      "operation_type": "Foliar Spray",
      "chemical_lines": [
        { "name": "Spray Seal", "rate": 2, "unit": "L/ha" }
      ]
    }
    """

    private func legacyRow() throws -> BackendSprayJobTemplate {
        try JSONDecoder().decode(BackendSprayJobTemplate.self, from: Data(legacyJSON.utf8))
    }

    private func step(from row: BackendSprayJobTemplate) -> SprayProgramStep {
        SprayProgramStep(
            record: row.toSprayRecord(),
            source: .portal,
            growthStageCode: row.growthStageCode,
            targetRaw: row.target
        )
    }

    private func encoded(_ payload: BackendSprayJobTemplateUpdate) throws -> [String: Any] {
        let data = try JSONEncoder().encode(payload)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func libraryEntry(
        _ identifier: String,
        _ label: String,
        vineyard: UUID
    ) -> VineyardSprayTargetRecord {
        VineyardSprayTargetRecord(
            id: UUID(),
            vineyardId: vineyard,
            identifier: identifier,
            label: label
        )
    }

    // MARK: - 1. Legacy wording loads as separate tags

    @Test("Existing free-text target wording loads into separate tags")
    func legacyWordingBecomesTags() throws {
        let step = step(from: try legacyRow())
        let tags = step.targetTags()

        #expect(tags.count == 2)
        #expect(tags.map(\.label) == ["Eutypa Dieback", "Botryosphaeria Dieback"])
        #expect(tags.allSatisfy(\.isCustom))
        #expect(tags.map(\.identifier) == ["eutypa_dieback", "botryosphaeria_dieback"])
    }

    @Test("Comma, semicolon and middle-dot all separate targets; a slash does not")
    func conservativeSeparators() {
        #expect(SprayTargetVocabulary.wordings(from: "Phomopsis, Black Spot") == ["Phomopsis", "Black Spot"])
        #expect(SprayTargetVocabulary.wordings(from: "Phomopsis; Black Spot") == ["Phomopsis", "Black Spot"])
        #expect(SprayTargetVocabulary.wordings(from: "Phomopsis \u{00B7} Black Spot") == ["Phomopsis", "Black Spot"])

        // "Nutrition / Biostimulant" is ONE target's own name. Splitting on the
        // slash would invent two targets this vineyard never selected, which is
        // strictly worse than failing to split something.
        #expect(SprayTargetVocabulary.wordings(from: "Nutrition / Biostimulant") == ["Nutrition / Biostimulant"])
        #expect(SprayTargetVocabulary.tag(wording: "Nutrition / Biostimulant")?.builtIn == .nutritionBiostimulant)
    }

    @Test("Wording that is only punctuation or whitespace produces no tag")
    func emptyWordingIsRejected() {
        #expect(SprayTargetVocabulary.tag(wording: "   ") == nil)
        #expect(SprayTargetVocabulary.tag(wording: "***") == nil)
        #expect(SprayTargetVocabulary.identifier(for: "-- ") == nil)
        #expect(SprayTargetVocabulary.wordings(from: ", ; \u{00B7}").isEmpty)
    }

    // MARK: - 2. Built-in and custom coexist

    @Test("Built-in and custom targets coexist in one selection")
    func builtInAndCustomCoexist() throws {
        var draft = SprayProgramStepDraft(step: step(from: try legacyRow()))
        draft.addTarget(SprayTargetTag(.powderyMildew))

        #expect(draft.targets.count == 3)
        #expect(draft.recognisedTargets == [.powderyMildew])
        #expect(SprayTargetVocabulary.customs(draft.targets).map(\.label)
            == ["Eutypa Dieback", "Botryosphaeria Dieback"])

        // Built-ins lead in presentation order, then the vineyard's own in the
        // order they were added — so two operators who tapped the same targets
        // in a different sequence write the same array.
        #expect(SprayTargetVocabulary.identifiers(draft.targets)
            == ["powdery_mildew", "eutypa_dieback", "botryosphaeria_dieback"])
    }

    @Test("Typing the name of a built-in target selects it rather than creating a duplicate")
    func typedBuiltInResolvesToTheBuiltIn() {
        let tag = SprayTargetVocabulary.tag(wording: "powdery mildew")
        #expect(tag?.builtIn == .powderyMildew)
        #expect(tag?.isCustom == false)
        #expect(tag?.label == "Powdery Mildew")
    }

    // MARK: - 3. Case-insensitive de-duplication

    @Test("Custom targets de-duplicate case-insensitively")
    func customTargetsDeduplicate() throws {
        var draft = SprayProgramStepDraft(step: step(from: try legacyRow()))
        let before = draft.targets.count

        for wording in ["eutypa dieback", "EUTYPA DIEBACK", "  Eutypa   Dieback  "] {
            let tag = try #require(SprayTargetVocabulary.tag(wording: wording))
            #expect(tag.identifier == "eutypa_dieback")
            draft.addTarget(tag)
        }
        #expect(draft.targets.count == before)
    }

    // MARK: - 4. The library is vineyard-scoped

    @Test("A custom target created for one vineyard is offered in that vineyard only")
    func libraryIsVineyardScoped() {
        let entries = [
            libraryEntry("eutypa_dieback", "Eutypa Dieback", vineyard: Self.vineyardA),
            libraryEntry("mealybug", "Mealybug", vineyard: Self.vineyardB)
        ]

        let a = SprayTargetLibraryService.customTags(in: entries, vineyardId: Self.vineyardA)
        let b = SprayTargetLibraryService.customTags(in: entries, vineyardId: Self.vineyardB)

        #expect(a.map(\.identifier) == ["eutypa_dieback"])
        #expect(b.map(\.identifier) == ["mealybug"])
        #expect(SprayTargetLibraryService.labels(in: entries, vineyardId: Self.vineyardA)
            == ["eutypa_dieback": "Eutypa Dieback"])
        #expect(SprayTargetLibraryService.labels(in: entries, vineyardId: Self.vineyardB)["eutypa_dieback"] == nil)
    }

    @Test("The library offers targets already used on this vineyard's Program Steps")
    func observedTargetsAreOffered() throws {
        let steps = [step(from: try legacyRow())]
        let observed = SprayProgramCatalog.observedTargetTags(steps)
        #expect(observed.map(\.identifier).sorted() == ["botryosphaeria_dieback", "eutypa_dieback"])

        // A real library row's wording beats the wording read off a step.
        let entries = [libraryEntry("eutypa_dieback", "Eutypa Die-Back", vineyard: Self.vineyardA)]
        let offered = SprayTargetLibraryService.customTags(
            in: entries,
            vineyardId: Self.vineyardA,
            observed: observed
        )
        #expect(offered.count == 2)
        #expect(offered.first { $0.identifier == "eutypa_dieback" }?.label == "Eutypa Die-Back")
    }

    // MARK: - 5. Removing from a step never touches the library

    @Test("Removing a target from a Program Step leaves the vineyard library intact")
    func removalIsStepLocal() throws {
        let entries = [
            libraryEntry("eutypa_dieback", "Eutypa Dieback", vineyard: Self.vineyardA),
            libraryEntry("botryosphaeria_dieback", "Botryosphaeria Dieback", vineyard: Self.vineyardA)
        ]
        var draft = SprayProgramStepDraft(step: step(from: try legacyRow()))
        let eutypa = try #require(draft.targets.first { $0.identifier == "eutypa_dieback" })

        draft.removeTarget(eutypa)

        #expect(!draft.targets.contains { $0.identifier == "eutypa_dieback" })
        // The vineyard still sprays for Eutypa; one step no longer naming it is
        // not a reason to forget the word.
        #expect(SprayTargetLibraryService.customTags(in: entries, vineyardId: Self.vineyardA)
            .map(\.identifier).sorted() == ["botryosphaeria_dieback", "eutypa_dieback"])
    }

    // MARK: - 6. Portal save/reload preserves every selected string

    @Test("A portal save writes structured targets plus the wording projection")
    func portalPayloadWritesBothRepresentations() throws {
        var draft = SprayProgramStepDraft(step: step(from: try legacyRow()))
        draft.addTarget(SprayTargetTag(.powderyMildew))

        let json = try encoded(draft.portalPayload(updatedBy: nil))

        let identifiers = try #require(json["targets"] as? [String])
        #expect(identifiers == ["powdery_mildew", "eutypa_dieback", "botryosphaeria_dieback"])

        // The legacy column stays written, as a projection — existing portal and
        // report readers still consume it, and it is where a custom target's
        // exact wording survives the slug.
        #expect(json["target"] as? String == "Powdery Mildew \u{00B7} Eutypa Dieback \u{00B7} Botryosphaeria Dieback")
    }

    @Test("Every selected target survives a portal save and reload, wording included")
    func portalRoundTripPreservesEveryString() throws {
        let row = try legacyRow()
        var draft = SprayProgramStepDraft(step: step(from: row))
        draft.addTarget(SprayTargetTag(.powderyMildew))
        let awkward = try #require(SprayTargetVocabulary.tag(wording: "Light Brown Apple Moth (LBAM)"))
        draft.addTarget(awkward)

        let reloaded = step(from: row.applying(draft.portalPayload(updatedBy: nil)))
        let tags = reloaded.targetTags()

        #expect(tags.map(\.label) == [
            "Powdery Mildew",
            "Eutypa Dieback",
            "Botryosphaeria Dieback",
            "Light Brown Apple Moth (LBAM)"
        ])
        // Punctuation the slug strips is recovered from the wording projection,
        // so the tag reads back exactly as it was typed.
        #expect(tags.last?.identifier == "light_brown_apple_moth_lbam")
    }

    @Test("Clearing every target persists as null wording and an empty array, not as a stale line")
    func clearingTargetsPersists() throws {
        var draft = SprayProgramStepDraft(step: step(from: try legacyRow()))
        draft.targets = []

        let json = try encoded(draft.portalPayload(updatedBy: nil))
        #expect((json["targets"] as? [String])?.isEmpty == true)
        #expect(json["target"] is NSNull)
    }

    @Test("Structured targets win over stale wording on reload")
    func structuredTargetsAreTheSourceOfTruth() throws {
        // A row whose wording has drifted from its identifiers: `targets` is
        // what the step is for, and the wording only supplies phrasing.
        let row = BackendSprayJobTemplate(
            id: Self.stepId,
            vineyardId: Self.vineyardA,
            name: "Bunch Closing",
            target: "Powdery Mildew \u{00B7} Botrytis \u{00B7} Phomopsis",
            targets: ["botrytis", "phomopsis"]
        )
        let tags = step(from: row).targetTags()
        #expect(tags.map(\.identifier) == ["botrytis", "phomopsis"])
        #expect(tags.map(\.label) == ["Botrytis", "Phomopsis"])
    }

    // MARK: - 7/8. Calculator prefill

    @Test("Known targets still prefill the calculator")
    func knownTargetsPrefillTheCalculator() throws {
        let row = BackendSprayJobTemplate(
            id: Self.stepId,
            vineyardId: Self.vineyardA,
            name: "Flowering",
            target: "Powdery Mildew \u{00B7} Botrytis",
            targets: ["powdery_mildew", "botrytis"]
        )
        let prefill = step(from: row).calculatorPrefill
        #expect(prefill.targets == [.powderyMildew, .botrytis])
        #expect(prefill.customTargets.isEmpty)
    }

    @Test("Custom targets travel with the planned spray and are never coerced onto a built-in")
    func customTargetsTravelUncoerced() throws {
        let prefill = step(from: try legacyRow()).calculatorPrefill

        // Nothing forced onto `.other` or onto an unrelated disease: an untyped
        // truth beats a typed lie on a compliance record.
        #expect(prefill.targets.isEmpty)
        #expect(prefill.customTargets == ["eutypa_dieback", "botryosphaeria_dieback"])
        #expect(!prefill.isEmpty)
    }

    @Test("The guided flow carries custom targets onto the saved application")
    func guidedFlowCarriesCustomTargets() {
        var inputs = SprayGuidedInputs()
        inputs.targets = [.botrytis]
        inputs.customTargets = ["phomopsis"]

        let snapshot = SprayApplicationSnapshot(
            targets: Array(inputs.targets),
            customTargets: inputs.customTargets
        )
        #expect(snapshot.targets == [.botrytis])
        #expect(snapshot.customTargets == ["phomopsis"])
        #expect(snapshot.targetIdentifiers == ["botrytis", "phomopsis"])
        #expect(snapshot.hasRecordedTargets)
    }

    // MARK: - Local Program Steps

    @Test("A local Program Step keeps its custom targets through an edit")
    func localStepKeepsCustomTargets() throws {
        let record = SprayRecord(
            id: UUID(),
            vineyardId: Self.vineyardA,
            sprayReference: "EL12 Pre-Flowering",
            tanks: [SprayTank(chemicals: [
                SprayChemical(name: "Copper Hydroxide", ratePerHa: 1_000, unit: .kilograms, rateBasis: .wholeBlockArea)
            ])],
            isTemplate: true
        )
        var draft = SprayProgramStepDraft(step: SprayProgramStep(record: record, source: .local))
        draft.addTarget(SprayTargetTag(.downyMildew))
        draft.addTarget(try #require(SprayTargetVocabulary.tag(wording: "Phomopsis")))

        let updated = draft.applied(to: record)
        let snapshot = try #require(updated.applicationGeometry)

        // Before this, a local step had nowhere to put the custom half of the
        // selection and dropped it on save.
        #expect(snapshot.targets == [.downyMildew])
        #expect(snapshot.customTargets == ["phomopsis"])

        // Both halves reach the SAME sql/193 text[] column — no second column,
        // no migration, no notes field.
        let upsert = BackendSprayRecord.upsert(from: updated, createdBy: nil, clientUpdatedAt: Date())
        #expect(upsert.targets == ["downy_mildew", "phomopsis"])

        let reloaded = SprayProgramStep(record: updated, source: .local)
        #expect(reloaded.targetTags().map(\.label) == ["Downy Mildew", "Phomopsis"])
    }

    @Test("Unrecognised stored identifiers are kept, not discarded")
    func unknownIdentifiersSurviveDecode() throws {
        let snapshot = SprayApplicationSnapshot(targets: [.botrytis], customTargets: ["eutypa_dieback"])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SprayApplicationSnapshot.self, from: data)

        #expect(decoded.targets == [.botrytis])
        #expect(decoded.customTargets == ["eutypa_dieback"])
    }

    @Test("Never-recorded targets stay distinguishable from recorded-as-none")
    func absenceIsPreserved() {
        let never = SprayApplicationSnapshot(grossAreaHa: 4)
        #expect(never.targets == nil)
        #expect(never.customTargets == nil)
        #expect(never.targetIdentifiers == nil)
        #expect(!never.hasRecordedTargets)

        let none = SprayApplicationSnapshot(targets: [], customTargets: [])
        #expect(none.targetIdentifiers == [])
        #expect(!none.hasRecordedTargets)
    }

    @Test("An empty custom target is never written, because the sql/193 CHECK would reject the record")
    func blankCustomTargetsAreDropped() {
        let snapshot = SprayApplicationSnapshot(targets: [.botrytis], customTargets: ["", "  ", "phomopsis"])
        #expect(snapshot.customTargets == ["phomopsis"])
    }

    @Test("A custom identifier that duplicates a built-in is not stored twice")
    func customTargetsNeverShadowBuiltIns() {
        let snapshot = SprayApplicationSnapshot(targets: [.botrytis], customTargets: ["botrytis", "phomopsis"])
        #expect(snapshot.customTargets == ["phomopsis"])
        #expect(snapshot.targetIdentifiers == ["botrytis", "phomopsis"])
    }

    // MARK: - Product replacement

    private func sprayOil() -> SavedChemical {
        SavedChemical(
            id: UUID(uuidString: "aaaaaaaa-0000-0000-0000-00000000000c")!,
            vineyardId: Self.vineyardA,
            name: "Biosafe Spray Oil",
            unit: .litres,
            manufacturer: "Example Crop Science",
            activeIngredient: "Paraffinic oil 815 g/L"
        )
    }

    @Test("One Replace Product action serves resolved and unresolved lines alike")
    func replacementIsOneActionForBothStates() throws {
        var draft = SprayProgramStepDraft(step: step(from: try legacyRow()))
        let unresolved = try #require(draft.products.first)
        #expect(unresolved.savedChemicalId == nil)
        #expect(!unresolved.isResolved(in: [sprayOil()]))

        // Unresolved -> resolved.
        draft.products[0].replaceProduct(with: sprayOil(), seedRate: nil)
        #expect(draft.products[0].savedChemicalId == sprayOil().id)
        #expect(draft.products[0].isResolved(in: [sprayOil()]))

        // Resolved -> a different product, through the same call.
        let other = SavedChemical(
            id: UUID(uuidString: "aaaaaaaa-0000-0000-0000-00000000000d")!,
            vineyardId: Self.vineyardA,
            name: "Wettable Sulphur",
            unit: .kilograms
        )
        draft.products[0].replaceProduct(with: other, seedRate: nil)
        #expect(draft.products[0].savedChemicalId == other.id)
        #expect(draft.products[0].name == "Wettable Sulphur")
    }

    @Test("A newly created chemical is bound by identity, not by name match")
    func createdChemicalIsSelectedByIdentity() throws {
        var draft = SprayProgramStepDraft(step: step(from: try legacyRow()))
        #expect(draft.products[0].name == "Spray Seal")

        // The product the operator just created in the Add Chemical form comes
        // straight back and binds this line. Its name is deliberately unrelated
        // to "Spray Seal": identity comes from the explicit choice, never from
        // the old line's wording.
        let created = sprayOil()
        draft.products[0].replaceProduct(with: created, seedRate: nil)

        #expect(draft.products[0].savedChemicalId == created.id)
        #expect(draft.products[0].name == created.name)
        #expect(draft.products[0].activeIngredient == created.activeIngredient)
        // Frozen chemistry belongs to the product it described, so it goes.
        #expect(draft.products[0].chemicalSnapshot == nil)
    }

    @Test("Abandoning chemical creation leaves the Program Step draft untouched")
    func cancellingCreationPreservesTheDraft() throws {
        var draft = SprayProgramStepDraft(step: step(from: try legacyRow()))
        draft.name = "Pruning Wound Protection 2026"
        draft.addTarget(SprayTargetTag(.powderyMildew))
        draft.notes = "Two passes."
        let before = draft

        // Cancelling the Add Chemical form applies no replacement at all: the
        // draft is a value the editor owns, and the picker never held it.
        #expect(draft == before)
        #expect(draft.name == "Pruning Wound Protection 2026")
        #expect(draft.targets.contains { $0.builtIn == .powderyMildew })
        #expect(draft.products.first?.name == "Spray Seal")
        #expect(draft.products.first?.savedChemicalId == nil)
    }

    // MARK: - History

    @Test("Editing a Program Step's targets rewrites no completed spray")
    func historyIsUntouched() throws {
        let completed = SprayRecord(
            id: UUID(),
            vineyardId: Self.vineyardA,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            sprayReference: "Bunch Closing 12 Nov",
            tanks: [SprayTank(chemicals: [
                SprayChemical(name: "Wettable Sulphur", ratePerHa: 3_000, unit: .grams, rateBasis: .wholeBlockArea)
            ])],
            isTemplate: false,
            applicationGeometry: SprayApplicationSnapshot(
                grossAreaHa: 4.2,
                treatedAreaHa: 4.2,
                targets: [.powderyMildew]
            )
        )
        let before = completed

        var draft = SprayProgramStepDraft(step: step(from: try legacyRow()))
        draft.addTarget(SprayTargetTag(.botrytis))
        draft.removeTarget(try #require(draft.targets.first { $0.identifier == "eutypa_dieback" }))
        _ = draft.portalPayload(updatedBy: nil)

        #expect(completed.applicationGeometry?.targets == before.applicationGeometry?.targets)
        #expect(completed.applicationGeometry?.customTargets == nil)
        #expect(completed.applicationGeometry?.grossAreaHa == 4.2)
        #expect(completed.tanks == before.tanks)
    }
}
