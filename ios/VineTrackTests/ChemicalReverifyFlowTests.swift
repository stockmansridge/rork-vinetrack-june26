import Foundation
import Testing
@testable import VineTrack

/// The Re-verify Chemical screen's actual behaviour.
///
/// These drive `ChemicalReverifyFlow` — the same object `ChemicalReverifyFlowView`
/// drives — rather than re-deriving the sequence, so a rule cannot pass here while
/// the screen does something else. The Android suite `ChemicalReverifyFlowTest`
/// asserts the same fixtures and the same outcomes.
///
/// Four properties are under protection:
///
///  1. Cancel is writing nothing, by construction.
///  2. Accept writes the outcome that was PREVIEWED, through the reconciler.
///  3. A failed or empty lookup never downgrades a record.
///  4. A completed spray's frozen snapshot survives any accepted update.
struct ChemicalReverifyFlowTests {

    private let at = Date(timeIntervalSince1970: 1_786_000_000)
    private let chemId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    /// Deliberately not a real active — see the note in `ChemicalReverificationTests`.
    /// A fixture that legitimately moves FRAC 11 → 3 cannot use a real active,
    /// because the reference table knows the real classification and would
    /// correctly raise a conflict (asserted separately below).
    private let referenceActive = "Examplestrobin"

    // MARK: - Fixtures

    private func frac(_ code: String) -> ChemicalActivityGroup {
        ChemicalActivityGroup(scheme: .frac, code: code)
    }

    private func active(
        _ name: String,
        _ concentration: Double? = nil,
        _ group: ChemicalActivityGroup? = nil,
        authoritative: Bool = true
    ) -> ChemicalActiveIngredient {
        ChemicalActiveIngredient(
            name: name,
            concentration: concentration,
            concentrationUnit: concentration == nil ? nil : .gramsPerLitre,
            activityGroup: group,
            groupSource: group == nil
                ? nil
                : (authoritative ? .authoritativeClassification : .manualEntry),
            identitySource: .officialRegister
        )
    }

    private func registration(labelVersion: String? = nil) -> ChemicalRegistration {
        ChemicalRegistration(
            countryCode: "AU",
            scheme: .apvma,
            registrationNumber: "62764",
            registrant: "Example Crop Science",
            registeredProductName: "Example Fungicide",
            labelVersion: labelVersion
        )
    }

    private func verifiedEvidence(
        conflicts: [ChemicalVerificationConflict] = [],
        extraSource: ChemicalDataSource? = nil
    ) -> ChemicalVerification {
        var sources: [ChemicalDataSource] = [
            ChemicalDataSource(kind: .officialRegister, name: "APVMA PUBCRIS"),
            AuthoritativeActivityGroups.source()
        ]
        if let extraSource { sources.append(extraSource) }
        return ChemicalVerification(
            status: .verified,
            sources: sources,
            verifiedAt: at,
            conflicts: conflicts
        )
    }

    private func group11(
        labelVersion: String? = nil,
        uses: [ChemicalRegisteredUse] = [],
        verification: ChemicalVerification? = nil
    ) -> ChemicalIntelligence {
        ChemicalIntelligence(
            activeIngredients: [active(referenceActive, 250, frac("11"))],
            registration: registration(labelVersion: labelVersion),
            verification: verification ?? verifiedEvidence(),
            registeredUses: uses,
            productCategory: "fungicide",
            activityGroupTableVersion: AuthoritativeActivityGroups.tableVersion,
            schemaVersion: ChemicalIntelligence.currentSchemaVersion
        )
    }

    private func group3() -> ChemicalIntelligence {
        var intel = group11()
        intel.activeIngredients = [active(referenceActive, 250, frac("3"))]
        return intel
    }

    private func use(
        crop: String = "Grapes",
        target: String = "Powdery mildew",
        rates: [ChemicalLabelRate] = [],
        whp: Int? = nil,
        reEntry: Int? = nil
    ) -> ChemicalRegisteredUse {
        ChemicalRegisteredUse(
            crop: crop,
            targetRaw: target,
            rates: rates,
            withholdingPeriodDays: whp,
            reEntryPeriodHours: reEntry
        )
    }

    private func rate(
        _ basis: ChemicalLabelRateBasis,
        value: Double? = nil,
        min: Double? = nil,
        max: Double? = nil,
        unit: String = "mL"
    ) -> ChemicalLabelRate {
        ChemicalLabelRate(basis: basis, value: value, minValue: min, maxValue: max, unit: unit)
    }

