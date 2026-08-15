import Foundation
import Testing
@testable import VineTrack

/// Verification must not survive a manual change to the very value that was
/// verified, and must not be disturbed by an edit to anything else.
///
/// The Android suite `ChemicalEditReconcilerTest` asserts the same fixtures and
/// the same outcomes, because both apps write the same Supabase rows: a
/// resistance decision must not depend on which phone recorded the edit.
///
/// Every assertion here goes through `ChemicalEditReconciler` and then reads
/// `resolvedVerificationStatus`. None of them assign a status. That is the
/// point: the tests prove the EVIDENCE model reaches the right conclusion, so
/// no UI layer is ever in a position to declare something verified.
struct ChemicalEditReconcilerTests {

    // MARK: - Fixtures

    private func frac(_ code: String) -> ChemicalActivityGroup {
        ChemicalActivityGroup(scheme: .frac, code: code)
    }

    /// Azoxystrobin is in the reference table as FRAC 11.
    private func verifiedAzoxystrobin() -> ChemicalIntelligence {
        ChemicalIntelligence(
            activeIngredients: [
                ChemicalActiveIngredient(
                    name: "Azoxystrobin",
                    concentration: 250,
                    concentrationUnit: .gramsPerLitre,
                    activityGroup: frac("11"),
                    groupSource: .authoritativeClassification,
                    identitySource: .officialRegister
                )
            ],
            registration: ChemicalRegistration(
                countryCode: "AU",
                scheme: .apvma,
                registrationNumber: "62764",
                registrant: "Example Crop Science",
                registeredProductName: "Amistar 250"
            ),
            verification: ChemicalVerification(
                status: .verified,
                sources: [
                    ChemicalDataSource(kind: .officialRegister, name: "APVMA PUBCRIS"),
                    AuthoritativeActivityGroups.source()
                ],
                verifiedAt: Date(timeIntervalSince1970: 1_770_000_000)
            ),
            productCategory: "fungicide"
        )
    }

    /// A verified product whose active the reference table has NO opinion about,
    /// so a hand-typed group cannot be positively contradicted.
    private func verifiedUnknownActive() -> ChemicalIntelligence {
        var intel = verifiedAzoxystrobin()
        var active = intel.activeIngredients[0]
        active.name = "Vinclozolin-XT"
        intel.activeIngredients = [active]
        return intel
    }

    /// A saved chemical carrying verified structured chemistry, as the store
    /// would hand it to the edit form.
    private func verifiedSavedChemical() -> SavedChemical {
        let intel = verifiedAzoxystrobin()
        return SavedChemical(
            name: "Amistar 250",
            ratePerHa: 1,
            chemicalGroup: intel.legacyChemicalGroup,
            manufacturer: "Example Crop Science",
            notes: "Half drum left in the shed.",
            activeIngredient: intel.legacyActiveIngredient,
            productCategory: "fungicide",
            pricePerPack: 420,
            inventoryQuantity: 3,
            chemicalIntelligence: intel
        )
    }

    /// Replays exactly what the edit form does on save: reconcile the chemistry
    /// text currently in the boxes against the stored intelligence.
    private func outcome(
        for chemical: SavedChemical,
        activeIngredient: String? = nil,
        chemicalGroup: String? = nil,
        modeOfAction: String = "",
        manufacturer: String? = nil,
        productCategory: String? = nil
    ) -> ChemicalEditOutcome? {
        guard let stored = chemical.chemicalIntelligence, !stored.isEmpty else { return nil }
        return ChemicalEditReconciler.reconcileLegacyEdit(
            existing: stored,
            activeIngredientText: activeIngredient ?? chemical.activeIngredient,
            chemicalGroupText: chemicalGroup ?? chemical.chemicalGroup,
            modeOfActionText: modeOfAction,
            productCategory: productCategory ?? chemical.productCategory,
            registrantText: manufacturer ?? chemical.manufacturer
        )
    }

    // MARK: - Verified, nothing authoritative changed

    @Test("a verified chemical with no authoritative change stays verified")
    func noChangeStaysVerified() {
        let chemical = verifiedSavedChemical()
        #expect(chemical.verificationStatus == .verified)
        #expect(outcome(for: chemical) == nil)
    }

