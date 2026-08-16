import Foundation
import Testing
@testable import VineTrack

/// The structured manual Chemical editor's actual behaviour.
///
/// These drive `ChemicalManualEntry` — the same object `ChemicalManualEditorView`
/// drives — rather than re-deriving the mapping, so a rule cannot pass here while
/// the screen does something else. The Android suite `ChemicalManualEntryTest`
/// asserts the same fixtures and the same outcomes.
///
/// Four properties are under protection:
///
///  1. A mixture is stored as N independent active→group relationships, never as
///     one combined `"3 + 11"` string.
///  2. Manual entry stays Unverified however completely it is filled in, and
///     becomes Conflict only when the reference table positively disagrees.
///  3. A draft read out of a record and written straight back is unchanged.
///  4. Commercial and operational fields are untouched by chemistry edits.
struct ChemicalManualEntryTests {

    private let at = Date(timeIntervalSince1970: 1_786_000_000)
    private let chemId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    // MARK: - Fixtures

    private func activeDraft(
        _ name: String,
        _ concentration: String = "",
        unit: ChemicalConcentrationUnit? = .gramsPerLitre,
        scheme: ChemicalActivityGroupScheme? = .frac,
        code: String = ""
    ) -> ChemicalManualActiveDraft {
        ChemicalManualActiveDraft(
            name: name,
            concentrationText: concentration,
            concentrationUnit: unit,
            scheme: scheme,
            groupCode: code
        )
    }

    /// Tebuconazole FRAC 3 + Azoxystrobin FRAC 11 — the canonical mixture.
    private func mixtureDraft() -> ChemicalManualDraft {
        ChemicalManualDraft(
            productName: "Custom Mix 300",
            countryCode: "AU",
            productCategory: "fungicide",
            registrant: "Example Crop Science",
            actives: [
                activeDraft("Tebuconazole", "200", code: "3"),
                activeDraft("Azoxystrobin", "120", code: "11"),
            ]
        )
    }

    private func savedFrom(
        _ intel: ChemicalIntelligence,
        name: String = "Custom Mix 300"
    ) -> SavedChemical {
        SavedChemical(
            id: chemId,
            name: name,
            chemicalGroup: intel.legacyChemicalGroup,
            manufacturer: intel.registration?.registrant ?? "",
            // Commercial and operational data the grower maintains. Present in
            // every fixture so any test that loses it fails loudly.
            notes: "Shed B, top shelf",
            activeIngredient: intel.legacyActiveIngredient,
            modeOfAction: "",
            productCategory: intel.productCategory,
            packSize: 10,
            pricePerPack: 425,
            inventoryQuantity: 3,
            applicationNotes: "Do not tank-mix with oil",
            isActive: true,
            chemicalIntelligence: intel
        )
    }

    // MARK: - Single active

    @Test("a manual single-active product is structured and unverified")
    func manualSingleActiveIsStructuredAndUnverified() throws {
        let draft = ChemicalManualDraft(
            productName: "Knockdown 360",
            countryCode: "AU",
            productCategory: "herbicide",
            actives: [activeDraft("Glyphosate", "360", scheme: .hrac, code: "G")]
        )

        let outcome = ChemicalManualEntry.outcome(for: draft, existing: nil, at: at)
        let active = try #require(outcome.intelligence.activeIngredients.first)

        #expect(outcome.intelligence.activeIngredients.count == 1)
        #expect(active.name == "Glyphosate")
        #expect(active.concentration == 360)
        #expect(active.concentrationUnit == .gramsPerLitre)
        #expect(active.activityGroup?.scheme == .hrac)
        #expect(active.activityGroup?.code == "G")
        // The single fact that keeps completeness from becoming trust.
        #expect(active.groupSource == .manualEntry)
        #expect(!active.hasAuthoritativeGroup)
        #expect(outcome.resolvedStatus == .unverified)
    }

    @Test("a manual single active survives save and reload")
    func manualSingleActiveSurvivesReload() throws {
        let outcome = ChemicalManualEntry.outcome(
            for: ChemicalManualDraft(
                productName: "Knockdown 360",
                countryCode: "AU",
                actives: [activeDraft("Glyphosate", "360", scheme: .hrac, code: "G")]
            ),
            existing: nil
        )
        let reloaded = ChemicalManualEntry.draft(
            from: savedFrom(outcome.intelligence, name: "Knockdown 360"),
            fallbackCountry: "NZ"
        )

        let active = try #require(reloaded.actives.first)
        #expect(reloaded.actives.count == 1)
        #expect(active.name == "Glyphosate")
        #expect(active.concentrationText == "360")
        #expect(active.scheme == .hrac)
        #expect(active.groupCode == "G")
        // The record's own country wins over the vineyard default on reload.
        #expect(reloaded.countryCode == "AU")
    }

