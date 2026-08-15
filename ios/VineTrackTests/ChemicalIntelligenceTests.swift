import Foundation
import Testing
@testable import VineTrack

/// Contract tests for the Chemical Intelligence foundation.
///
/// The Android suite `ChemicalIntelligenceTest` asserts the same fixtures and
/// the same outcomes, so both platforms classify a product identically.
///
/// Everything here protects one rule: resistance decisions are made from
/// structured, source-attributed data, never from parsing a free-text
/// `chemical_group` string — and a product is only ever as trusted as the
/// weakest evidence behind it.
struct ChemicalIntelligenceTests {

    // MARK: - Fixtures

    private func frac(_ code: String) -> ChemicalActivityGroup {
        ChemicalActivityGroup(scheme: .frac, code: code)
    }

    private func active(
        _ name: String,
        _ concentration: Double? = nil,
        group: ChemicalActivityGroup? = nil,
        groupSource: ChemicalDataSourceKind? = .authoritativeClassification
    ) -> ChemicalActiveIngredient {
        ChemicalActiveIngredient(
            name: name,
            concentration: concentration,
            concentrationUnit: concentration == nil ? nil : .gramsPerLitre,
            activityGroup: group,
            groupSource: group == nil ? nil : groupSource,
            identitySource: .officialRegister
        )
    }

    private func registration(
        country: String = "AU",
        scheme: ChemicalRegistrationScheme? = .apvma,
        number: String? = "62764"
    ) -> ChemicalRegistration {
        ChemicalRegistration(
            countryCode: country,
            scheme: scheme,
            registrationNumber: number,
            registrant: "Example Crop Science",
            registeredProductName: "Example Fungicide"
        )
    }

    private func verifiedEvidence() -> ChemicalVerification {
        ChemicalVerification(
            status: .verified,
            sources: [
                ChemicalDataSource(kind: .officialRegister, name: "APVMA PUBCRIS"),
                AuthoritativeActivityGroups.source()
            ],
            verifiedAt: Date()
        )
    }

    /// THE worked example from the specification: a two-active mixture that
    /// must count as Group 3 AND Group 11.
    private func combinationProduct() -> ChemicalIntelligence {
        ChemicalIntelligence(
            activeIngredients: [
                active("Tebuconazole", 200, group: frac("3")),
                active("Azoxystrobin", 120, group: frac("11"))
            ],
            registration: registration(),
            verification: verifiedEvidence(),
            registeredUses: [
                ChemicalRegisteredUse(
                    crop: "Grapes (winegrapes)",
                    targetRaw: "Powdery mildew",
                    rates: [
                        ChemicalLabelRate(label: "Standard", basis: .perHectare, value: 1.5, unit: "L")
                    ],
                    withholdingPeriodDays: 30
                )
            ],
            productCategory: "fungicide"
        )
    }

