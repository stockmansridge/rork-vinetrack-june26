import Foundation
import Testing
@testable import VineTrack

/// Re-verification, the old → new diff, and the chemical-intelligence
/// availability contract.
///
/// The Android suite `ChemicalReverificationTest` asserts the same fixtures and
/// the same outcomes. Four rules are under protection here:
///
///  1. A diff compares MEANING, so reordering is never reported as a change.
///  2. Cancel writes nothing; Accept changes only the current record.
///  3. A completed spray's frozen snapshot survives any re-verification.
///  4. An absent snapshot is "cannot assess", never "no concern".
struct ChemicalReverificationTests {

    private let at = Date(timeIntervalSince1970: 1_786_000_000)
    private let chemId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    /// The reference product's active, deliberately NOT a real one.
    ///
    /// A fixture that legitimately moves from FRAC 11 to FRAC 3 cannot use a real
    /// active, because `AuthoritativeActivityGroups` knows the real
    /// classification and would correctly raise a conflict — see
    /// `knownActiveOntoContradictingGroupConflicts`, which asserts exactly that.
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

    private func registration(
        number: String? = "62764",
        registrant: String? = "Example Crop Science",
        labelVersion: String? = nil
    ) -> ChemicalRegistration {
        ChemicalRegistration(
            countryCode: "AU",
            scheme: .apvma,
            registrationNumber: number,
            registrant: registrant,
            registeredProductName: "Example Fungicide",
            labelVersion: labelVersion
        )
    }

    private func verifiedEvidence(
        conflicts: [ChemicalVerificationConflict] = []
    ) -> ChemicalVerification {
        ChemicalVerification(
            status: .verified,
            sources: [
                ChemicalDataSource(kind: .officialRegister, name: "APVMA PUBCRIS"),
                AuthoritativeActivityGroups.source()
            ],
            verifiedAt: at,
            conflicts: conflicts
        )
    }

    private func group11(
        labelVersion: String? = nil,
        uses: [ChemicalRegisteredUse] = []
    ) -> ChemicalIntelligence {
        ChemicalIntelligence(
            activeIngredients: [active(referenceActive, 250, frac("11"))],
            registration: registration(labelVersion: labelVersion),
            verification: verifiedEvidence(),
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

    private func savedChemical(
        intelligence: ChemicalIntelligence? = nil,
        activeIngredient: String = "",
        chemicalGroup: String = "",
        manufacturer: String = "Example Crop Science"
    ) -> SavedChemical {
        SavedChemical(
            id: chemId,
            name: "Example Fungicide",
            chemicalGroup: chemicalGroup,
            manufacturer: manufacturer,
            activeIngredient: activeIngredient,
            modeOfAction: "",
            productCategory: "fungicide",
            isActive: true,
            chemicalIntelligence: intelligence
        )
    }

    // MARK: - Phase 25: no change

    @Test("Identical current and candidate produce an empty diff")
    func identicalIsEmpty() {
        let diff = ChemicalIntelligenceDiffer.diff(current: group11(), candidate: group11())

        #expect(diff.isEmpty)
        #expect(!diff.hasMeaningfulChanges)
        #expect(ChemicalReverification.isNoChangeResult(diff))
    }

    @Test("Reordering actives, sources and uses is not a change")
    func reorderingIsNotAChange() {
        let a = active("Tebuconazole", 200, frac("3"))
        let b = active("Azoxystrobin", 120, frac("11"))
        let useA = use(target: "Powdery mildew")
        let useB = use(target: "Downy mildew")

        var current = group11()
        current.activeIngredients = [a, b]
        current.registeredUses = [useA, useB]

        // Same facts, every unordered collection reversed.
        var candidate = current
        candidate.activeIngredients = [b, a]
        candidate.registeredUses = [useB, useA]
        candidate.verification.sources = current.verification.sources.reversed()

        let diff = ChemicalIntelligenceDiffer.diff(current: current, candidate: candidate)

        #expect(diff.isEmpty, "ordering alone must not diff, got \(diff.changes.map(\.id))")
    }

    // MARK: - Phase 25: groups

    @Test("Group change 11 to 3 is reported against the active")
    func groupChangeReported() throws {
        let diff = ChemicalIntelligenceDiffer.diff(current: group11(), candidate: group3())

        let codeChanges = diff.changes.filter { $0.field == .activityGroupCode }
        // Reported once, not also as a product-level add/remove pair.
        #expect(codeChanges.count == 1)
        let change = try #require(codeChanges.first)
        #expect(change.kind == .changed)
        #expect(change.subject == referenceActive)
        #expect(change.currentValue == "FRAC 11")
        #expect(change.candidateValue == "FRAC 3")
        #expect(diff.hasResistanceCriticalChanges)
        #expect(!ChemicalReverification.isNoChangeResult(diff))
    }

    @Test("Activity group scheme change is reported")
    func schemeChangeReported() throws {
        var candidate = group11()
        candidate.activeIngredients = [
            active(referenceActive, 250, ChemicalActivityGroup(scheme: .hrac, code: "11"))
        ]

        let diff = ChemicalIntelligenceDiffer.diff(current: group11(), candidate: candidate)

        let change = try #require(diff.changes.first { $0.field == .activityGroupScheme })
        #expect(change.currentValue == "FRAC")
        #expect(change.candidateValue == "HRAC")
    }

    // MARK: - Phase 25: actives

    @Test("Active added and removed are both reported")
    func activeAddedAndRemoved() throws {
        var candidate = group11()
        candidate.activeIngredients = [active("Tebuconazole", 200, frac("3"))]

        let diff = ChemicalIntelligenceDiffer.diff(current: group11(), candidate: candidate)

        let added = try #require(
            diff.changes.first { $0.field == .activeIngredient && $0.kind == .added }
        )
        let removed = try #require(
            diff.changes.first { $0.field == .activeIngredient && $0.kind == .removed }
        )
        #expect(added.subject == "Tebuconazole")
        #expect(removed.subject == referenceActive)
        // The product's group set moved too, and that is separately visible.
        #expect(diff.changes.contains { $0.field == .activityGroupCode })
    }