    // MARK: - Verified, manual group edit

    @Test("hand-changing FRAC 11 to FRAC 3 cannot leave the record verified")
    func groupEditCannotStayVerified() throws {
        let before = verifiedAzoxystrobin()
        #expect(before.resolvedVerificationStatus == .verified)

        let result = try #require(ChemicalEditReconciler.reconcileLegacyEdit(
            existing: before,
            activeIngredientText: before.legacyActiveIngredient,
            chemicalGroupText: "3",
            modeOfActionText: "",
            productCategory: "fungicide",
            registrantText: "Example Crop Science"
        ))

        #expect(result.resolvedStatus != .verified)
        #expect(result.isDowngrade)
        #expect(result.changedFields.contains(.activityGroupCode))
        // The reference table positively disagrees, so this is a conflict rather
        // than a mere absence of evidence.
        #expect(result.resolvedStatus == .conflict)
        #expect(!result.intelligence.verification.conflicts.isEmpty)
    }

    @Test("the operator's typed group is stored, not silently discarded")
    func typedGroupIsStored() throws {
        let result = try #require(ChemicalEditReconciler.reconcileLegacyEdit(
            existing: verifiedUnknownActive(),
            activeIngredientText: "Vinclozolin-XT 250 g/L",
            chemicalGroupText: "3",
            modeOfActionText: "",
            productCategory: "fungicide",
            registrantText: "Example Crop Science"
        ))

        let active = try #require(result.intelligence.activeIngredients.first)
        #expect(active.activityGroup?.code == "3")
        // Stored as the operator's own claim, which is why it cannot verify itself.
        #expect(active.groupSource == .manualEntry)
        #expect(!active.hasAuthoritativeGroup)
    }

    @Test("a group edit the reference table cannot judge falls to the surviving evidence")
    func unknownActiveFallsToRemainingEvidence() throws {
        let result = try #require(ChemicalEditReconciler.reconcileLegacyEdit(
            existing: verifiedUnknownActive(),
            activeIngredientText: "Vinclozolin-XT 250 g/L",
            chemicalGroupText: "3",
            modeOfActionText: "",
            productCategory: "fungicide",
            registrantText: "Example Crop Science"
        ))

        // No conflict is inventable, but the group is no longer authoritative —
        // and the registered identity still is. "Partially verified" is the
        // honest middle, and it is COMPUTED, not chosen.
        #expect(result.resolvedStatus == .partiallyVerified)
        #expect(result.resolvedStatus != .verified)
    }

    @Test("old evidence cannot endorse a changed value")
    func oldEvidenceIsWithdrawn() throws {
        let before = verifiedAzoxystrobin()
        #expect(before.verification.sources.containsAuthoritative)

        let result = try #require(ChemicalEditReconciler.reconcileLegacyEdit(
            existing: before,
            activeIngredientText: before.legacyActiveIngredient,
            chemicalGroupText: "3",
            modeOfActionText: "",
            productCategory: "fungicide",
            registrantText: "Example Crop Science"
        ))

        // The APVMA and FRAC citations described FRAC 11. They must not remain
        // attached as though they supported the newly typed FRAC 3.
        #expect(!result.intelligence.verification.sources.containsAuthoritative)
        #expect(result.intelligence.verification.sources.contains { $0.kind == .manualEntry })
        #expect(result.intelligence.verification.verifiedAt == nil)
        #expect(result.intelligence.activeIngredients.allSatisfy { !$0.hasAuthoritativeGroup })
    }

    @Test("correcting a group back to the authoritative value clears the conflict")
    func conflictClearsAfterCorrection() throws {
        let conflicted = try #require(ChemicalEditReconciler.reconcileLegacyEdit(
            existing: verifiedAzoxystrobin(),
            activeIngredientText: "Azoxystrobin 250 g/L",
            chemicalGroupText: "3",
            modeOfActionText: "",
            productCategory: "fungicide",
            registrantText: "Example Crop Science"
        ))
        #expect(conflicted.resolvedStatus == .conflict)

        // The operator realises the mistake and puts 11 back.
        let fixed = try #require(ChemicalEditReconciler.reconcileLegacyEdit(
            existing: conflicted.intelligence,
            activeIngredientText: "Azoxystrobin 250 g/L",
            chemicalGroupText: "11",
            modeOfActionText: "",
            productCategory: "fungicide",
            registrantText: "Example Crop Science"
        ))

        #expect(fixed.intelligence.verification.conflicts.isEmpty)
        // A record must be able to escape conflict, or one typo poisons it forever.
        #expect(fixed.resolvedStatus != .conflict)
    }

    // MARK: - Edits that must NOT touch verification

    @Test("a price edit leaves a verified product verified")
    func priceEditKeepsVerification() {
        var chemical = verifiedSavedChemical()
        chemical.pricePerPack = 515
        chemical.purchase = ChemicalPurchase(costDollars: 515, containerSizeML: 10, containerUnit: .litres)

        #expect(outcome(for: chemical) == nil)
        #expect(chemical.verificationStatus == .verified)
    }

    @Test("a supplier and pack edit leaves a verified product verified")
    func supplierAndPackEditKeepsVerification() {
        var chemical = verifiedSavedChemical()
        chemical.packSize = 20
        chemical.packUnit = "L"
        chemical.restrictions = "Ordered through a different supplier this season."

        #expect(outcome(for: chemical) == nil)
        #expect(chemical.verificationStatus == .verified)
    }

    @Test("a notes edit leaves a verified product verified")
    func notesEditKeepsVerification() {
        var chemical = verifiedSavedChemical()
        chemical.notes = "Use the older drum first."
        chemical.applicationNotes = "Avoid spraying above 28 degrees."

        #expect(outcome(for: chemical) == nil)
        #expect(chemical.verificationStatus == .verified)
    }

    @Test("a stock edit leaves a verified product verified")
    func stockEditKeepsVerification() {
        var chemical = verifiedSavedChemical()
        chemical.inventoryQuantity = 1
        chemical.inventoryUnit = "packs"

        #expect(outcome(for: chemical) == nil)
        #expect(chemical.verificationStatus == .verified)
    }

    @Test("changing the grower's preferred rate leaves a verified product verified")
    func preferredRateEditKeepsVerification() {
        var chemical = verifiedSavedChemical()
        chemical.ratePerHa = 1.6
        chemical.rates = [ChemicalRate(label: "Per Ha", value: 1_600, basis: .perHectare)]

        // The grower's own preferred rate is an operational preference, not a
        // label claim. Only STRUCTURED label rates are resistance-critical.
        #expect(outcome(for: chemical) == nil)
        #expect(chemical.verificationStatus == .verified)
    }

    @Test("a harmless product rename does not disturb a registered identity")
    func renameKeepsVerification() {
        var chemical = verifiedSavedChemical()
        chemical.name = "Amistar 250 (old stock)"

        // Once a registration number is known, THAT is the identity; the display
        // name is the grower's to tidy.
        #expect(outcome(for: chemical) == nil)
        #expect(chemical.verificationStatus == .verified)
        #expect(chemical.resolvedIntelligence.registration?.identityKey == "AU:apvma:62764")
    }

    @Test("re-typing the same chemistry in different case and spacing is not a change")
    func whitespaceAndCaseAreNotChanges() {
        let before = verifiedAzoxystrobin()

        let result = ChemicalEditReconciler.reconcileLegacyEdit(
            existing: before,
            activeIngredientText: "  azoxystrobin   250 g/L ",
            chemicalGroupText: " \(before.legacyChemicalGroup) ",
            modeOfActionText: "",
            productCategory: "fungicide",
            registrantText: " example crop science "
        )

        // Whitespace and capitalisation are not evidence of anything.
        #expect(result == nil)
    }

    // MARK: - Registration edits

    @Test("changing the registrant re-resolves the claim")
    func registrantChangeDowngrades() throws {
        let result = try #require(ChemicalEditReconciler.reconcileLegacyEdit(
            existing: verifiedAzoxystrobin(),
            activeIngredientText: "Azoxystrobin 250 g/L",
            chemicalGroupText: "11",
            modeOfActionText: "",
            productCategory: "fungicide",
            registrantText: "A Completely Different Registrant"
        ))

        #expect(result.changedFields.contains(.productIdentity))
        #expect(result.resolvedStatus != .verified)
    }

    @Test("changing the registration number invalidates the inherited identity")
    func registrationNumberChangeDowngrades() {
        let before = verifiedAzoxystrobin()
        var proposed = before
        var registration = before.registration
        registration?.registrationNumber = "99999"
        proposed.registration = registration

        let result = ChemicalEditReconciler.reconcile(existing: before, proposed: proposed)

        #expect(result.changedFields.contains(.registrationIdentifier))
        #expect(result.resolvedStatus != .verified)
    }

    @Test("changing the registration scheme invalidates the inherited identity")
    func registrationSchemeChangeDowngrades() {
        let before = verifiedAzoxystrobin()
        var proposed = before
        var registration = before.registration
        registration?.scheme = .acvm
        proposed.registration = registration

        let result = ChemicalEditReconciler.reconcile(existing: before, proposed: proposed)

        #expect(result.changedFields.contains(.registrationScheme))
        #expect(result.resolvedStatus != .verified)
    }

    @Test("changing the country makes it a different registered product")
    func countryChangeDowngrades() {
        let before = verifiedAzoxystrobin()
        var proposed = before
        var registration = before.registration
        registration?.countryCode = "NZ"
        proposed.registration = registration

        let result = ChemicalEditReconciler.reconcile(existing: before, proposed: proposed)

        #expect(result.changedFields.contains(.country))
        #expect(result.resolvedStatus != .verified)
    }

    // MARK: - Active ingredient and concentration edits

    @Test("changing a concentration re-resolves the claim")
    func concentrationChangeDowngrades() {
        let before = verifiedAzoxystrobin()
        var proposed = before
        var active = before.activeIngredients[0]
        active.concentration = 500
        proposed.activeIngredients = [active]

        let result = ChemicalEditReconciler.reconcile(existing: before, proposed: proposed)

        #expect(result.changedFields.contains(.activeConcentration))
        #expect(result.resolvedStatus != .verified)
    }

    @Test("adding an active to a verified mixture cannot inherit verification")
    func addedActiveCannotInheritVerification() throws {
        let before = verifiedAzoxystrobin()
        var proposed = before
        proposed.activeIngredients = before.activeIngredients + [
            ChemicalActiveIngredient(name: "Tebuconazole", activityGroup: frac("3"))
        ]

        let result = ChemicalEditReconciler.reconcile(existing: before, proposed: proposed)

        #expect(result.changedFields.contains(.activeIngredients))
        #expect(result.resolvedStatus != .verified)
        // The untouched active keeps its authoritative classification: evidence
        // belongs to a value, so only the changed part loses its backing.
        let kept = try #require(result.intelligence.activeIngredients.first { $0.name == "Azoxystrobin" })
        #expect(kept.hasAuthoritativeGroup)
    }

    // MARK: - Structured label rates and registered uses

    @Test("changing a structured label rate is recorded as resistance critical")
    func labelRateChangeIsCritical() throws {
        var before = verifiedAzoxystrobin()
        before.registeredUses = [
            ChemicalRegisteredUse(
                crop: "Grapes (winegrapes)",
                targetRaw: "Powdery mildew",
                rates: [ChemicalLabelRate(label: "Standard", basis: .perHectare, value: 1, unit: "L")]
            )
        ]

        var proposed = before
        var use = try #require(before.registeredUses.first)
        use.rates = [ChemicalLabelRate(label: "Standard", basis: .perHectare, value: 2, unit: "L")]
        proposed.registeredUses = [use]

        let result = ChemicalEditReconciler.reconcile(existing: before, proposed: proposed)

        #expect(result.changedFields.contains(.labelRates))
        #expect(result.changedFields.contains(.registeredUses))
        #expect(result.resolvedStatus != .verified)
    }

    @Test("changing a registered use is recorded as resistance critical")
    func registeredUseChangeIsCritical() {
        var before = verifiedAzoxystrobin()
        before.registeredUses = [
            ChemicalRegisteredUse(crop: "Grapes (winegrapes)", targetRaw: "Powdery mildew")
        ]

        var proposed = before
        proposed.registeredUses = [
            ChemicalRegisteredUse(crop: "Grapes (winegrapes)", targetRaw: "Powdery mildew"),
            ChemicalRegisteredUse(crop: "Grapes (winegrapes)", targetRaw: "Downy mildew")
        ]

        let result = ChemicalEditReconciler.reconcile(existing: before, proposed: proposed)

        #expect(result.changedFields.contains(.registeredUses))
        #expect(result.resolvedStatus != .verified)
    }

    // MARK: - Stale stored status and promotion

    @Test("a stored verified status is not believed when the evidence is incomplete")
    func staleStoredStatusIsNotBelieved() {
        // Exactly the shape a stale or hand-patched database row would have:
        // status says verified, but no authoritative group and no registration.
        let stale = ChemicalIntelligence(
            activeIngredients: [
                ChemicalActiveIngredient(
                    name: "Azoxystrobin",
                    activityGroup: frac("11"),
                    groupSource: .aiInterpretation
                )
            ],
            verification: ChemicalVerification(status: .verified)
        )

        #expect(stale.resolvedVerificationStatus != .verified)
    }

    @Test("a stored verified status is not believed when a conflict is attached")
    func conflictOverridesStoredStatus() {
        var intel = verifiedAzoxystrobin()
        intel.verification.addConflict(
            ChemicalVerificationConflict(
                field: "activity_group",
                activeIngredientName: "Azoxystrobin",
                extractedValue: "FRAC 3",
                authoritativeValue: "FRAC 11"
            )
        )
        intel.verification.status = .verified

        #expect(intel.resolvedVerificationStatus == .conflict)
    }

    @Test("the reconciler never promotes verification automatically")
    func reconcilerNeverPromotes() {
        let manual = ChemicalIntelligence(
            activeIngredients: [
                ChemicalActiveIngredient(
                    name: "Tebuconazole",
                    activityGroup: frac("3"),
                    groupSource: .manualEntry
                )
            ],
            verification: .manual()
        )

        var proposed = manual
        var active = manual.activeIngredients[0]
        active.concentration = 200
        proposed.activeIngredients = [active]
        // Someone tries to hand the model a verified claim it has not earned.
        proposed.verification.status = .verified

        let result = ChemicalEditReconciler.reconcile(existing: manual, proposed: proposed)

        #expect(result.resolvedStatus != .verified)
        #expect(result.intelligence.verification.status != .verified)
    }

    @Test("an operator-facing warning is offered only when trust actually falls")
    func warningOnlyOnRealDowngrade() throws {
        let downgraded = try #require(ChemicalEditReconciler.reconcileLegacyEdit(
            existing: verifiedAzoxystrobin(),
            activeIngredientText: "Azoxystrobin 250 g/L",
            chemicalGroupText: "3",
            modeOfActionText: "",
            productCategory: "fungicide",
            registrantText: "Example Crop Science"
        ))
        #expect(downgraded.warning?.isEmpty == false)

        // A manual record has nothing to lose, so it is not warned.
        let alreadyUnverified = ChemicalIntelligence(
            activeIngredients: [
                ChemicalActiveIngredient(
                    name: "Vinclozolin-XT",
                    activityGroup: frac("3"),
                    groupSource: .manualEntry
                )
            ],
            verification: .manual()
        )
        var proposed = alreadyUnverified
        var active = alreadyUnverified.activeIngredients[0]
        active.concentration = 200
        proposed.activeIngredients = [active]

        let result = ChemicalEditReconciler.reconcile(existing: alreadyUnverified, proposed: proposed)
        #expect(result.warning == nil)
    }

    // MARK: - Legacy compatibility projections stay derived

    @Test("legacy scalars remain derived projections of the reconciled chemistry")
    func legacyScalarsStayDerived() throws {
        let result = try #require(ChemicalEditReconciler.reconcileLegacyEdit(
            existing: verifiedAzoxystrobin(),
            activeIngredientText: "Azoxystrobin 250 g/L",
            chemicalGroupText: "3",
            modeOfActionText: "",
            productCategory: "fungicide",
            registrantText: "Example Crop Science"
        ))

        var chemical = verifiedSavedChemical()
        chemical.chemicalIntelligence = result.intelligence

        // The scalar mirrors what the structured groups now say — it is written
        // FROM the model, never read back into it.
        #expect(chemical.legacyProjection.chemicalGroup == "3")
        #expect(chemical.resolvedIntelligence.activityGroupCodes == ["3"])
    }
}