    /// A store record carrying real operational data the grower maintains.
    ///
    /// The pack size, price, stock and notes are here on purpose: accepting a
    /// re-verification must upgrade the chemistry without discarding years of
    /// inventory and costing.
    private func savedChemical(
        intelligence: ChemicalIntelligence? = nil,
        activeIngredient: String = "",
        chemicalGroup: String = ""
    ) -> SavedChemical {
        SavedChemical(
            id: chemId,
            name: "Example Fungicide",
            chemicalGroup: chemicalGroup,
            manufacturer: "Example Crop Science",
            notes: "Shed B, top shelf",
            activeIngredient: activeIngredient,
            modeOfAction: "",
            productCategory: "fungicide",
            packSize: 10,
            pricePerPack: 425,
            inventoryQuantity: 3,
            applicationNotes: "Do not tank-mix with oil",
            isActive: true,
            chemicalIntelligence: intelligence
        )
    }

    // MARK: - Result extraction

    private typealias ChangesResult = (
        candidate: ChemicalIntelligence,
        diff: ChemicalIntelligenceDiff,
        outcome: ChemicalEditOutcome
    )

    private func changes(
        _ stored: SavedChemical,
        _ candidate: ChemicalIntelligence
    ) -> ChangesResult? {
        if case let .changes(c, d, o) = ChemicalReverifyFlow.resolve(
            chemical: stored, candidate: candidate, at: at
        ) {
            return (c, d, o)
        }
        return nil
    }

    private func current(
        _ stored: SavedChemical,
        _ candidate: ChemicalIntelligence
    ) -> (candidate: ChemicalIntelligence, refreshed: ChemicalIntelligence?)? {
        if case let .current(c, r) = ChemicalReverifyFlow.resolve(
            chemical: stored, candidate: candidate, at: at
        ) {
            return (c, r)
        }
        return nil
    }

    // MARK: - No change

    @Test("An unchanged product resolves to the current result")
    func unchangedResolvesToCurrent() throws {
        let result = try #require(current(savedChemical(intelligence: group11()), group11()))

        let refreshed = try #require(result.refreshed)
        // Chemistry untouched on a no-change confirmation.
        #expect(refreshed.activityGroupCodes == ["11"])
    }

    @Test("A no-change result on a legacy-only record refreshes nothing")
    func noChangeOnLegacyRecordRefreshesNothing() throws {
        // A record with no structured intelligence has only a legacy SEED. A
        // "nothing changed" answer must not become that record's first structured
        // write, or re-verification would quietly materialise a guess as data.
        let legacy = savedChemical(
            activeIngredient: "\(referenceActive) 250 g/L",
            chemicalGroup: "11"
        )
        let candidate = try #require(ChemicalReverifyFlow.currentIntelligence(legacy))

        let result = try #require(current(legacy, candidate))

        #expect(result.refreshed == nil)
    }

    // MARK: - Group change