    @Test("a manual product appears in the spray picker with its groups and status")
    func manualProductRendersInPicker() {
        let outcome = ChemicalManualEntry.outcome(for: mixtureDraft(), existing: nil)
        let saved = savedFrom(outcome.intelligence)

        // What the picker row renders: name, actives, derived groups, trust.
        #expect(saved.name == "Custom Mix 300")
        #expect(saved.legacyProjection.activeIngredient == "Tebuconazole 200 g/L + Azoxystrobin 120 g/L")
        #expect(saved.legacyProjection.chemicalGroup == "3 + 11")
        #expect(saved.activityGroupCodes == ["3", "11"])
        #expect(saved.verificationStatus == .unverified)
        // Unverified is not a reason to block use of a product the grower owns.
        #expect(!saved.resolvedIntelligence.isResistanceDependable)
    }

    // MARK: - Mixture

    @Test("a manual mixture keeps two independent active to group relationships")
    func manualMixtureKeepsTwoRelationships() {
        let outcome = ChemicalManualEntry.outcome(for: mixtureDraft(), existing: nil)
        let actives = outcome.intelligence.activeIngredients

        #expect(actives.count == 2)
        // Each relationship stands on its own. This is what `"3 + 11"` as a single
        // string could never express, and what resistance planning needs.
        #expect(actives[0].name == "Tebuconazole")
        #expect(actives[0].activityGroup?.code == "3")
        #expect(actives[1].name == "Azoxystrobin")
        #expect(actives[1].activityGroup?.code == "11")
        #expect(outcome.intelligence.activityGroupCodes == ["3", "11"])
    }

    @Test("the combined group string is derived for display only")
    func combinedGroupStringIsDerived() {
        #expect(ChemicalManualEntry.groupSummary(mixtureDraft()) == "FRAC 3 + 11")
        #expect(ChemicalManualEntry.activesSummary(mixtureDraft()) == "Tebuconazole + Azoxystrobin")
        // And the legacy column mirrors it without anything reading it back.
        let outcome = ChemicalManualEntry.outcome(for: mixtureDraft(), existing: nil)
        #expect(outcome.intelligence.legacyChemicalGroup == "3 + 11")
    }

    @Test("mixed schemes stay qualified in the summary")
    func mixedSchemesStayQualified() {
        let draft = ChemicalManualDraft(
            productName: "Odd Mix",
            actives: [
                activeDraft("Tebuconazole", code: "3"),
                activeDraft("Bifenthrin", scheme: .irac, code: "3"),
            ]
        )
        // "3 + 3" would read as one chemistry used twice. FRAC 3 and IRAC 3 are
        // unrelated, so the summary must not collapse them.
        let summary = ChemicalManualEntry.groupSummary(draft)
        #expect(summary.contains("FRAC 3"))
        #expect(summary.contains("IRAC 3"))
    }

    @Test("a mixture survives save, reload and re-save unchanged")
    func mixtureSurvivesRoundTrip() {
        let first = ChemicalManualEntry.outcome(for: mixtureDraft(), existing: nil)
        let saved = savedFrom(first.intelligence)

        let reloaded = ChemicalManualEntry.draft(from: saved, fallbackCountry: "AU")
        #expect(reloaded.actives.count == 2)
        #expect(reloaded.actives[0].name == "Tebuconazole")
        #expect(reloaded.actives[0].groupCode == "3")
        #expect(reloaded.actives[0].concentrationText == "200")
        #expect(reloaded.actives[1].name == "Azoxystrobin")
        #expect(reloaded.actives[1].groupCode == "11")
        #expect(reloaded.actives[1].concentrationText == "120")

        // Round-tripping the editor must not itself be an edit.
        let second = ChemicalManualEntry.outcome(for: reloaded, existing: first.intelligence)
        #expect(second.intelligence.activeIngredients == first.intelligence.activeIngredients)
        #expect(!second.hasResistanceCriticalChange)
    }

    @Test("adding a third active leaves the first two untouched")
    func addingAThirdActive() {
        let first = ChemicalManualEntry.outcome(for: mixtureDraft(), existing: nil)
        var grown = ChemicalManualEntry.draft(from: savedFrom(first.intelligence), fallbackCountry: "AU")
        grown.actives.append(activeDraft("Sulphur", "800", code: "M2"))

        let outcome = ChemicalManualEntry.outcome(for: grown, existing: first.intelligence)
        #expect(outcome.intelligence.activeIngredients.count == 3)
        #expect(outcome.intelligence.activityGroupCodes == ["3", "11", "M2"])
        #expect(outcome.intelligence.activeIngredients[0].activityGroup?.code == "3")
        #expect(outcome.intelligence.activeIngredients[1].activityGroup?.code == "11")
    }

    @Test("removing an active removes only its group")
    func removingAnActive() {
        let first = ChemicalManualEntry.outcome(for: mixtureDraft(), existing: nil)
        var reduced = mixtureDraft()
        reduced.actives = [activeDraft("Tebuconazole", "200", code: "3")]

        let outcome = ChemicalManualEntry.outcome(for: reduced, existing: first.intelligence)
        #expect(outcome.intelligence.activityGroupCodes == ["3"])
        #expect(outcome.intelligence.activeIngredients.count == 1)
    }