    @Test("Concentration change is reported with both values")
    func concentrationChange() throws {
        var candidate = group11()
        candidate.activeIngredients = [active(referenceActive, 200, frac("11"))]

        let diff = ChemicalIntelligenceDiffer.diff(current: group11(), candidate: candidate)

        let change = try #require(diff.changes.first { $0.field == .activeConcentration })
        #expect(change.currentValue == "250 g/L")
        #expect(change.candidateValue == "200 g/L")
        #expect(change.isResistanceCritical)
    }

    @Test("Concentration unit change is reported")
    func concentrationUnitChange() throws {
        var moved = active(referenceActive, 250, frac("11"))
        moved.concentrationUnit = .gramsPerKilogram
        var candidate = group11()
        candidate.activeIngredients = [moved]

        let diff = ChemicalIntelligenceDiffer.diff(current: group11(), candidate: candidate)

        let change = try #require(diff.changes.first { $0.field == .concentrationUnit })
        #expect(change.currentValue == "g/L")
        #expect(change.candidateValue == "g/kg")
    }

    // MARK: - Phase 25: identity

    @Test("Registration identity change is reported and is resistance critical")
    func registrationIdentityChange() throws {
        var candidate = group11()
        candidate.registration = registration(number: "70001")

        let diff = ChemicalIntelligenceDiffer.diff(current: group11(), candidate: candidate)

        let change = try #require(diff.changes.first { $0.field == .registrationIdentifier })
        #expect(change.currentValue == "62764")
        #expect(change.candidateValue == "70001")
        #expect(change.isResistanceCritical)
        #expect(change.section == .identity)
    }

    @Test("A lookup that omits a field does not report it as removed")
    func omittedFieldIsNotRemoval() {
        // Silence is not evidence of absence: an incomplete lookup response must
        // not read as the regulator having withdrawn the registration number.
        var candidate = group11()
        candidate.registration = ChemicalRegistration(countryCode: "AU")

        let diff = ChemicalIntelligenceDiffer.diff(current: group11(), candidate: candidate)

        #expect(!diff.changes.contains { $0.field == .registrationIdentifier })
    }

    // MARK: - Phase 25: label rates