    private func singleActiveProduct() -> ChemicalIntelligence {
        ChemicalIntelligence(
            activeIngredients: [active("Azoxystrobin", 250, group: frac("11"))],
            registration: registration(number: "50123"),
            verification: verifiedEvidence(),
            productCategory: "fungicide"
        )
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func savedChemical(
        name: String = "Example Fungicide",
        activeIngredient: String = "",
        chemicalGroup: String = "",
        modeOfAction: String = "",
        productCategory: String = "fungicide",
        intelligence: ChemicalIntelligence? = nil
    ) -> SavedChemical {
        SavedChemical(
            name: name,
            chemicalGroup: chemicalGroup,
            manufacturer: "Example Crop Science",
            activeIngredient: activeIngredient,
            modeOfAction: modeOfAction,
            productCategory: productCategory,
            chemicalIntelligence: intelligence
        )
    }

    // MARK: - Single active

    @Test("A single-active product exposes exactly one group")
    func singleActive() throws {
        let intel = singleActiveProduct()

        #expect(intel.activeIngredients.count == 1)
        #expect(intel.activityGroupCodes == ["11"])
        #expect(intel.activityGroups.first?.scheme == .frac)
        #expect(intel.resolvedVerificationStatus == .verified)
        #expect(try roundTrip(intel).activityGroupCodes == ["11"])
    }

    // MARK: - Combination product

    @Test("A two-active mixture counts as BOTH groups, never as one fused string")
    func combinationProductYieldsBothGroups() {
        let intel = combinationProduct()

        // The headline requirement of the whole stage.
        #expect(intel.activityGroupCodes == ["3", "11"])
        #expect(intel.activityGroupCodes != ["3 + 11"])
        #expect(intel.activityGroups.count == 2)

        // Each group belongs to its OWN active — the relationship the future
        // engine needs in order to reason about a mixture at all.
        #expect(intel.activeIngredients[0].activityGroup?.code == "3")
        #expect(intel.activeIngredients[1].activityGroup?.code == "11")
    }

    @Test("Group order is stable regardless of the order the actives were entered")
    func groupOrderIsStable() {
        let forward = combinationProduct()
        var reversed = combinationProduct()
        reversed.activeIngredients.reverse()

        // Two identical products must never persist as two different-looking
        // histories, or the future rotation analysis sees phantom variety.
        #expect(forward.activityGroupCodes == reversed.activityGroupCodes)
        #expect(reversed.activityGroupCodes == ["3", "11"])
    }

    @Test("All groups of a mixture survive persistence and reload")
    func mixedActivesSurviveReload() throws {
        let reloaded = try roundTrip(combinationProduct())

        #expect(reloaded.activityGroupCodes == ["3", "11"])
        #expect(reloaded.activeIngredients.count == 2)
        #expect(reloaded.activeIngredients[0].name == "Tebuconazole")
        #expect(reloaded.activeIngredients[0].concentration == 200)
        #expect(reloaded.activeIngredients[0].concentrationUnit == .gramsPerLitre)
        #expect(reloaded.activeIngredients[1].activityGroup?.code == "11")
        #expect(reloaded.resolvedVerificationStatus == .verified)
    }

    @Test("The legacy group string is derived FROM the groups, not the reverse")
    func legacyProjectionIsDerived() {
        let intel = combinationProduct()

        #expect(intel.legacyChemicalGroup == "3 + 11")
        #expect(intel.legacyActiveIngredient == "Tebuconazole 200 g/L + Azoxystrobin 120 g/L")

        // And the direction of authority is what matters: dropping an active
        // changes the projection, because the projection is an output.
        var single = intel
        single.activeIngredients.removeLast()
        #expect(single.legacyChemicalGroup == "3")
    }

    // MARK: - Legacy chemicals

    @Test("A pre-Chemical-Intelligence chemical still loads and keeps its display fields")
    func legacyChemicalStillLoads() {
        let legacy = savedChemical(
            activeIngredient: "Tebuconazole 200 g/L + Azoxystrobin 120 g/L",
            chemicalGroup: "3 + 11",
            modeOfAction: "3 (DMI) + 11 (QoI / Strobilurin)"
        )

        // Untouched scalars: the Chemical Store renders exactly as it did.
        #expect(legacy.chemicalGroup == "3 + 11")
        #expect(legacy.activeIngredient == "Tebuconazole 200 g/L + Azoxystrobin 120 g/L")
        #expect(legacy.chemicalIntelligence == nil)

        // The candidate reading identifies both actives for the audit...
        let seeded = legacy.resolvedIntelligence
        #expect(seeded.activeIngredients.map(\.name) == ["Tebuconazole", "Azoxystrobin"])
        // ...but is explicitly UNMATCHED, never verified.
        #expect(seeded.resolvedVerificationStatus == .needsMatch)
        #expect(legacy.verificationStatus == .needsMatch)
    }

    @Test("Groups parsed from legacy text can never satisfy a verified claim")
    func legacyParsedGroupsAreNotAuthoritative() {
        let legacy = savedChemical(
            activeIngredient: "Tebuconazole + Azoxystrobin",
            chemicalGroup: "3 + 11"
        )
        let seeded = legacy.resolvedIntelligence

        #expect(seeded.activityGroupCodes == ["3", "11"])
        // Every one of them is tagged as coming from an old record, which makes
        // `hasAuthoritativeGroup` false and Verified structurally unreachable.
        #expect(seeded.activeIngredients.allSatisfy { $0.groupSource == .legacyRecord })
        #expect(seeded.activeIngredients.allSatisfy { !$0.hasAuthoritativeGroup })
        #expect(seeded.resolvedVerificationStatus != .verified)
    }

    @Test("A legacy group is never attached to the wrong active in a mixture")
    func ambiguousLegacyPairingAttachesNothing() {
        // Two actives but only one parsable group: which active owns it is
        // unknowable, so attaching it anywhere would be a fabrication.
        let legacy = savedChemical(
            activeIngredient: "Tebuconazole + Azoxystrobin",
            chemicalGroup: "11"
        )
        let seeded = legacy.resolvedIntelligence

        #expect(seeded.activeIngredients.count == 2)
        #expect(seeded.activeIngredients.allSatisfy { $0.activityGroup == nil })
        #expect(seeded.activityGroupCodes.isEmpty)
    }

    @Test("A chemistry name in the legacy group field yields no false codes")
    func chemistryNameYieldsNoCodes() {
        let legacy = savedChemical(
            activeIngredient: "Seaweed extract",
            chemicalGroup: "Biostimulant - Amino Acid",
            productCategory: "biostimulant"
        )

        #expect(legacy.resolvedIntelligence.activityGroupCodes.isEmpty)
        #expect(ChemicalActivityGroup.isPlausibleCode("STROBILURIN") == false)
        #expect(ChemicalActivityGroup.isPlausibleCode("M5"))
        #expect(ChemicalActivityGroup.isPlausibleCode("G"))
        #expect(ChemicalActivityGroup.isPlausibleCode("4A"))
    }

    @Test("Saving a legacy chemical never rewrites its own display fields")
    func savingLegacyDoesNotRewrite() {
        let legacy = savedChemical(
            activeIngredient: "Tebuconazole 200 g/L",
            chemicalGroup: "Triazole"
        )
        let projection = legacy.legacyProjection

        // No structured intelligence means no derived projection: the
        // operator's own words survive the round trip untouched.
        #expect(projection.chemicalGroup == "Triazole")
        #expect(projection.activeIngredient == "Tebuconazole 200 g/L")
    }

    @Test("A structured chemical writes derived legacy scalars for old clients")
    func structuredChemicalWritesDerivedScalars() {
        let chemical = savedChemical(
            activeIngredient: "old text",
            chemicalGroup: "old group",
            intelligence: combinationProduct()
        )
        let projection = chemical.legacyProjection

        #expect(projection.chemicalGroup == "3 + 11")
        #expect(projection.activeIngredient == "Tebuconazole 200 g/L + Azoxystrobin 120 g/L")
    }

    // MARK: - Verification states

    @Test("Verified, partially verified and unverified all round-trip")
    func verificationStatesRoundTrip() throws {
        for status in ChemicalVerificationStatus.allCases {
            let verification = ChemicalVerification(status: status)
            #expect(try roundTrip(verification).status == status)
        }
    }

    @Test("A product with an unconfirmed group cannot claim Verified")
    func unconfirmedGroupBlocksVerified() {
        var intel = combinationProduct()
        // The claim says verified; the evidence says one group came from an AI.
        intel.activeIngredients[1].groupSource = .aiInterpretation

        #expect(intel.verification.status == .verified)
        #expect(intel.resolvedVerificationStatus == .partiallyVerified)
        #expect(intel.isResistanceDependable == false)
    }

    @Test("A product with no registration cannot claim Verified")
    func missingRegistrationBlocksVerified() {
        var intel = combinationProduct()
        intel.registration = nil

        #expect(intel.resolvedVerificationStatus == .partiallyVerified)
    }

    @Test("An AI hit alone is never Verified")
    func aiAloneIsNeverVerified() {
        let intel = ChemicalIntelligence(
            activeIngredients: [
                active("Azoxystrobin", 250, group: frac("11"), groupSource: .aiInterpretation)
            ],
            registration: registration(),
            verification: ChemicalVerification(
                status: .verified,
                sources: [ChemicalDataSource(kind: .aiInterpretation, name: "Model extraction")]
            )
        )

        // The lookup found something real, and it is still not a verification.
        #expect(intel.resolvedVerificationStatus == .partiallyVerified)
        #expect(ChemicalDataSourceKind.aiInterpretation.isAuthoritative == false)
    }

    @Test("An unresolved field keeps a product below Verified")
    func unresolvedFieldBlocksVerified() {
        var intel = combinationProduct()
        intel.verification.unresolvedFields = ["registered_uses"]

        #expect(intel.resolvedVerificationStatus == .partiallyVerified)
    }

    @Test("A manually entered chemical defaults to Unverified")
    func manualEntryIsUnverified() {
        let manual = ChemicalIntelligence(
            activeIngredients: [
                ChemicalActiveIngredient(
                    name: "Tebuconazole",
                    concentration: 430,
                    concentrationUnit: .gramsPerLitre,
                    activityGroup: frac("3"),
                    groupSource: .manualEntry,
                    identitySource: .manualEntry
                )
            ],
            verification: .manual(),
            productCategory: "fungicide"
        )

        // Structured entry is still supported — the operator gets the full model,
        // not a free-text box — but typing is not evidence.
        #expect(manual.activeIngredients.count == 1)
        #expect(manual.activityGroupCodes == ["3"])
        #expect(manual.resolvedVerificationStatus == .unverified)
        #expect(manual.isResistanceDependable == false)
    }

    // MARK: - Source conflict

    @Test("A disagreement between extraction and classification becomes a conflict")
    func conflictIsSurfaced() {
        // The specification's example: extraction says Group 11, the
        // authoritative classification says Group 3.
        let outcome = AuthoritativeActivityGroups.reconcile(
            activeNamed: "Tebuconazole",
            extracted: frac("11"),
            extractedSource: .aiInterpretation
        )

        let conflict = try? #require(outcome.conflict)
        #expect(conflict?.field == "activity_group")
        #expect(conflict?.activeIngredientName == "Tebuconazole")
        #expect(conflict?.extractedValue.contains("11") == true)
        #expect(conflict?.authoritativeValue.contains("3") == true)

        // The authoritative answer is what survives — the extracted value is
        // never silently kept.
        #expect(outcome.group?.code == "3")
        #expect(outcome.source == .authoritativeClassification)
    }

    @Test("A conflicted product can never be Verified, whatever status is stored")
    func conflictCannotBeVerified() throws {
        var intel = combinationProduct()
        intel.verification.addConflict(
            ChemicalVerificationConflict(
                field: "activity_group",
                activeIngredientName: "Tebuconazole",
                extractedValue: "FRAC 11",
                authoritativeValue: "FRAC 3"
            )
        )

        #expect(intel.verification.status == .conflict)
        #expect(intel.resolvedVerificationStatus == .conflict)
        #expect(intel.isResistanceDependable == false)

        // Even forcing the stored status back to verified cannot promote it:
        // the resolved status is computed from evidence, not from the claim.
        intel.verification.status = .verified
        #expect(intel.resolvedVerificationStatus == .conflict)
        #expect(try roundTrip(intel).resolvedVerificationStatus == .conflict)
    }

    @Test("Agreement between sources upgrades the attribution, not the value")
    func agreementUpgradesSource() {
        let outcome = AuthoritativeActivityGroups.reconcile(
            activeNamed: "Azoxystrobin",
            extracted: frac("11"),
            extractedSource: .aiInterpretation
        )

        #expect(outcome.conflict == nil)
        #expect(outcome.group?.code == "11")
        #expect(outcome.source == .authoritativeClassification)
    }

    @Test("An active the table does not know keeps its weaker attribution")
    func unknownActiveKeepsWeakSource() {
        let outcome = AuthoritativeActivityGroups.reconcile(
            activeNamed: "Novelmoleculeium",
            extracted: frac("11"),
            extractedSource: .aiInterpretation
        )

        // No opinion is not agreement. The group survives so the operator can
        // see it, but it stays attributed to the AI and cannot reach Verified.
        #expect(outcome.conflict == nil)
        #expect(outcome.group?.code == "11")
        #expect(outcome.source == .aiInterpretation)
        #expect(AuthoritativeActivityGroups.knows(activeNamed: "Novelmoleculeium") == false)
    }

    // MARK: - Country separation

    @Test("Identically named AU and NZ products are different identities")
    func countriesAreSeparateIdentities() {
        let au = ChemicalRegistration(
            countryCode: "AU", scheme: .apvma, registrationNumber: "62764",
            registeredProductName: "Example Fungicide"
        )
        let nz = ChemicalRegistration(
            countryCode: "NZ", scheme: .acvm, registrationNumber: "P7391",
            registeredProductName: "Example Fungicide"
        )

        #expect(au.identityKey == "AU:apvma:62764")
        #expect(nz.identityKey == "NZ:acvm:P7391")
        #expect(au.identityKey != nz.identityKey)
    }

    @Test("The same registration number in two countries is still two products")
    func sameNumberDifferentCountry() {
        let au = ChemicalRegistration(countryCode: "AU", scheme: .apvma, registrationNumber: "1234")
        let nz = ChemicalRegistration(countryCode: "NZ", scheme: .acvm, registrationNumber: "1234")

        // Country is part of the key precisely so NZ rates can never be read
        // off an AU label.
        #expect(au.identityKey != nz.identityKey)
    }

    @Test("Each country resolves to its own registers, and others stay empty")
    func registerSchemesPerCountry() {
        #expect(ChemicalRegistrationScheme.schemes(forCountryCode: "AU") == [.apvma])
        #expect(ChemicalRegistrationScheme.schemes(forCountryCode: "NZ") == [.acvm, .nzEPA])
        // Extensible without pretending coverage exists.
        #expect(ChemicalRegistrationScheme.schemes(forCountryCode: "US").isEmpty)
    }

    @Test("Country names and codes normalise to the same stored value")
    func countryNormalisation() {
        #expect(ChemicalRegistration(countryCode: "Australia").countryCode == "AU")
        #expect(ChemicalRegistration(countryCode: "New Zealand").countryCode == "NZ")
        #expect(ChemicalRegistration(countryCode: "nz").countryCode == "NZ")
    }

    @Test("A registration without a scheme cannot underwrite Verified")
    func weakRegistrationIsNotAuthoritative() {
        let vague = ChemicalRegistration(countryCode: "AU", scheme: .other, registrationNumber: "?")
        #expect(vague.isAuthoritativeIdentity == false)
        #expect(registration().isAuthoritativeIdentity)
    }

    // MARK: - Label rate basis

    @Test("Label rate basis is independent of the spray carrier basis")
    func labelBasisIsIndependentOfCarrier() {
        let perHectare = ChemicalLabelRate(label: "Standard", basis: .perHectare, value: 1.5, unit: "L")
        let per100L = ChemicalLabelRate(label: "Standard", basis: .per100Litres, value: 100, unit: "mL")

        #expect(perHectare.displayRate == "1.5 L/ha")
        #expect(per100L.displayRate == "100 mL/100 L")
        #expect(perHectare.basis.isAreaBased)
        #expect(per100L.basis.isVolumeBased)

        // An NZ vineyard measuring carrier in L/100 m still applies a 1.5 L/ha
        // product: the label basis is never rewritten to match the carrier.
        #expect(ChemicalLabelRateBasis.allCases.contains(.perHectare))
        #expect(perHectare.basis != per100L.basis)
    }

    @Test("A per-100 L label offers exactly one spray basis, so no picker is shown")
    func per100LOffersOneBasis() {
        #expect(ChemicalLabelRateBasis.per100Litres.compatibleProductRateBases == [.per100Litres])
        #expect(ChemicalLabelRateBasis.rangePer100Litres.compatibleProductRateBases == [.per100Litres])
    }

    @Test("An area label offers whole-block and treated-area, the banded ambiguity")
    func areaLabelOffersBothAreaBases() {
        #expect(
            ChemicalLabelRateBasis.perHectare.compatibleProductRateBases
                == [.wholeBlockArea, .treatedArea]
        )
        #expect(
            ChemicalLabelRateBasis.rangePerHectare.compatibleProductRateBases
                == [.wholeBlockArea, .treatedArea]
        )
    }

    @Test("A rate range proposes its low end, never its high end")
    func rangeProposesLowEnd() {
        let range = ChemicalLabelRate(
            label: "Disease pressure", basis: .rangePerHectare,
            minValue: 1.0, maxValue: 2.0, unit: "L"
        )

        #expect(range.displayRate == "1–2 L/ha")
        // An automatic suggestion must never inflate a dose on the operator's
        // behalf.
        #expect(range.proposedValue == 1.0)
    }

    @Test("An unusual label basis is preserved verbatim rather than force-fitted")
    func otherBasisPreservesText() {
        let odd = ChemicalLabelRate(
            label: "Per vine", basis: .other, unit: "mL", rawText: "5 mL per vine"
        )

        #expect(odd.displayRate == "5 mL per vine")
        #expect(odd.basis.compatibleProductRateBases.isEmpty)
    }

    @Test("Distinct label rate bases are collected across registered uses")
    func rateBasesCollected() {
        let intel = ChemicalIntelligence(
            registeredUses: [
                ChemicalRegisteredUse(
                    crop: "Grapes", targetRaw: "Powdery mildew",
                    rates: [ChemicalLabelRate(basis: .perHectare, value: 1.5, unit: "L")]
                ),
                ChemicalRegisteredUse(
                    crop: "Grapes", targetRaw: "Botrytis",
                    rates: [ChemicalLabelRate(basis: .per100Litres, value: 100, unit: "mL")]
                )
            ]
        )

        #expect(intel.labelRateBases.count == 2)
        #expect(intel.labelRateBases.contains(.perHectare))
        #expect(intel.labelRateBases.contains(.per100Litres))
    }

    // MARK: - Registered uses / targets

    @Test("Registered uses map onto typed targets only when the label is unambiguous")
    func targetMapping() {
        #expect(ChemicalRegisteredUse.mapTarget("Powdery mildew") == .powderyMildew)
        #expect(ChemicalRegisteredUse.mapTarget("Downy mildew (Plasmopara viticola)") == .downyMildew)
        #expect(ChemicalRegisteredUse.mapTarget("Botrytis bunch rot") == .botrytis)
        // Never guessed: a wrong target would tell the future engine the wrong
        // disease was being managed.
        #expect(ChemicalRegisteredUse.mapTarget("Light brown apple moth") == nil)
        #expect(ChemicalRegisteredUse.mapTarget("") == nil)
    }

    @Test("A target is never inferred from the chemistry")
    func targetIsNotInferredFromGroup() {
        // A Group 11 product with no registered uses recorded. It is emphatically
        // NOT assumed to control powdery mildew just because of its chemistry.
        let intel = ChemicalIntelligence(
            activeIngredients: [active("Azoxystrobin", 250, group: frac("11"))],
            registration: registration(),
            verification: verifiedEvidence()
        )

        #expect(intel.activityGroupCodes == ["11"])
        #expect(intel.registeredUses.isEmpty)
        #expect(intel.registeredUses.viticulturalTargets.isEmpty)
    }

    @Test("Only viticultural uses are surfaced as vine targets")
    func viticulturalFiltering() {
        let uses = [
            ChemicalRegisteredUse(crop: "Grapes (winegrapes)", targetRaw: "Powdery mildew"),
            ChemicalRegisteredUse(crop: "Wheat", targetRaw: "Rust")
        ]

        #expect(uses.viticultural.count == 1)
        #expect(uses.viticulturalTargets == [.powderyMildew])
    }

    // MARK: - Resistance profile contract

    @Test("The resistance profile hands over codes, never a fused string")
    func resistanceProfileContract() {
        let chemical = savedChemical(intelligence: combinationProduct())
        let profile = chemical.resistanceProfile()

        #expect(profile.activityGroupCodes == ["3", "11"])
        #expect(profile.activeIngredients.count == 2)
        #expect(profile.verificationStatus == .verified)
        #expect(profile.isDependable)
        #expect(profile.countryCode == "AU")
        #expect(profile.registrationIdentityKey == "AU:apvma:62764")
        #expect(profile.labelRateBases == [.perHectare])
        #expect(profile.viticulturalTargets == [.powderyMildew])
        #expect(profile.sourceVersion == "1.\(AuthoritativeActivityGroups.tableVersion)")
    }

    @Test("An unmatched legacy chemical still yields a profile, marked undependable")
    func legacyProfileIsUndependable() {
        let profile = savedChemical(
            activeIngredient: "Sulphur 800 g/kg",
            chemicalGroup: "M2"
        ).resistanceProfile()

        #expect(profile.isDependable == false)
        #expect(profile.verificationStatus == .needsMatch)
    }

    // MARK: - Spray line snapshot

    @Test("A spray line freezes the classification that was current when applied")
    func sprayLineFreezesClassification() throws {
        let snapshot = try #require(
            ChemicalLineSnapshot.capture(from: combinationProduct(), legacyChemicalGroup: "3 + 11")
        )
        let line = SprayChemical(
            name: "Example Fungicide",
            volumePerTank: 1_500,
            ratePerHa: 1_500,
            unit: .litres,
            rateBasis: .wholeBlockArea,
            chemicalSnapshot: snapshot
        )

        #expect(line.recordedActivityGroupCodes == ["3", "11"])
        #expect(line.hasResistanceSnapshot)
        #expect(line.chemicalSnapshot?.verificationStatus == .verified)
        #expect(line.chemicalSnapshot?.registrationIdentityKey == "AU:apvma:62764")
        #expect(try roundTrip(line).recordedActivityGroupCodes == ["3", "11"])
    }

    @Test("Correcting the Chemical Store later does not restate a historical spray")
    func correctingChemicalDoesNotRestateHistory() throws {
        // The spray as it was recorded, against a product classified 3 + 11.
        let line = SprayChemical(
            name: "Example Fungicide",
            chemicalSnapshot: ChemicalLineSnapshot.capture(
                from: combinationProduct(), legacyChemicalGroup: "3 + 11"
            )
        )

        // Three years later the Chemical Store record is corrected: one active
        // was wrong, and the whole product is reclassified.
        var corrected = combinationProduct()
        corrected.activeIngredients = [active("Fluopyram", 400, group: frac("7"))]
        let correctedChemical = savedChemical(intelligence: corrected)
        #expect(correctedChemical.activityGroupCodes == ["7"])

        // The historical spray is untouched. It still reports what VineTrack
        // actually used when the application happened.
        #expect(line.recordedActivityGroupCodes == ["3", "11"])
        #expect(try roundTrip(line).recordedActivityGroupCodes == ["3", "11"])
    }

    @Test("A line whose product has nothing structured stays honestly empty")
    func unstructuredLineHasNoSnapshot() {
        #expect(ChemicalLineSnapshot.capture(from: nil, legacyChemicalGroup: "") == nil)

        // A legacy display string alone is preserved for faithful reproduction,
        // but carries no machine-readable groups — "we did not know" is the
        // honest answer, not an invitation to go and read today's record.
        let legacyOnly = ChemicalLineSnapshot.capture(from: nil, legacyChemicalGroup: "3 + 11")
        #expect(legacyOnly?.legacyChemicalGroup == "3 + 11")
        #expect(legacyOnly?.activityGroupCodes.isEmpty == true)
        #expect(legacyOnly?.hasResistanceData == false)
    }

    @Test("A legacy spray line without a snapshot decodes cleanly")
    func legacyLineDecodes() throws {
        // Exactly the shape a pre-Chemical-Intelligence tank JSONB holds.
        let json = """
        {"id":"\(UUID().uuidString)","name":"Sulphur","volumePerTank":2000,
         "ratePerHa":2000,"ratePer100L":0,"costPerUnit":0,"unit":"Kg"}
        """
        let line = try JSONDecoder().decode(SprayChemical.self, from: Data(json.utf8))

        #expect(line.name == "Sulphur")
        #expect(line.chemicalSnapshot == nil)
        #expect(line.recordedActivityGroupCodes.isEmpty)
        #expect(line.hasResistanceSnapshot == false)
    }

    @Test("A snapshot records the RESOLVED status, not an optimistic claim")
    func snapshotRecordsResolvedStatus() throws {
        var intel = combinationProduct()
        intel.verification.addConflict(
            ChemicalVerificationConflict(
                field: "activity_group",
                extractedValue: "FRAC 11",
                authoritativeValue: "FRAC 3"
            )
        )
        intel.verification.status = .verified

        let snapshot = try #require(
            ChemicalLineSnapshot.capture(from: intel, legacyChemicalGroup: "")
        )
        // A spray must never claim its product was verified when the evidence
        // at the time said otherwise.
        #expect(snapshot.verificationStatus == .conflict)
    }

    // MARK: - Tolerant decoding

    @Test("An unknown activity group scheme degrades instead of failing the record")
    func unknownSchemeDegrades() throws {
        let json = #"{"scheme":"future_scheme","code":"99"}"#
        let group = try JSONDecoder().decode(ChemicalActivityGroup.self, from: Data(json.utf8))

        #expect(group.scheme == .notApplicable)
        #expect(group.isResistanceRelevant == false)
    }

    @Test("An unknown source kind is read as the weakest, never the strongest")
    func unknownSourceDegradesDownward() throws {
        let json = #"{"kind":"future_source","name":"Something new"}"#
        let source = try JSONDecoder().decode(ChemicalDataSource.self, from: Data(json.utf8))

        // Erring downward is the only safe direction for a trust claim.
        #expect(source.kind == .aiInterpretation)
        #expect(source.kind.isAuthoritative == false)
    }

    @Test("Group codes normalise so the same group never stores two ways")
    func codeNormalisation() {
        #expect(ChemicalActivityGroup.normaliseCode("Group 3") == "3")
        #expect(ChemicalActivityGroup.normaliseCode(" 11 (QoI / Strobilurin)") == "11")
        #expect(ChemicalActivityGroup.normaliseCode("frac 7") == "7")
        #expect(ChemicalActivityGroup.normaliseCode("m5") == "M5")
    }
}