    @Test("A group change reaches the review screen as a resistance-critical change")
    func groupChangeReachesReview() throws {
        let result = try #require(changes(savedChemical(intelligence: group11()), group3()))

        let change = try #require(
            result.diff.changes.first { $0.field == .activityGroupCode }
        )
        #expect(change.currentValue == "FRAC 11")
        #expect(change.candidateValue == "FRAC 3")
        #expect(change.isResistanceCritical)
        #expect(result.diff.hasResistanceCriticalChanges)
        // Chemistry leads the screen.
        #expect(result.diff.populatedSections.first == .activityGroups)
    }

    // MARK: - Actives and concentration

    @Test("An active added and removed both reach the review screen")
    func activeAddedAndRemovedReachReview() throws {
        var candidate = group11()
        candidate.activeIngredients = [active("Tebuconazole", 200, frac("3"))]

        let result = try #require(changes(savedChemical(intelligence: group11()), candidate))

        let actives = result.diff.changes.filter { $0.field == .activeIngredient }
        #expect(actives.count == 2)
        #expect(actives.contains { $0.kind == .added })
        #expect(actives.contains { $0.kind == .removed })
    }

    @Test("A concentration change reaches the review screen")
    func concentrationChangeReachesReview() throws {
        var candidate = group11()
        candidate.activeIngredients = [active(referenceActive, 200, frac("11"))]

        let result = try #require(changes(savedChemical(intelligence: group11()), candidate))

        let change = try #require(
            result.diff.changes.first { $0.field == .activeConcentration }
        )
        #expect(change.currentValue == "250 g/L")
        #expect(change.candidateValue == "200 g/L")
    }

    // MARK: - Label rates

    @Test("A rate value change reaches the review screen as one change")
    func rateValueChangeIsOneChange() throws {
        let stored = savedChemical(
            intelligence: group11(uses: [use(rates: [rate(.per100Litres, value: 100)])])
        )
        let candidate = group11(uses: [use(rates: [rate(.per100Litres, min: 80, max: 100)])])

        let result = try #require(changes(stored, candidate))

        let rateChanges = result.diff.changes.filter { $0.field == .labelRate }
        #expect(rateChanges.count == 1)
        #expect(rateChanges.first?.kind == .changed)
        #expect(rateChanges.first?.currentValue == "100 mL/100 L")
        #expect(rateChanges.first?.candidateValue == "80–100 mL/100 L")
    }

    @Test("A rate basis change reaches the review screen as a removal and an addition")
    func rateBasisChangeIsAddAndRemove() throws {
        let stored = savedChemical(
            intelligence: group11(uses: [use(rates: [rate(.per100Litres, value: 100)])])
        )
        let candidate = group11(
            uses: [use(rates: [rate(.perHectare, value: 1.5, unit: "L")])]
        )

        let result = try #require(changes(stored, candidate))

        let rateChanges = result.diff.changes.filter { $0.field == .labelRate }
        #expect(rateChanges.count == 2)
        #expect(rateChanges.contains { $0.kind == .added })
        #expect(rateChanges.contains { $0.kind == .removed })
    }

    // MARK: - Registered uses, WHP, re-entry

    @Test("A registered use change reaches the review screen")
    func registeredUseChangeReachesReview() throws {
        let stored = savedChemical(
            intelligence: group11(uses: [use(target: "Powdery mildew")])
        )
        let candidate = group11(
            uses: [use(target: "Powdery mildew"), use(target: "Downy mildew")]
        )

        let result = try #require(changes(stored, candidate))

        let change = try #require(result.diff.changes.first { $0.field == .registeredUse })
        #expect(change.kind == .added)
        #expect(change.candidateValue == "Grapes — Downy mildew")
        // Administrative, so it must not be dressed up as resistance news.
        #expect(!change.isResistanceCritical)
    }

    @Test("A withholding and re-entry change reaches the review screen")
    func withholdingAndReEntryChangeReachReview() throws {
        let stored = savedChemical(intelligence: group11(uses: [use(whp: 14, reEntry: 24)]))
        let candidate = group11(uses: [use(whp: 21, reEntry: 48)])

        let result = try #require(changes(stored, candidate))

        #expect(
            result.diff.changes.first { $0.field == .withholdingPeriod }?.candidateValue
                == "21 days"
        )
        #expect(
            result.diff.changes.first { $0.field == .reEntryPeriod }?.candidateValue
                == "48 hours"
        )
    }

    // MARK: - Source and version changes

    @Test("A source and label version change is a current result not an update")
    func evidenceOnlyChangeIsCurrent() throws {
        // Evidence-only movement is "current, freshly confirmed". Presenting a new
        // retrieval date as a product update is how operators learn to click
        // through review screens without reading them.
        let stored = savedChemical(intelligence: group11(labelVersion: "2024-06"))
        let candidate = group11(
            labelVersion: "2026-02",
            verification: verifiedEvidence(
                extraSource: ChemicalDataSource(
                    kind: .officialRegister,
                    name: "APVMA label PDF"
                )
            )
        )

        let result = try #require(current(stored, candidate))

        let refreshed = try #require(result.refreshed)
        // Chemistry untouched, provenance refreshed.
        #expect(refreshed.activityGroupCodes == ["11"])
        #expect(refreshed.registration?.labelVersion == "2026-02")
        #expect(refreshed.verification.sources.contains { $0.name == "APVMA label PDF" })
    }

    // MARK: - Conflict

    @Test("A conflicted candidate reaches review without a verified result")
    func conflictedCandidateCannotVerify() throws {
        var conflicted = group3()
        conflicted.verification = verifiedEvidence(
            conflicts: [
                ChemicalVerificationConflict(
                    field: "concentration",
                    activeIngredientName: referenceActive,
                    extractedValue: "250 g/L",
                    authoritativeValue: "200 g/L"
                )
            ]
        )

        let result = try #require(changes(savedChemical(intelligence: group11()), conflicted))

        // The screen renders the outcome's conflicts, so they must survive here.
        #expect(!result.outcome.intelligence.verification.conflicts.isEmpty)
        #expect(result.outcome.resolvedStatus == .conflict)
        #expect(!result.outcome.resolvedStatus.isResistanceDependable)
    }

    @Test("A contradicting group on a known active reaches review as a conflict")
    func contradictingKnownActiveConflicts() throws {
        // Azoxystrobin is authoritatively FRAC 11. A lookup claiming FRAC 3 is a
        // disagreement, not an update, and the review screen must say so.
        var storedIntel = group11()
        storedIntel.activeIngredients = [active("Azoxystrobin", 250, frac("11"))]
        var contradicting = group11()
        contradicting.activeIngredients = [active("Azoxystrobin", 250, frac("3"))]

        let result = try #require(
            changes(savedChemical(intelligence: storedIntel), contradicting)
        )

        #expect(result.outcome.resolvedStatus == .conflict)
        #expect(!result.outcome.intelligence.verification.conflicts.isEmpty)
    }

    // MARK: - Lookup failure

    @Test("An empty lookup result is unusable and changes nothing")
    func emptyLookupIsUnusable() throws {
        let stored = savedChemical(intelligence: group11())
        let before = try JSONEncoder().encode(stored)

        let result = ChemicalReverifyFlow.resolve(
            chemical: stored,
            candidate: ChemicalIntelligence(),
            at: at
        )

        guard case .unusable = result else {
            Issue.record("an empty candidate must be unusable, never a diff")
            return
        }
        // A failed check is not evidence about the product, so nothing moves and
        // the record keeps the verification it already earned.
        #expect(try JSONEncoder().encode(stored) == before)
        #expect(stored.verificationStatus == .verified)
        #expect(stored.activityGroupCodes == ["11"])
    }

    // MARK: - Cancel

    @Test("Cancelling a reviewed change leaves the record untouched")
    func cancelLeavesRecordUntouched() throws {
        let stored = savedChemical(intelligence: group11())
        let before = try JSONEncoder().encode(stored)

        // Reviewing is the whole of a cancelled re-verification: resolve, show,
        // drop. Cancel is safe because no flow function mutates anything.
        let result = try #require(changes(stored, group3()))
        #expect(result.diff.hasMeaningfulChanges)

        #expect(try JSONEncoder().encode(stored) == before)
        #expect(stored.activityGroupCodes == ["11"])
        #expect(stored.verificationStatus == .verified)
    }

    // MARK: - Accept

    @Test("Accepting writes the previewed outcome to the current record")
    func acceptWritesPreviewedOutcome() throws {
        let stored = savedChemical(intelligence: group11())
        let result = try #require(changes(stored, group3()))

        let updated = ChemicalReverifyFlow.accepted(stored, with: result.outcome)

        #expect(updated.activityGroupCodes == ["3"])
        // Compatibility scalars stay derived from the structured truth.
        #expect(updated.chemicalGroup == "3")
        #expect(updated.activeIngredient.contains(referenceActive))
        // The Chemical Store row reads the resolved status, so it updates at once.
        #expect(updated.verificationStatus == .verified)
        // And the written intelligence is exactly what was previewed.
        #expect(updated.chemicalIntelligence == result.outcome.intelligence)
    }

    @Test("Accepting an update keeps the operational data the grower maintains")
    func acceptKeepsOperationalData() throws {
        let stored = savedChemical(intelligence: group11())
        let result = try #require(changes(stored, group3()))

        let updated = ChemicalReverifyFlow.accepted(stored, with: result.outcome)

        // Upgrading chemistry must not cost the grower their inventory and costing.
        #expect(updated.packSize == 10)
        #expect(updated.pricePerPack == 425)
        #expect(updated.inventoryQuantity == 3)
        #expect(updated.notes == "Shed B, top shelf")
        #expect(updated.applicationNotes == "Do not tank-mix with oil")
    }

    @Test("Accepting cannot force verified from an AI-only reading")
    func acceptCannotForceVerifiedFromAI() throws {
        let stored = savedChemical(intelligence: group11())
        var aiCandidate = group3()
        aiCandidate.activeIngredients = [
            active(referenceActive, 250, frac("3"), authoritative: false)
        ]
        aiCandidate.verification = ChemicalVerification(
            status: .verified,
            sources: [ChemicalDataSource(kind: .aiInterpretation, name: "Search summary")]
        )

        let result = try #require(changes(stored, aiCandidate))

        // Completeness is not evidence. There is no path here that sets verified.
        #expect(!result.outcome.resolvedStatus.isResistanceDependable)
        #expect(result.outcome.isDowngrade)
    }

    // MARK: - Current status refresh

    @Test("Confirming a current result writes evidence only")
    func confirmCurrentWritesEvidenceOnly() throws {
        let stored = savedChemical(intelligence: group11(labelVersion: "2024-06"))
        let result = try #require(current(stored, group11(labelVersion: "2026-02")))
        let refreshed = try #require(result.refreshed)

        let updated = ChemicalReverifyFlow.confirmed(stored, with: refreshed)

        // Same chemistry, fresher provenance.
        #expect(updated.activityGroupCodes == ["11"])
        #expect(updated.chemicalIntelligence?.registration?.labelVersion == "2026-02")
        #expect(updated.chemicalIntelligence?.verification.verifiedAt == at)
        // And no meaningless product change was invented.
        #expect(updated.chemicalIntelligence?.activeIngredients == group11().activeIngredients)
    }

    // MARK: - Historical immutability

    @Test("Accepting an update never touches a completed spray snapshot")
    func acceptNeverTouchesHistory() throws {
        let stored = savedChemical(intelligence: group11())
        // A spray completed while the product was FRAC 11.
        let line = SprayChemical(
            name: "Example Fungicide",
            ratePerHa: 1500,
            savedChemicalId: stored.id,
            chemicalSnapshot: ChemicalSnapshotCapture.capture(stored, at: at)
        )
        let frozen = try #require(line.chemicalSnapshot)

        // The operator re-verifies onto FRAC 3 and accepts, through the real path.
        let result = try #require(changes(stored, group3()))
        let updated = ChemicalReverifyFlow.accepted(stored, with: result.outcome)

        // Current record moved.
        #expect(updated.activityGroupCodes == ["3"])
        // Completed application did not, in any frozen dimension.
        #expect(line.chemicalSnapshot?.activityGroupCodes == ["11"])
        #expect(frozen.verificationStatus == .verified)
        #expect(frozen.activityGroupTableVersion == AuthoritativeActivityGroups.tableVersion)
        #expect(frozen.capturedAt == at)
        #expect(frozen.registrationIdentityKey == "AU:apvma:62764")

        // Still true through a persist/reload cycle.
        let data = try JSONEncoder().encode(line)
        let reloaded = try JSONDecoder().decode(SprayChemical.self, from: data)
        #expect(reloaded.chemicalSnapshot == frozen)
    }

    @Test("Confirming a current result never touches a completed spray snapshot")
    func confirmNeverTouchesHistory() throws {
        let stored = savedChemical(intelligence: group11(labelVersion: "2024-06"))
        let line = SprayChemical(
            name: "Example Fungicide",
            ratePerHa: 1500,
            savedChemicalId: stored.id,
            chemicalSnapshot: ChemicalSnapshotCapture.capture(stored, at: at)
        )
        let frozen = try #require(line.chemicalSnapshot)

        let result = try #require(current(stored, group11(labelVersion: "2026-02")))
        let refreshed = try #require(result.refreshed)
        _ = ChemicalReverifyFlow.confirmed(stored, with: refreshed)

        // A freshly confirmed check must not restamp a completed application.
        // `capturedAt` is the one that matters most here: if refreshing evidence
        // could move it, the audit trail would claim the spray was recorded
        // against information that did not exist on the day it was applied.
        #expect(frozen.capturedAt == at)
        #expect(frozen.activityGroupCodes == ["11"])
        #expect(frozen.verificationStatus == .verified)
        #expect(line.chemicalSnapshot == frozen)
    }

    // MARK: - Entry-point eligibility comes from the domain

    @Test("The entry point is offered exactly where the domain says it is")
    func entryPointMatchesDomain() {
        // Verified, partially verified, unverified and conflicted records all hold
        // an identity worth re-checking.
        for status in [
            ChemicalVerificationStatus.verified,
            .partiallyVerified,
            .unverified,
            .conflict
        ] {
            var intel = group11()
            intel.verification.status = status
            #expect(
                ChemicalReverification.isOffered(
                    for: savedChemical(intelligence: intel),
                    fallbackCountry: "AU"
                ),
                "expected Re-verify offered for \(status.rawValue)"
            )
        }

        // A legacy record with nothing but a typed name goes to Match & Verify.
        let legacy = savedChemical(activeIngredient: "Azoxystrobin", chemicalGroup: "11")
        #expect(!ChemicalReverification.isOffered(for: legacy, fallbackCountry: "AU"))
        #expect(
            ChemicalReverification.unavailableReason(for: legacy, fallbackCountry: "AU") != nil
        )
    }

    @Test("The lookup leads with the held registration rather than the brand name")
    func lookupLeadsWithRegistration() {
        let plan = ChemicalReverification.plan(
            for: savedChemical(intelligence: group11()),
            fallbackCountry: "AU"
        )

        #expect(plan.strength == .registrationIdentity)
        // Re-verification must not restart as a broad product-name search.
        #expect(plan.lookupQuery.contains("62764"))
        #expect(plan.lookupQuery.contains("APVMA"))
    }
}