    @Test("Label rate value change is one change, not an add plus remove")
    func rateValueChange() throws {
        let current = group11(uses: [use(rates: [rate(.per100Litres, value: 100)])])
        let candidate = group11(uses: [use(rates: [rate(.per100Litres, min: 80, max: 100)])])

        let diff = ChemicalIntelligenceDiffer.diff(current: current, candidate: candidate)

        let changes = diff.changes.filter { $0.field == .labelRate }
        #expect(changes.count == 1)
        let change = try #require(changes.first)
        #expect(change.kind == .changed)
        #expect(change.currentValue == "100 mL/100 L")
        #expect(change.candidateValue == "80–100 mL/100 L")
    }

    @Test("Label rate basis change reports a removal and an addition")
    func rateBasisChange() {
        let current = group11(uses: [use(rates: [rate(.per100Litres, value: 100)])])
        let candidate = group11(uses: [use(rates: [rate(.perHectare, value: 1.5, unit: "L")])])

        let diff = ChemicalIntelligenceDiffer.diff(current: current, candidate: candidate)

        let changes = diff.changes.filter { $0.field == .labelRate }
        #expect(changes.count == 2)
        #expect(changes.contains { $0.kind == .added })
        #expect(changes.contains { $0.kind == .removed })
    }

    // MARK: - Phase 25: registered uses

    @Test("Registered use added is reported with its crop and target")
    func useAdded() throws {
        let current = group11(uses: [use(target: "Powdery mildew")])
        let candidate = group11(uses: [use(target: "Powdery mildew"), use(target: "Downy mildew")])

        let diff = ChemicalIntelligenceDiffer.diff(current: current, candidate: candidate)

        let change = try #require(diff.changes.first { $0.field == .registeredUse })
        #expect(change.kind == .added)
        #expect(change.candidateValue == "Grapes — Downy mildew")
    }

    @Test("Registered use removed is reported")
    func useRemoved() throws {
        let current = group11(uses: [use(target: "Powdery mildew"), use(target: "Downy mildew")])
        let candidate = group11(uses: [use(target: "Powdery mildew")])

        let diff = ChemicalIntelligenceDiffer.diff(current: current, candidate: candidate)

        let change = try #require(diff.changes.first { $0.field == .registeredUse })
        #expect(change.kind == .removed)
        #expect(change.currentValue == "Grapes — Downy mildew")
    }

    @Test("Withholding and re-entry changes are reported")
    func whpAndReEntryChange() throws {
        let current = group11(uses: [use(whp: 14, reEntry: 24)])
        let candidate = group11(uses: [use(whp: 21, reEntry: 48)])

        let diff = ChemicalIntelligenceDiffer.diff(current: current, candidate: candidate)

        let whp = try #require(diff.changes.first { $0.field == .withholdingPeriod })
        let reEntry = try #require(diff.changes.first { $0.field == .reEntryPeriod })
        #expect(whp.currentValue == "14 days")
        #expect(whp.candidateValue == "21 days")
        #expect(reEntry.currentValue == "24 hours")
        #expect(reEntry.candidateValue == "48 hours")
    }

    // MARK: - Phase 25: evidence

    @Test("Label and table version changes are evidence only")
    func versionChangesAreEvidenceOnly() {
        let current = group11(labelVersion: "2024-06")
        var candidate = group11(labelVersion: "2026-02")
        candidate.activityGroupTableVersion = AuthoritativeActivityGroups.tableVersion + 1

        let diff = ChemicalIntelligenceDiffer.diff(current: current, candidate: candidate)

        #expect(diff.hasMeaningfulChanges)
        #expect(diff.isEvidenceOnly)
        #expect(!diff.hasResistanceCriticalChanges)
        // Evidence-only movement is "current, freshly confirmed", not "updated".
        #expect(ChemicalReverification.isNoChangeResult(diff))
        #expect(diff.populatedSections == [.evidence])
    }

    @Test("A newly cited source is reported as evidence")
    func newSourceReported() throws {
        var candidate = group11()
        candidate.verification.sources.append(
            ChemicalDataSource(kind: .manufacturerLabel, name: "Example label 2026")
        )

        let diff = ChemicalIntelligenceDiffer.diff(current: group11(), candidate: candidate)

        let change = try #require(diff.changes.first { $0.field == .source })
        #expect(change.kind == .added)
        #expect(change.candidateValue == "Example label 2026")
        #expect(diff.isEvidenceOnly)
    }