    // MARK: - Schemes

    @Test("every scheme survives persistence and a JSON round trip")
    func everySchemeRoundTrips() throws {
        let cases: [(ChemicalActivityGroupScheme, String)] = [
            (.frac, "11"),
            (.hrac, "G"),
            (.irac, "4A"),
        ]
        for (scheme, code) in cases {
            let draft = ChemicalManualDraft(
                productName: "Scheme test",
                actives: [activeDraft("Examplecide", scheme: scheme, code: code)]
            )
            let intel = ChemicalManualEntry.outcome(for: draft, existing: nil).intelligence
            let data = try JSONEncoder().encode(intel)
            let decoded = try JSONDecoder().decode(ChemicalIntelligence.self, from: data)
            let group = try #require(decoded.activeIngredients.first?.activityGroup)
            #expect(group.scheme == scheme)
            #expect(group.code == code)
        }
    }

    @Test("not applicable is recorded as an assertion, not as a missing group")
    func notApplicableIsAnAssertion() throws {
        let draft = ChemicalManualDraft(
            productName: "Wetting agent",
            productCategory: "adjuvant",
            actives: [
                ChemicalManualActiveDraft(
                    name: "Non-ionic surfactant",
                    scheme: .notApplicable
                )
            ]
        )
        let intel = ChemicalManualEntry.outcome(for: draft, existing: nil).intelligence
        let group = try #require(intel.activeIngredients.first?.activityGroup)

        #expect(group.scheme == .notApplicable)
        // "Has no resistance group" is a different claim from "group unknown", and
        // it must not contribute a code to the resistance columns.
        #expect(!group.isResistanceRelevant)
        #expect(intel.activityGroupCodes.isEmpty)

        let data = try JSONEncoder().encode(intel)
        let decoded = try JSONDecoder().decode(ChemicalIntelligence.self, from: data)
        #expect(decoded.activeIngredients.first?.activityGroup?.scheme == .notApplicable)
    }