    @Test("Sections are ordered chemistry first")
    func sectionsChemistryFirst() {
        var candidate = group3()
        candidate.registration = registration(number: "70001", labelVersion: "2026-02")
        candidate.registeredUses = [use()]

        let diff = ChemicalIntelligenceDiffer.diff(current: group11(), candidate: candidate)

        // Whatever else moved, the operator reads the group change first.
        #expect(diff.populatedSections.first == .activityGroups)
    }

    // MARK: - Phase 25: cancel and accept

    @Test("Cancel leaves the stored chemical untouched")
    func cancelChangesNothing() throws {
        let stored = savedChemical(intelligence: group11())
        let before = try JSONEncoder().encode(stored)

        // Diffing is the whole of a cancelled re-verification: read, show, drop.
        let diff = ChemicalIntelligenceDiffer.diff(
            current: stored.resolvedIntelligence, candidate: group3()
        )
        #expect(diff.hasMeaningfulChanges)

        #expect(try JSONEncoder().encode(stored) == before)
        #expect(stored.activityGroupCodes == ["11"])
    }

    @Test("Accept updates the saved chemical to the new chemistry")
    func acceptUpdatesChemical() {
        let stored = savedChemical(intelligence: group11())

        let outcome = ChemicalReverification.apply(
            candidate: group3(), to: stored.resolvedIntelligence, at: at
        )
        let updated = ChemicalReverification.updated(stored, with: outcome)

        #expect(updated.activityGroupCodes == ["3"])
        // Legacy scalar mirrors follow the structured truth.
        #expect(updated.chemicalGroup == "3")
        #expect(updated.activeIngredient.contains(referenceActive))
        #expect(updated.verificationStatus == .verified)
    }

    @Test("Accept never forces verified when the lookup is only an AI reading")
    func aiOnlyCannotVerify() {
        let stored = savedChemical(intelligence: group11())
        // A complete-looking candidate whose only citation is an AI reading.
        var aiCandidate = group3()
        aiCandidate.activeIngredients = [
            active(referenceActive, 250, frac("3"), authoritative: false)
        ]
        aiCandidate.verification = ChemicalVerification(
            status: .verified,
            sources: [ChemicalDataSource(kind: .aiInterpretation, name: "Search summary")]
        )

        let outcome = ChemicalReverification.apply(
            candidate: aiCandidate, to: stored.resolvedIntelligence, at: at
        )

        // Completeness is not evidence. Trust may not rise on an AI answer.
        #expect(!outcome.resolvedStatus.isResistanceDependable)
        #expect(outcome.isDowngrade)
    }

    @Test("Re-verifying a known active onto a contradicting group conflicts")
    func knownActiveOntoContradictingGroupConflicts() throws {
        // Azoxystrobin is authoritatively FRAC 11. A lookup claiming FRAC 3 for it
        // is not an update, it is a disagreement — and the reference-table
        // cross-check must catch it during re-verification exactly as it does
        // during a manual edit, or a bad lookup could launder itself into a
        // Verified record.
        var current = group11()
        current.activeIngredients = [active("Azoxystrobin", 250, frac("11"))]
        var contradicting = group11()
        contradicting.activeIngredients = [active("Azoxystrobin", 250, frac("3"))]

        let outcome = ChemicalReverification.apply(
            candidate: contradicting, to: current, at: at
        )

        #expect(outcome.resolvedStatus == .conflict)
        // The lookup's value is still stored — VineTrack does not pick a winner,
        // it surfaces the disagreement.
        let single = try #require(outcome.intelligence.activeIngredients.first)
        #expect(single.activityGroup?.code == "3")
        #expect(!outcome.intelligence.verification.conflicts.isEmpty)
    }

    @Test("A candidate carrying an unresolved conflict cannot become verified")
    func lookupConflictBlocksVerified() {
        let stored = savedChemical(intelligence: group11())
        // A non-group conflict on purpose. Activity-group conflicts are
        // deliberately RECOMPUTED from the reference table on every reconcile, so
        // that correcting a bad group clears the conflict it caused; injecting one
        // here would test the wrong thing. A concentration disagreement is
        // carried through untouched, which is what proves an unresolved conflict
        // from the lookup survives into the accepted record.
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

        let outcome = ChemicalReverification.apply(
            candidate: conflicted, to: stored.resolvedIntelligence, at: at
        )

        #expect(outcome.resolvedStatus == .conflict)
        let updated = ChemicalReverification.updated(stored, with: outcome)
        #expect(updated.verificationStatus == .conflict)
    }

    @Test("A no-change result refreshes evidence without rewriting chemistry")
    func noChangeRefreshesEvidenceOnly() {
        let current = group11()
        let candidate = group11(labelVersion: "2026-02")

        let confirmed = ChemicalReverification.confirmingCurrent(
            current: current, candidate: candidate, at: at
        )

        // Values untouched.
        #expect(confirmed.activeIngredients == current.activeIngredients)
        #expect(confirmed.activityGroupCodes == ["11"])
        // Evidence refreshed.
        #expect(confirmed.verification.verifiedAt == at)
        #expect(confirmed.registration?.labelVersion == "2026-02")
        // And the freshly confirmed record still diffs clean against itself.
        #expect(ChemicalIntelligenceDiffer.diff(current: confirmed, candidate: confirmed).isEmpty)
    }

    // MARK: - Phase 2: strongest identity first

    @Test("Re-verification keys on the held registration number, not the brand name")
    func keysOnRegistrationNumber() {
        let plan = ChemicalReverification.plan(for: savedChemical(intelligence: group11()))

        #expect(plan.strength == .registrationIdentity)
        #expect(plan.identityKey == "AU:apvma:62764")
        // The exact registration leads the query; the name only disambiguates.
        #expect(plan.lookupQuery.contains("62764"))
        #expect(plan.lookupQuery.contains("APVMA"))
    }

    @Test("Identity strength falls back through registrant to name only")
    func identityStrengthFallback() {
        var noNumber = group11()
        noNumber.registration = registration(number: nil)
        #expect(
            ChemicalReverification.plan(for: savedChemical(intelligence: noNumber)).strength
                == .productRegistrantCountry
        )