    @Test("a code without a scheme is refused rather than guessed")
    func codeWithoutSchemeIsRefused() {
        let draft = ChemicalManualDraft(
            productName: "Half entered",
            actives: [activeDraft("Tebuconazole", scheme: nil, code: "3")]
        )
        let intel = ChemicalManualEntry.outcome(for: draft, existing: nil).intelligence

        // A bare "3" is ambiguous across schemes, so it is not stored as a group.
        #expect(intel.activeIngredients.first?.activityGroup == nil)
        #expect(ChemicalManualEntry.problems(in: draft)
            .contains { $0.contains("which resistance group system") })
    }

    // MARK: - Conflict

    @Test("a manually entered wrong group raises a conflict against the reference table")
    func wrongGroupRaisesConflict() throws {
        let draft = ChemicalManualDraft(
            productName: "Mislabelled",
            countryCode: "AU",
            productCategory: "fungicide",
            // The reference table knows Azoxystrobin is FRAC 11.
            actives: [activeDraft("Azoxystrobin", "250", code: "3")]
        )
        let outcome = ChemicalManualEntry.outcome(for: draft, existing: nil, at: at)

        let conflict = try #require(outcome.intelligence.verification.conflicts.first)
        #expect(outcome.intelligence.verification.conflicts.count == 1)
        #expect(conflict.field == "activity_group")
        #expect(conflict.activeIngredientName == "Azoxystrobin")
        #expect(conflict.extractedValue.contains("3"))
        #expect(conflict.authoritativeValue.contains("11"))
        #expect(outcome.resolvedStatus == .conflict)

        // The operator's own value is still what is stored — the table does not
        // silently overwrite them, it disagrees in the open.
        #expect(outcome.intelligence.activeIngredients.first?.activityGroup?.code == "3")
    }

    @Test("the reference table's authority is never attached to the typed group")
    func tableAuthorityNeverEndorsesTypedGroup() throws {
        let draft = ChemicalManualDraft(
            productName: "Mislabelled",
            actives: [activeDraft("Azoxystrobin", "250", code: "3")]
        )
        let active = try #require(
            ChemicalManualEntry.outcome(for: draft, existing: nil)
                .intelligence.activeIngredients.first
        )

        // The table's classification of Azoxystrobin-as-FRAC-11 must not read as
        // an endorsement of a hand-typed FRAC 3.
        #expect(active.groupSource == .manualEntry)
        #expect(!active.hasAuthoritativeGroup)
    }

    @Test("correcting the group clears the stale conflict")
    func correctingClearsConflict() {
        let wrong = ChemicalManualEntry.outcome(
            for: ChemicalManualDraft(
                productName: "Mislabelled",
                productCategory: "fungicide",
                actives: [activeDraft("Azoxystrobin", "250", code: "3")]
            ),
            existing: nil
        )
        #expect(wrong.resolvedStatus == .conflict)

        let corrected = ChemicalManualEntry.outcome(
            for: ChemicalManualDraft(
                productName: "Mislabelled",
                productCategory: "fungicide",
                actives: [activeDraft("Azoxystrobin", "250", code: "11")]
            ),
            existing: wrong.intelligence
        )

        // Group conflicts are recomputed from scratch on every reconcile, so a
        // correction clears the conflict it caused instead of leaving it stuck.
        #expect(corrected.intelligence.verification.conflicts.isEmpty)
        #expect(corrected.resolvedStatus == .unverified)
    }

    @Test("an active the reference table does not know raises no conflict")
    func unknownActiveRaisesNoConflict() {
        let draft = ChemicalManualDraft(
            productName: "Novel product",
            productCategory: "fungicide",
            actives: [activeDraft("Examplestrobin", "250", code: "11")]
        )
        let outcome = ChemicalManualEntry.outcome(for: draft, existing: nil)

        #expect(!AuthoritativeActivityGroups.knows(activeNamed: "Examplestrobin"))
        #expect(outcome.intelligence.verification.conflicts.isEmpty)
        // No conflict is inventable, and no trust is granted either.
        #expect(outcome.resolvedStatus == .unverified)
    }

    // MARK: - Verification

    @Test("a fully completed manual product still resolves Unverified")
    func fullyCompletedManualProductStaysUnverified() {
        let draft = ChemicalManualDraft(
            productName: "Completely Filled In",
            countryCode: "AU",
            productCategory: "fungicide",
            registrant: "Example Crop Science",
            // Exactly the shape an authoritative identity has.
            registrationScheme: .apvma,
            registrationNumber: "12345",
            actives: [
                activeDraft("Tebuconazole", "200", code: "3"),
                activeDraft("Azoxystrobin", "120", code: "11"),
            ],
            productRates: [
                ChemicalManualRateDraft(basis: .perHectare, valueText: "1.5", unit: "L")
            ],
            uses: [
                ChemicalManualUseDraft(
                    crop: "Grapes",
                    targetRaw: "Powdery Mildew",
                    withholdingPeriodDaysText: "14"
                )
            ]
        )
        let outcome = ChemicalManualEntry.outcome(for: draft, existing: nil, at: at)

        // Every field the operator could fill is filled, the groups are the CORRECT
        // ones, and the answer is still Unverified — because the source is the
        // operator, and completeness is not evidence.
        #expect(outcome.resolvedStatus == .unverified)
        #expect(outcome.resolvedStatus != .verified)
        #expect(outcome.resolvedStatus != .partiallyVerified)
    }

    @Test("a hand-typed registration number is not an authoritative identity")
    func handTypedRegistrationIsNotEvidence() throws {
        let draft = ChemicalManualDraft(
            productName: "Typed Identity",
            countryCode: "AU",
            registrationScheme: .apvma,
            registrationNumber: "12345",
            actives: [activeDraft("Tebuconazole", "200", code: "3")]
        )
        let intel = ChemicalManualEntry.outcome(for: draft, existing: nil).intelligence
        let registration = try #require(intel.registration)

        // The number is stored and usable as a lookup key...
        #expect(registration.registrationNumber == "12345")
        #expect(registration.identityKey == "AU:apvma:12345")
        // ...and it still is not proof of identity, because only the operator says so.
        #expect(registration.isAuthoritativeIdentity)
        #expect(!intel.hasEvidencedRegistration)
        #expect(intel.resolvedVerificationStatus == .unverified)
    }

    @Test("manual verification cites the operator and holds no verified date")
    func manualVerificationCitesTheOperator() {
        let intel = ChemicalManualEntry
            .outcome(for: mixtureDraft(), existing: nil, at: at).intelligence

        #expect(intel.verification.verifiedAt == nil)
        #expect(!intel.verification.sources.containsAuthoritative)
        #expect(intel.verification.sources.allSatisfy { $0.kind.isSelfReported })
    }

    // MARK: - Rates

    @Test("every label rate shape survives save and reload")
    func everyRateShapeSurvives() {
        var draft = mixtureDraft()
        draft.productRates = [
            ChemicalManualRateDraft(basis: .perHectare, valueText: "1.5", unit: "L"),
            ChemicalManualRateDraft(basis: .rangePerHectare, minText: "1.0", maxText: "1.5", unit: "L"),
            ChemicalManualRateDraft(basis: .per100Litres, valueText: "100", unit: "mL"),
            ChemicalManualRateDraft(basis: .rangePer100Litres, minText: "80", maxText: "100", unit: "mL"),
        ]
        let intel = ChemicalManualEntry.outcome(for: draft, existing: nil).intelligence
        let rates = intel.registeredUses.productLevelRates

        #expect(rates.count == 4)
        #expect(rates[0].displayRate == "1.5 L/ha")
        #expect(rates[1].displayRate == "1–1.5 L/ha")
        #expect(rates[2].displayRate == "100 mL/100 L")
        #expect(rates[3].displayRate == "80–100 mL/100 L")

        let reloaded = ChemicalManualEntry.draft(from: savedFrom(intel), fallbackCountry: "AU")
        #expect(reloaded.productRates.count == 4)
        #expect(reloaded.productRates[0].valueText == "1.5")
        #expect(reloaded.productRates[1].minText == "1")
        #expect(reloaded.productRates[1].maxText == "1.5")
        #expect(reloaded.productRates[2].basis == .per100Litres)
        #expect(reloaded.productRates[3].minText == "80")
    }

    @Test("a range typed back to front is stored low to high")
    func backToFrontRangeIsOrdered() throws {
        var draft = mixtureDraft()
        draft.productRates = [
            ChemicalManualRateDraft(basis: .rangePerHectare, minText: "2.0", maxText: "1.0", unit: "L")
        ]
        let rate = try #require(
            ChemicalManualEntry.outcome(for: draft, existing: nil)
                .intelligence.registeredUses.productLevelRates.first
        )

        #expect(rate.minValue == 1.0)
        #expect(rate.maxValue == 2.0)
        // A suggestion must never be handed the top of a band.
        #expect(rate.proposedValue == 1.0)
        #expect(ChemicalManualEntry.problems(in: draft).contains { $0.contains("back to front") })
    }

    @Test("the label rate basis drives the Guided Spray choices, not the carrier")
    func labelBasisDrivesGuidedSpray() throws {
        var areaDraft = mixtureDraft()
        areaDraft.productRates = [
            ChemicalManualRateDraft(basis: .perHectare, valueText: "1.5", unit: "L")
        ]
        let area = ChemicalManualEntry.outcome(for: areaDraft, existing: nil).intelligence

        // An area label leaves the whole-block vs treated-band decision to the job.
        #expect(area.labelRateBases == [.perHectare])
        let areaBasis = try #require(area.labelRateBases.first)
        #expect(areaBasis.compatibleProductRateBases == [.wholeBlockArea, .treatedArea])

        var volumeDraft = mixtureDraft()
        volumeDraft.productRates = [
            ChemicalManualRateDraft(basis: .per100Litres, valueText: "100", unit: "mL")
        ]
        let volume = ChemicalManualEntry.outcome(for: volumeDraft, existing: nil).intelligence

        // A per-100 L label stays carrier-based and offers exactly one option.
        let volumeBasis = try #require(volume.labelRateBases.first)
        #expect(volumeBasis.compatibleProductRateBases == [.per100Litres])
    }

    @Test("an application decision is never stored inside the legal label rate")
    func applicationDecisionIsNotInTheLabelRate() throws {
        var draft = mixtureDraft()
        draft.productRates = [
            ChemicalManualRateDraft(basis: .perHectare, valueText: "1.5", unit: "L")
        ]
        let intel = ChemicalManualEntry.outcome(for: draft, existing: nil).intelligence
        let rate = try #require(intel.registeredUses.productLevelRates.first)

        // The label basis is the product's. Whole-block vs treated-area is the
        // spray job's decision and has no representation in here at all.
        #expect(rate.basis == .perHectare)
        #expect(rate.basis.isAreaBased)
        #expect(!rate.basis.isVolumeBased)
        #expect(rate.rawText == nil)
    }

    @Test("product-level rates do not claim a registered use")
    func productRatesClaimNoUse() {
        var draft = mixtureDraft()
        draft.productRates = [
            ChemicalManualRateDraft(basis: .perHectare, valueText: "1.5", unit: "L")
        ]
        let intel = ChemicalManualEntry.outcome(for: draft, existing: nil).intelligence

        // Knowing a rate is not knowing which crop and disease it was registered
        // for. The carrier contributes rate information and no use claim.
        #expect(intel.registeredUses.count == 1)
        #expect(intel.registeredUses.statedUses.isEmpty)
        #expect(intel.registeredUses.viticulturalTargets.isEmpty)
        #expect(intel.labelRateBases.count == 1)
    }

    // MARK: - Uses

    @Test("multiple structured uses survive save and reload")
    func multipleUsesSurvive() {
        var draft = mixtureDraft()
        draft.uses = [
            ChemicalManualUseDraft(
                crop: "Grapes",
                targetRaw: "Powdery Mildew",
                rates: [ChemicalManualRateDraft(basis: .per100Litres, valueText: "100", unit: "mL")],
                withholdingPeriodDaysText: "14",
                reEntryPeriodHoursText: "24",
                restrictions: "Do not apply after bunch closure"
            ),
            ChemicalManualUseDraft(
                crop: "Grapes",
                targetRaw: "Botrytis",
                rates: [ChemicalManualRateDraft(basis: .perHectare, valueText: "2", unit: "L")],
                withholdingPeriodDaysText: "30"
            ),
        ]
        let intel = ChemicalManualEntry.outcome(for: draft, existing: nil).intelligence
        let uses = intel.registeredUses.statedUses

        #expect(uses.count == 2)
        #expect(uses[0].crop == "Grapes")
        #expect(uses[0].targetRaw == "Powdery Mildew")
        #expect(uses[0].target == .powderyMildew)
        #expect(uses[0].withholdingPeriodDays == 14)
        #expect(uses[0].reEntryPeriodHours == 24)
        #expect(uses[0].restrictions == "Do not apply after bunch closure")
        #expect(uses[1].target == .botrytis)
        #expect(uses[1].withholdingPeriodDays == 30)

        let reloaded = ChemicalManualEntry.draft(from: savedFrom(intel), fallbackCountry: "AU")
        #expect(reloaded.uses.count == 2)
        #expect(reloaded.uses[0].targetRaw == "Powdery Mildew")
        #expect(reloaded.uses[0].withholdingPeriodDaysText == "14")
        #expect(reloaded.uses[0].reEntryPeriodHoursText == "24")
        #expect(reloaded.uses[0].rates.first?.valueText == "100")
        #expect(reloaded.uses[1].withholdingPeriodDaysText == "30")
    }

    @Test("a target VineTrack has no word for is recorded rather than force-fitted")
    func unmappableTargetIsStillRecorded() throws {
        var draft = mixtureDraft()
        draft.uses = [ChemicalManualUseDraft(crop: "Grapes", targetRaw: "Phomopsis cane blight")]
        let use = try #require(
            ChemicalManualEntry.outcome(for: draft, existing: nil)
                .intelligence.registeredUses.statedUses.first
        )

        #expect(use.targetRaw == "Phomopsis cane blight")
        // Guessing a typed target would tell the Resistance Engine the wrong
        // disease was being managed, so it stays unmapped and stays recorded.
        #expect(use.target == nil)
        #expect(use.isViticultural)
    }

    // MARK: - Critical vs non-critical editing

    @Test("a chemistry edit re-resolves trust on a verified record")
    func chemistryEditReResolvesTrust() {
        // A genuinely verified record, as Match & Verify would have left it.
        var verified = ChemicalManualEntry.outcome(for: mixtureDraft(), existing: nil).intelligence
        verified.activeIngredients = verified.activeIngredients.map { active in
            var copy = active
            copy.groupSource = .authoritativeClassification
            copy.identitySource = .officialRegister
            return copy
        }
        verified.registration = ChemicalRegistration(
            countryCode: "AU",
            scheme: .apvma,
            registrationNumber: "62764"
        )
        verified.verification = ChemicalVerification(
            status: .verified,
            sources: [
                ChemicalDataSource(kind: .officialRegister, name: "APVMA PUBCRIS"),
                AuthoritativeActivityGroups.source(),
            ],
            verifiedAt: at
        )
        #expect(verified.resolvedVerificationStatus == .verified)

        var edited = mixtureDraft()
        edited.actives = [
            activeDraft("Tebuconazole", "200", code: "3"),
            // Hand-changed to a group nothing supports.
            activeDraft("Azoxystrobin", "120", code: "7"),
        ]
        let outcome = ChemicalManualEntry.outcome(for: edited, existing: verified, at: at)

        #expect(outcome.hasResistanceCriticalChange)
        #expect(outcome.resolvedStatus != .verified)
        #expect(outcome.isDowngrade)
        #expect(outcome.warning != nil)
    }

    @Test("commercial and operational fields are untouched by the chemistry editor")
    func commercialFieldsAreUntouched() {
        let intel = ChemicalManualEntry.outcome(for: mixtureDraft(), existing: nil).intelligence
        let saved = savedFrom(intel)

        var reloaded = ChemicalManualEntry.draft(from: saved, fallbackCountry: "AU")
        reloaded.actives.append(activeDraft("Sulphur", "800", code: "M2"))
        let outcome = ChemicalManualEntry.outcome(for: reloaded, existing: intel)

        // The chemistry editor's own output carries no commercial data at all,
        // which is structurally why price, pack, stock and notes cannot be lost.
        #expect(outcome.intelligence.activeIngredients.count == 3)
        #expect(saved.packSize == 10)
        #expect(saved.pricePerPack == 425)
        #expect(saved.inventoryQuantity == 3)
        #expect(saved.notes == "Shed B, top shelf")
        #expect(saved.applicationNotes == "Do not tank-mix with oil")
    }

    @Test("an untouched draft proposes no change at all")
    func untouchedDraftProposesNoChange() {
        let intel = ChemicalManualEntry.outcome(for: mixtureDraft(), existing: nil).intelligence
        let reloaded = ChemicalManualEntry.draft(from: savedFrom(intel), fallbackCountry: "AU")

        let outcome = ChemicalManualEntry.outcome(for: reloaded, existing: intel)

        // This is what lets a price-only or notes-only save leave verification
        // exactly where it was: nothing resistance-critical moved.
        #expect(!outcome.hasResistanceCriticalChange)
        #expect(outcome.resolvedStatus == intel.resolvedVerificationStatus)
    }

    @Test("a legacy record's free-text seed is not treated as prior evidence")
    func legacySeedIsNotPriorEvidence() throws {
        let legacy = SavedChemical(
            id: chemId,
            name: "Old Fungicide",
            activeIngredient: "Azoxystrobin 250 g/L",
            productCategory: "fungicide"
        )
        var seeded = legacy
        seeded.chemicalGroup = "11"
        #expect(seeded.chemicalIntelligence == nil)
        #expect(seeded.verificationStatus == .needsMatch)

        // The editor opens on what the old columns implied...
        let draft = ChemicalManualEntry.draft(from: seeded, fallbackCountry: "AU")
        #expect(draft.actives.first?.name == "Azoxystrobin")

        // ...and saving it is the operator asserting those values themselves, so
        // the record becomes Unverified rather than inheriting the seed's status.
        let outcome = ChemicalManualEntry.outcome(for: draft, chemical: seeded, at: at)
        #expect(outcome.resolvedStatus == .unverified)
        #expect(outcome.intelligence.activeIngredients.first?.groupSource == .manualEntry)
    }

    // MARK: - Match & Verify / Re-verify compatibility

    @Test("a manual product with a typed registration is offered Re-verify")
    func manualProductWithRegistrationIsOfferedReverify() {
        var draft = mixtureDraft()
        draft.registrationScheme = .apvma
        draft.registrationNumber = "12345"
        let intel = ChemicalManualEntry.outcome(for: draft, existing: nil).intelligence
        let saved = savedFrom(intel)

        #expect(ChemicalReverification.isOffered(for: saved, fallbackCountry: "AU"))
        let plan = ChemicalReverification.plan(for: saved, fallbackCountry: "AU")
        // The typed number is the strongest identity available, so the re-check
        // leads with it instead of restarting a brand-name search.
        #expect(plan.registrationNumber == "12345")
        #expect(plan.scheme == .apvma)
    }

    @Test("a manual product with only a registrant and country is still re-verifiable")
    func manualProductWithRegistrantIsReverifiable() {
        let intel = ChemicalManualEntry.outcome(for: mixtureDraft(), existing: nil).intelligence
        let saved = savedFrom(intel)

        // No registration number, but product name + registrant + country is a real
        // identity tier, so the domain can go and look. Manual entry does not have
        // to be complete to be re-checkable later.
        #expect(intel.registration?.registrationNumber == nil)
        #expect(ChemicalReverification.isOffered(for: saved, fallbackCountry: "AU"))
        #expect(ChemicalReverification.plan(for: saved, fallbackCountry: "AU").registrant
            == "Example Crop Science")
    }

    @Test("a manual product with no country cannot be re-verified yet")
    func manualProductWithNoCountryIsNotOffered() {
        let bare = ChemicalManualDraft(
            productName: "Shed Mix",
            actives: [activeDraft("Tebuconazole", "200", code: "3")]
        )
        let saved = savedFrom(
            ChemicalManualEntry.outcome(for: bare, existing: nil).intelligence,
            name: "Shed Mix"
        )

        // Without a country there is no register to check against, and the domain
        // says so rather than running a guess.
        #expect(!ChemicalReverification.isOffered(for: saved, fallbackCountry: ""))
        #expect(ChemicalReverification.unavailableReason(for: saved, fallbackCountry: "") != nil)
    }

    @Test("matching a manual product later compares against what the operator recorded")
    func matchingLaterDiffsAgainstTheManualRecord() throws {
        let manual = ChemicalManualEntry.outcome(for: mixtureDraft(), existing: nil).intelligence
        // What a register would come back with six months later: the same two
        // actives, authoritatively classified, and one concentration corrected.
        var authoritative = manual
        authoritative.activeIngredients = manual.activeIngredients.enumerated().map { index, active in
            var copy = active
            if index == 1 { copy.concentration = 250 }
            copy.groupSource = .authoritativeClassification
            copy.identitySource = .officialRegister
            return copy
        }

        let diff = ChemicalIntelligenceDiffer.diff(current: manual, candidate: authoritative)

        // The operator's record is the baseline the review screen diffs against, so
        // nothing they entered is discarded before they have seen the change.
        #expect(diff.hasMeaningfulChanges)
        let change = try #require(diff.changes.first { $0.currentValue?.contains("120") == true })
        #expect(change.currentValue?.contains("120") == true)
        #expect(change.candidateValue?.contains("250") == true)

        // And a groupSource-only difference is NOT a chemistry change: the meaning
        // of the record is unmoved, only the evidence behind it.
        var evidenceCandidate = manual
        evidenceCandidate.activeIngredients = manual.activeIngredients.map { active in
            var copy = active
            copy.groupSource = .authoritativeClassification
            return copy
        }
        let evidenceOnly = ChemicalIntelligenceDiffer.diff(
            current: manual,
            candidate: evidenceCandidate
        )
        #expect(!evidenceOnly.hasResistanceCriticalChanges)
    }

    // MARK: - Snapshot and history

    @Test("selecting a manual product captures its complete structure")
    func snapshotCapturesFullStructure() throws {
        let intel = ChemicalManualEntry.outcome(for: mixtureDraft(), existing: nil).intelligence
        let saved = savedFrom(intel)

        let resolution = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId: saved.id,
            productName: saved.name,
            library: [saved],
            at: at
        )
        let snapshot = try #require(resolution.snapshot)
        #expect(resolution.match == .identifier)

        #expect(snapshot.activeIngredients.count == 2)
        #expect(snapshot.activityGroupCodes == ["3", "11"])
        #expect(snapshot.verificationStatus == .unverified)
        #expect(snapshot.productName == "Custom Mix 300")
        #expect(snapshot.savedChemicalId == saved.id.uuidString)
        #expect(snapshot.capturedAt == at)
        // Manual provenance travels with the frozen record.
        #expect(snapshot.activeIngredients.allSatisfy { $0.groupSource == .manualEntry })
    }

    @Test("a completed spray keeps the chemistry it was recorded against")
    func historicalSnapshotIsImmutable() throws {
        let manual = ChemicalManualEntry.outcome(for: mixtureDraft(), existing: nil).intelligence
        let saved = savedFrom(manual)
        let frozen = try #require(
            ChemicalSnapshotCapture.captureForNewApplication(
                savedChemicalId: saved.id,
                productName: saved.name,
                library: [saved],
                at: at
            ).snapshot
        )

        // The Saved Chemical is later corrected and its chemistry moves on.
        var reduced = mixtureDraft()
        reduced.actives = [activeDraft("Tebuconazole", "200", code: "3")]
        let corrected = ChemicalManualEntry.outcome(for: reduced, existing: manual)
        #expect(corrected.intelligence.activityGroupCodes == ["3"])

        // The historical record does not move with it.
        #expect(frozen.activityGroupCodes == ["3", "11"])
        #expect(frozen.activeIngredients.count == 2)
        #expect(frozen.verificationStatus == .unverified)
        #expect(frozen.capturedAt == at)
    }

    // MARK: - Offline / JSON parity

    @Test("a structured mixture survives the offline JSON round trip intact")
    func offlineRoundTripIsLossless() throws {
        var draft = mixtureDraft()
        draft.registrationScheme = .apvma
        draft.registrationNumber = "12345"
        draft.productRates = [
            ChemicalManualRateDraft(basis: .rangePerHectare, minText: "1.0", maxText: "1.5", unit: "L")
        ]
        draft.uses = [
            ChemicalManualUseDraft(
                crop: "Grapes",
                targetRaw: "Powdery Mildew",
                withholdingPeriodDaysText: "14",
                reEntryPeriodHoursText: "24"
            )
        ]
        let intel = ChemicalManualEntry.outcome(for: draft, existing: nil).intelligence

        let data = try JSONEncoder().encode(intel)
        let decoded = try JSONDecoder().decode(ChemicalIntelligence.self, from: data)

        // The whole point: an offline create must not drop the structured arrays
        // on its way through the queue.
        #expect(decoded.activeIngredients.count == 2)
        #expect(decoded.activityGroupCodes == ["3", "11"])
        #expect(decoded.registration?.registrationNumber == "12345")
        #expect(decoded.registeredUses.count == 2)
        #expect(decoded.registeredUses.statedUses.first?.withholdingPeriodDays == 14)
        #expect(decoded.registeredUses.productLevelRates.first?.basis == .rangePerHectare)
        #expect(decoded.resolvedVerificationStatus == .unverified)
    }

    @Test("an empty draft produces nothing rather than an empty shell")
    func emptyDraftProducesNothing() {
        let empty = ChemicalManualDraft(actives: [ChemicalManualActiveDraft()])
        let proposed = ChemicalManualEntry.proposedIntelligence(from: empty, existing: nil)

        // A record whose chemistry was never entered must not be given a structured
        // payload just because the form was opened.
        #expect(proposed.isEmpty)
        #expect(proposed.activeIngredients.isEmpty)
        #expect(proposed.registration == nil)
    }

    @Test("a decimal comma is read rather than dropped")
    func decimalCommaIsRead() {
        #expect(ChemicalManualEntry.parseDouble("1,5") == 1.5)
        #expect(ChemicalManualEntry.parseDouble(" 1.5 ") == 1.5)
        #expect(ChemicalManualEntry.parseDouble("") == nil)
        #expect(ChemicalManualEntry.parseDouble("abc") == nil)
        #expect(ChemicalManualEntry.parseInt("14") == 14)
    }

    @Test("a duplicated active is reported")
    func duplicatedActiveIsReported() {
        var draft = mixtureDraft()
        draft.actives = [
            activeDraft("Tebuconazole", "200", code: "3"),
            activeDraft("tebuconazole", "200", code: "3"),
        ]
        #expect(ChemicalManualEntry.problems(in: draft).contains { $0.contains("listed twice") })
    }

    @Test("a product name is required")
    func productNameIsRequired() {
        var draft = mixtureDraft()
        draft.productName = "  "
        #expect(ChemicalManualEntry.problems(in: draft).contains { $0.contains("Product name") })
        #expect(ChemicalManualEntry.problems(in: mixtureDraft()).isEmpty)
    }
}