        var bare = group11()
        bare.registration = ChemicalRegistration(countryCode: "AU")
        let noRegistrant = savedChemical(intelligence: bare, manufacturer: "")
        #expect(ChemicalReverification.plan(for: noRegistrant).strength == .productNameOnly)
    }

    @Test("Re-verify is offered for every structured status")
    func offeredForEveryStatus() {
        for status in [
            ChemicalVerificationStatus.verified,
            .partiallyVerified,
            .unverified,
            .conflict
        ] {
            var intel = group11()
            intel.verification.status = status
            #expect(
                ChemicalReverification.isOffered(for: savedChemical(intelligence: intel)),
                "expected re-verify offered for \(status)"
            )
        }
    }

    @Test("A legacy needs-match product with no registration goes to Match & Verify")
    func legacyNeedsMatchNotOffered() {
        // Nothing but a typed name: there is no identity to re-check, so
        // re-verification would silently become a fresh brand-name search.
        let legacy = savedChemical(
            intelligence: nil,
            activeIngredient: "Azoxystrobin",
            chemicalGroup: "11"
        )

        #expect(legacy.verificationStatus == .needsMatch)
        #expect(!ChemicalReverification.isOffered(for: legacy, fallbackCountry: "AU"))
        #expect(ChemicalReverification.unavailableReason(for: legacy, fallbackCountry: "AU") != nil)
    }

    @Test("A needs-match product that does hold a registration can be re-verified")
    func needsMatchWithRegistrationIsOffered() {
        var intel = group11()
        intel.verification = .legacy()

        #expect(ChemicalReverification.isOffered(for: savedChemical(intelligence: intel)))
    }

    @Test("Re-verify is refused when no country is known")
    func refusedWithoutCountry() {
        var noCountry = group11()
        noCountry.registration = ChemicalRegistration(
            countryCode: "", registrationNumber: "62764"
        )
        let chemical = savedChemical(intelligence: noCountry)

        #expect(!ChemicalReverification.isOffered(for: chemical))
        #expect(
            (ChemicalReverification.unavailableReason(for: chemical) ?? "").contains("country")
        )
    }

    // MARK: - Phase 8: historical immutability

    @Test("Re-verifying a chemical never changes a completed spray snapshot")
    func historicalSnapshotSurvivesReverification() throws {
        let stored = savedChemical(intelligence: group11())
        // A spray completed while the product was FRAC 11.
        let line = SprayChemical(
            name: "Example Fungicide",
            ratePerHa: 1500,
            savedChemicalId: stored.id,
            chemicalSnapshot: ChemicalSnapshotCapture.capture(stored, at: at)
        )
        let frozen = try #require(line.chemicalSnapshot)

        // The store is re-verified onto FRAC 3 and accepted.
        let outcome = ChemicalReverification.apply(
            candidate: group3(), to: stored.resolvedIntelligence, at: at
        )
        let updated = ChemicalReverification.updated(stored, with: outcome)
        #expect(updated.activityGroupCodes == ["3"])

        // The completed application is untouched, in every frozen dimension.
        #expect(line.chemicalSnapshot?.activityGroupCodes == ["11"])
        #expect(frozen.verificationStatus == .verified)
        #expect(frozen.activityGroupTableVersion == AuthoritativeActivityGroups.tableVersion)
        #expect(frozen.capturedAt == at)
        #expect(frozen.registrationIdentityKey == "AU:apvma:62764")

        // Still true after a persist/reload cycle.
        let data = try JSONEncoder().encode(line)
        let reloaded = try JSONDecoder().decode(SprayChemical.self, from: data)
        #expect(reloaded.chemicalSnapshot == frozen)
    }

    // MARK: - Phase 28: availability

    @Test("Availability reflects each frozen verification status")
    func availabilityPerStatus() {
        let cases: [(ChemicalVerificationStatus, ChemicalIntelligenceAvailability)] = [
            (.verified, .availableVerified),
            (.partiallyVerified, .availablePartiallyVerified),
            (.unverified, .availableUnverified),
            (.needsMatch, .availableUnverified),
            (.conflict, .conflict)
        ]
        for (status, expected) in cases {
            let snapshot = ChemicalLineSnapshot(
                activeIngredients: [active(referenceActive, 250, frac("11"))],
                activityGroupCodes: ["11"],
                verificationStatus: status
            )
            #expect(ChemicalIntelligenceAvailability.resolve(snapshot: snapshot) == expected)
        }
    }

    @Test("An absent snapshot is unavailable and never a clean result")
    func absentSnapshotIsUnavailable() {
        let availability = ChemicalIntelligenceAvailability.resolve(snapshot: nil)

        #expect(availability == .unavailable)
        // The single most important assertion in this file: silence is not safety.
        #expect(!availability.canAssess)
        #expect(!availability.permitsCleanResult)
        #expect(!availability.isDependable)
        #expect(availability.requiresQualification)
        #expect(availability.assessmentCaveat != nil)
    }

    @Test("A legacy-only snapshot carries no assessable chemistry")
    func legacyOnlySnapshotUnavailable() {
        // Preserved display text, no structured group: honestly unassessable.
        let legacyOnly = ChemicalLineSnapshot(
            productName: "Mystery Product",
            verificationStatus: .unverified,
            legacyChemicalGroup: "Group 3 + 11"
        )

        #expect(!legacyOnly.hasResistanceData)
        #expect(ChemicalIntelligenceAvailability.resolve(snapshot: legacyOnly) == .unavailable)
    }

    @Test("A historical line with no snapshot reports unavailable")
    func historicalLineUnavailable() {
        let legacyLine = SprayChemical(name: "Old product", ratePerHa: 2000)

        #expect(legacyLine.chemicalSnapshot == nil)
        #expect(legacyLine.resistanceAvailability == .unavailable)
    }

    @Test("Only verified chemistry is dependable")
    func onlyVerifiedIsDependable() {
        #expect(ChemicalIntelligenceAvailability.availableVerified.isDependable)
        for other: ChemicalIntelligenceAvailability in [
            .availablePartiallyVerified, .availableUnverified, .conflict, .unavailable
        ] {
            #expect(!other.isDependable, "\(other) must not be dependable")
            #expect(other.requiresQualification)
            #expect(other.assessmentCaveat != nil)
        }
    }

    @Test("A mixed tank is governed by its weakest line")
    func mixedTankTakesWeakest() {
        // One unknown product in the tank could be the very group that breaks the
        // rotation, so the whole application stops being assessable.
        #expect(
            ChemicalIntelligenceAvailability.combined([.availableVerified, .unavailable])
                == .unavailable
        )
        #expect(
            ChemicalIntelligenceAvailability.combined([.availableVerified, .conflict])
                == .conflict
        )
        // An application with no lines at all is not vacuously fine.
        #expect(ChemicalIntelligenceAvailability.combined([]) == .unavailable)
    }

    @Test("Availability serialises to the shared raw values")
    func availabilityRawValues() {
        #expect(ChemicalIntelligenceAvailability.availableVerified.rawValue == "available_verified")
        #expect(
            ChemicalIntelligenceAvailability.availablePartiallyVerified.rawValue
                == "available_partially_verified"
        )
        #expect(
            ChemicalIntelligenceAvailability.availableUnverified.rawValue == "available_unverified"
        )
        #expect(ChemicalIntelligenceAvailability.conflict.rawValue == "conflict")
        #expect(ChemicalIntelligenceAvailability.unavailable.rawValue == "unavailable")
    }

    // MARK: - Phase 29: diff field parity

    @Test("Diff field and section raw values are stable across platforms")
    func diffRawValues() {
        #expect(ChemicalIntelligenceDiffField.activityGroupCode.rawValue == "activity_group_code")
        #expect(ChemicalIntelligenceDiffField.activeConcentration.rawValue == "active_concentration")
        #expect(
            ChemicalIntelligenceDiffField.registrationIdentifier.rawValue
                == "registration_identifier"
        )
        #expect(ChemicalIntelligenceDiffField.labelRate.rawValue == "label_rate")
        #expect(ChemicalIntelligenceDiffField.registeredUse.rawValue == "registered_use")
        #expect(ChemicalIntelligenceDiffSection.activityGroups.rawValue == "activity_groups")
        #expect(ChemicalIntelligenceDiffSection.evidence.rawValue == "evidence")
    }

    // MARK: - Phases 19–21: iOS manual spray line identity

    @Test("A picked Saved Chemical captures its id and snapshot")
    func pickedChemicalCaptures() throws {
        let chem = savedChemical(intelligence: group11())

        let resolution = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId: chem.id,
            productName: chem.name,
            library: [chem],
            at: at,
            allowNameMatch: false
        )

        #expect(resolution.savedChemicalId == chemId)
        let snapshot = try #require(resolution.snapshot)
        #expect(snapshot.activityGroupCodes == ["11"])
        #expect(snapshot.verificationStatus == .verified)
    }

    @Test("A renamed product still resolves through its identifier")
    func renameDoesNotBreakIdentity() throws {
        var renamed = savedChemical(intelligence: group11())
        renamed.name = "Example Fungicide (old stock)"

        let resolution = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId: chemId,
            // The line still carries the name as it was when picked.
            productName: "Example Fungicide",
            library: [renamed],
            at: at,
            allowNameMatch: false
        )

        #expect(resolution.savedChemicalId == chemId)
        #expect(try #require(resolution.snapshot).activityGroupCodes == ["11"])
    }

    @Test("An explicit off-library product stays unresolved with no fuzzy match")
    func offLibraryProductStaysManual() {
        var library = savedChemical(intelligence: group11())
        library.name = "Amistar 250 SC"

        // The operator deliberately typed a product not in the store. A near name
        // must never bind it to a different registered product's chemistry.
        let resolution = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId: nil,
            productName: "Amistar",
            library: [library],
            at: at,
            allowNameMatch: false
        )

        #expect(!resolution.isResolved)
        #expect(resolution.savedChemicalId == nil)
        #expect(resolution.snapshot == nil)
    }

    @Test("Even an exactly equal typed name does not bind when picking is required")
    func exactNameStillDoesNotBindInManualForm() {
        let library = savedChemical(intelligence: group11())

        // In the manual spray form a typed string is a deliberate manual entry,
        // never an identification — that is the whole point of the picker.
        let resolution = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId: nil,
            productName: "Example Fungicide",
            library: [library],
            at: at,
            allowNameMatch: false
        )

        #expect(!resolution.isResolved)
        #expect(resolution.snapshot == nil)
        // An importer, which has nothing but a name column, still may match.
        let imported = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId: nil,
            productName: "Example Fungicide",
            library: [library],
            at: at
        )
        #expect(imported.isResolved)
    }

    @Test("An unresolved manual line is unavailable for resistance assessment")
    func manualLineIsUnavailable() {
        let line = SprayChemical(
            name: "Mystery Product",
            ratePerHa: 2000,
            savedChemicalId: nil,
            chemicalSnapshot: nil
        )

        #expect(line.resistanceAvailability == .unavailable)
        #expect(!line.resistanceAvailability.permitsCleanResult)
    }
}
