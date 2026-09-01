import Foundation
import Testing

@testable import VineTrack

/// P8 — Plan → Spray Job → completed Spray Record → resistance history.
///
/// The chain has TWO independent freezes, and these tests exist to keep them
/// independent:
///
///  1. **Job creation** freezes the planned product's chemistry onto the job line
///     (sql/201 `chemical_lines`), so re-verifying the Saved Chemical later cannot
///     restate what the job was created to apply.
///  2. **Completion** freezes the Chemical Store as it stands at application time
///     onto the record line, which is the contract every new application follows.
///
/// Collapsing them would break one of the two: reusing the job's frozen chemistry
/// at completion would record chemistry that was months stale, and having no job
/// freeze at all leaves the job a bare pointer that silently re-reads.
@Suite("Plan → Job → Record provenance integrity")
struct PlanJobProvenanceIntegrityTests {

    // MARK: - Fixtures

    private let vineyardId = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let planId = "plan-2026-powdery"
    private let positionId = "position-4"
    private let blockA = "block-a"
    private let at = Date(timeIntervalSince1970: 1_786_000_000)
    private let later = Date(timeIntervalSince1970: 1_795_000_000)

    private let calendar = ResistanceSeasonCalendar()
    private var season: ResistanceSeason { calendar.seasonStarting(2026) }
    private func day(_ offset: Int) -> Int64 {
        season.startEpochMs + Int64(offset) * 86_400_000
    }

    private func group(
        _ scheme: ChemicalActivityGroupScheme,
        _ code: String
    ) -> ChemicalActivityGroup {
        ChemicalActivityGroup(scheme: scheme, code: code)
    }

    private func active(
        _ name: String,
        group: ChemicalActivityGroup?
    ) -> ChemicalActiveIngredient {
        ChemicalActiveIngredient(
            name: name,
            concentration: 200,
            concentrationUnit: .gramsPerLitre,
            activityGroup: group,
            groupSource: group == nil ? nil : .authoritativeClassification,
            identitySource: .officialRegister
        )
    }

    private func verified(_ status: ChemicalVerificationStatus = .verified) -> ChemicalVerification {
        ChemicalVerification(
            status: status,
            sources: [
                ChemicalDataSource(kind: .officialRegister, name: "APVMA PUBCRIS"),
                AuthoritativeActivityGroups.source(),
            ],
            verifiedAt: at
        )
    }

    private func chemical(
        id: UUID,
        name: String,
        number: String,
        actives: [ChemicalActiveIngredient],
        status: ChemicalVerificationStatus = .verified
    ) -> SavedChemical {
        SavedChemical(
            id: id,
            name: name,
            chemicalGroup: "",
            manufacturer: "Example Crop Science",
            activeIngredient: "",
            modeOfAction: "",
            productCategory: "fungicide",
            isActive: true,
            chemicalIntelligence: ChemicalIntelligence(
                activeIngredients: actives,
                registration: ChemicalRegistration(
                    countryCode: "AU",
                    scheme: .apvma,
                    registrationNumber: number,
                    registrant: "Example Crop Science",
                    registeredProductName: name
                ),
                verification: verified(status),
                productCategory: "fungicide"
            )
        )
    }

    private let dmiId = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!
    private let mixId = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
    private let herbicideId = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000003")!

    /// A single-active FRAC 3 fungicide.
    private var dmi: SavedChemical {
        chemical(
            id: dmiId, name: "Example DMI", number: "62764",
            actives: [active("Tebuconazole", group: group(.frac, "3"))]
        )
    }

    /// A genuine two-active co-formulation: FRAC 3 + FRAC 7.
    private var coformulation: SavedChemical {
        chemical(
            id: mixId, name: "Example Duo", number: "91636",
            actives: [
                active("Tebuconazole", group: group(.frac, "3")),
                active("Fluxapyroxad", group: group(.frac, "7")),
            ]
        )
    }

    /// A HERBICIDE classified HRAC 9 — the same bare number as FRAC 9.
    private var herbicide: SavedChemical {
        SavedChemical(
            id: herbicideId,
            name: "Example Knockdown",
            chemicalGroup: "",
            manufacturer: "Example Crop Science",
            activeIngredient: "",
            modeOfAction: "",
            productCategory: "herbicide",
            isActive: true,
            chemicalIntelligence: ChemicalIntelligence(
                activeIngredients: [active("Glyphosate", group: group(.hrac, "9"))],
                registration: ChemicalRegistration(
                    countryCode: "AU", scheme: .apvma, registrationNumber: "34321",
                    registrant: "Example Crop Science", registeredProductName: "Example Knockdown"
                ),
                verification: verified(),
                productCategory: "herbicide"
            )
        )
    }

    private func plannedProduct(
        _ chemical: SavedChemical,
        groups: [String],
        id: String = "planned-1",
        availability: ChemicalIntelligenceAvailability = .availableVerified
    ) -> ResistancePlannedProduct {
        ResistancePlannedProduct(
            id: id,
            groups: .of(groups),
            source: .savedChemical,
            savedChemicalId: chemical.id.uuidString,
            productName: chemical.name,
            chemicalAvailability: availability
        )
    }

    private func position(_ products: [ResistancePlannedProduct]) -> ResistancePlannedPosition {
        ResistancePlannedPosition(id: positionId, products: products)
    }

    private func insert(
        _ position: ResistancePlannedPosition,
        library: [SavedChemical],
        revision: Int64? = 7
    ) -> BackendPlanSprayJobInsert {
        BackendPlanSprayJobInsert(
            id: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!,
            vineyardId: vineyardId,
            name: "Powdery Mildew 2026/27 — Spray 4",
            isTemplate: false,
            status: "planned",
            target: "Powdery Mildew",
            notes: nil,
            chemicalLines: ResistancePlanJobService.chemicalLines(
                for: position, library: library, at: at
            ),
            resistancePlanId: planId,
            resistancePositionId: positionId,
            resistancePositionSnapshot: position,
            resistancePlanSourceRevision: revision,
            createdBy: nil
        )
    }

    private func roundTrip(_ insert: BackendPlanSprayJobInsert) throws -> BackendPlanSprayJob {
        // Through the wire shape the server actually stores, so a field that only
        // survives in memory is caught here.
        let data = try JSONEncoder().encode(insert)
        return try JSONDecoder().decode(BackendPlanSprayJob.self, from: data)
    }

    /// Completion, exactly as `SprayCalculatorView.chemicalSnapshot(for:)` does it:
    /// identity only, current store, at application time.
    private func complete(
        line: SprayJobChemicalLine,
        library: [SavedChemical],
        at date: Date
    ) -> ChemicalLineSnapshot? {
        ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId: line.chemicalId,
            productName: line.name,
            library: library,
            at: date,
            allowNameMatch: false
        ).snapshot
    }

    private func record(
        lines: [SprayChemical],
        endTime: Date? = Date(timeIntervalSince1970: 1_790_000_000),
        isTemplate: Bool = false,
        blocks: [String]? = [blockAId],
        targets: [SprayTarget]? = [.powderyMildew],
        jobId: UUID? = nil
    ) -> SprayRecord {
        SprayRecord(
            vineyardId: vineyardId,
            date: Date(timeIntervalSince1970: 1_789_000_000),
            endTime: endTime,
            tanks: [SprayTank(tankNumber: 1, waterVolume: 2000, sprayRatePerHa: 500, concentrationFactor: 1, rowApplications: [], chemicals: lines)],
            isTemplate: isTemplate,
            applicationGeometry: SprayApplicationSnapshot(
                targets: targets,
                blocks: blocks?.map { SprayApplicationBlockSnapshot(blockId: $0, blockName: "Home Block") }
            ),
            sprayJobId: jobId
        )
    }

    private static let blockAId = "block-a"
    private var blockAId: String { Self.blockAId }

    // MARK: - sql/201 fields

    @Test func sql201ProvenanceFieldsSurviveTheWireRoundTrip() throws {
        let payload = insert(position([plannedProduct(dmi, groups: ["3"])]), library: [dmi])
        let job = try roundTrip(payload)

        #expect(job.resistancePlanId == planId)
        #expect(job.resistancePositionId == positionId)
        #expect(job.resistancePlanSourceRevision == 7)
        let snapshot = try #require(job.resistancePositionSnapshot)
        #expect(snapshot.id == positionId)
        // The frozen INTENT keeps the planned group, so "what was planned" is
        // answerable from the job alone even if the plan is edited afterwards.
        #expect(snapshot.products.map(\.groupCodes) == [["3"]])
        #expect(job.originalIntentLabel == "FRAC 3 — Example DMI")
    }

    @Test func aJobWithNoRevisionStillCarriesItsPlanLink() throws {
        // An offline-created plan has no server revision yet. That is a legitimate
        // state and must not cost the job its provenance.
        let job = try roundTrip(
            insert(position([plannedProduct(dmi, groups: ["3"])]), library: [dmi], revision: nil)
        )
        #expect(job.resistancePlanSourceRevision == nil)
        #expect(job.resistancePlanId == planId)
        #expect(job.resistancePositionSnapshot != nil)
    }

    // MARK: - Chemistry frozen at job creation

    @Test func plannedChemistryIsFrozenOntoTheJobLine() throws {
        let job = try roundTrip(
            insert(position([plannedProduct(dmi, groups: ["3"])]), library: [dmi])
        )
        let line = try #require(job.chemicalLines.first)

        // Saved Chemical linkage survives.
        #expect(line.chemicalId == dmiId)
        #expect(line.name == "Example DMI")
        // Actives survive, structurally and as readable text.
        #expect(line.activeIngredient == "Tebuconazole")
        let frozen = try #require(line.chemicalSnapshot)
        #expect(frozen.activeIngredients.map(\.name) == ["Tebuconazole"])
        #expect(frozen.savedChemicalId == dmiId.uuidString)
        #expect(frozen.registrationIdentityKey == "AU:apvma:62764")
        #expect(frozen.verificationStatus == .verified)
        #expect(frozen.capturedAt == at)
        // Scheme-qualified groups, per P7.
        #expect(ResistanceEventSource.groups(from: frozen).codes == ["FRAC:3"])
    }

    @Test func multiActiveProductRetainsEveryGroupOnTheJob() throws {
        let job = try roundTrip(
            insert(position([plannedProduct(coformulation, groups: ["3", "7"])]), library: [coformulation])
        )
        let line = try #require(job.chemicalLines.first)
        let frozen = try #require(line.chemicalSnapshot)

        // BOTH actives and BOTH groups. A two-active product belongs to each group
        // independently; keeping one would let half its chemistry escape the
        // strategy entirely.
        #expect(frozen.activeIngredients.map(\.name) == ["Tebuconazole", "Fluxapyroxad"])
        #expect(line.activeIngredient == "Tebuconazole + Fluxapyroxad")
        let groups = ResistanceEventSource.groups(from: frozen)
        #expect(groups.codes == ["FRAC:3", "FRAC:7"])
        #expect(groups.isCoformulation)
        #expect(groups.projected(into: .frac).codes == ["3", "7"])
    }

    @Test func hrac9StaysDistinctFromFrac9AcrossPlanJobAndHistory() throws {
        let job = try roundTrip(
            insert(
                position([plannedProduct(herbicide, groups: ["HRAC 9"], id: "planned-herbicide")]),
                library: [herbicide]
            )
        )
        let jobLine = try #require(job.chemicalLines.first)
        let frozen = try #require(jobLine.chemicalSnapshot)

        // Frozen on the job as HRAC, not as a bare "9".
        let jobGroups = ResistanceEventSource.groups(from: frozen)
        #expect(jobGroups.codes == ["HRAC:9"])

        // Through completion...
        let completed = try #require(
            complete(line: jobLine, library: [herbicide], at: later)
        )
        #expect(ResistanceEventSource.groups(from: completed).codes == ["HRAC:9"])

        // ...and into history, where a FRAC strategy sees no Group 9 at all.
        let history = record(lines: [
            SprayChemical(name: "Example Knockdown", savedChemicalId: herbicideId, chemicalSnapshot: completed)
        ])
        let lines = ResistanceEventSource.productLines(from: history)
        #expect(lines.map(\.groups.codes) == [["HRAC:9"]])
        #expect(lines[0].groups.projected(into: .frac).codes.isEmpty)
    }

    // MARK: - Re-verification must not rewrite an existing job

    @Test func reVerifyingTheSavedChemicalDoesNotRewriteTheJob() throws {
        let job = try roundTrip(
            insert(position([plannedProduct(dmi, groups: ["3"])]), library: [dmi])
        )
        let creationLine = try #require(job.chemicalLines.first)
        let frozenAtCreation = try #require(creationLine.chemicalSnapshot)

        // Months later the SAME product is legitimately re-verified to FRAC 11.
        let reverified = chemical(
            id: dmiId, name: "Example DMI (renamed)", number: "62764",
            actives: [active("Azoxystrobin", group: group(.frac, "11"))]
        )

        // The job row is stored data. Nothing about it changed.
        #expect(frozenAtCreation.activeIngredients.map(\.name) == ["Tebuconazole"])
        #expect(ResistanceEventSource.groups(from: frozenAtCreation).codes == ["FRAC:3"])
        #expect(frozenAtCreation.productName == "Example DMI")

        // Re-decoding the stored job after the correction still yields FRAC 3 —
        // the job answers from its own row, never by re-reading the store.
        let reread = try roundTrip(
            insert(position([plannedProduct(dmi, groups: ["3"])]), library: [dmi])
        )
        let rereadLine = try #require(reread.chemicalLines.first)
        let rereadSnapshot = try #require(rereadLine.chemicalSnapshot)
        #expect(ResistanceEventSource.groups(from: rereadSnapshot).codes == ["FRAC:3"])

        // Completion AFTER the correction correctly records TODAY's chemistry —
        // that is the separate, deliberate rule: an application freezes what was
        // actually applied, not what was planned months earlier.
        let completed = try #require(
            complete(line: creationLine, library: [reverified], at: later)
        )
        #expect(ResistanceEventSource.groups(from: completed).codes == ["FRAC:11"])
        #expect(completed.capturedAt == later)
        // ...and that completed record is itself immutable thereafter.
        let historyLines = ResistanceEventSource.productLines(
            from: record(lines: [SprayChemical(name: "Example DMI", savedChemicalId: dmiId, chemicalSnapshot: completed)])
        )
        #expect(historyLines.map(\.groups.codes) == [["FRAC:11"]])
    }

    // MARK: - Unresolved / unverified planned chemistry

    @Test func groupOnlyPlannedChemistryNeverBecomesAuthoritative() throws {
        // A position planned as a bare GROUP — no product chosen.
        let stipulation = ResistancePlannedProduct(
            id: "planned-group",
            groups: .of(["3"]),
            source: .group
        )
        let job = try roundTrip(insert(position([stipulation]), library: [dmi]))
        let line = try #require(job.chemicalLines.first)

        // The line is named for its group, carries no product link, and — the
        // point of the test — freezes NO chemistry. There is no product to freeze.
        #expect(line.name == "FRAC 3")
        #expect(line.chemicalId == nil)
        #expect(line.chemicalSnapshot == nil)
        #expect(line.activeIngredient == nil)

        // Completion must not let that group label bind to a library product by
        // name, which would promote a stipulation into verified chemistry.
        let namedLikeAProduct = chemical(
            id: UUID(), name: "FRAC 3", number: "11111",
            actives: [active("Tebuconazole", group: group(.frac, "3"))]
        )
        let completed = complete(line: line, library: [dmi, namedLikeAProduct], at: later)
        #expect(completed?.savedChemicalId == nil)
        #expect(completed?.activeIngredients.isEmpty ?? true)
        #expect(ChemicalIntelligenceAvailability.resolve(snapshot: completed) == .unavailable)
        // And the planned group is still recoverable — from the frozen INTENT,
        // which is where a stipulation belongs.
        #expect(job.resistancePositionSnapshot?.products.first?.groupCodes == ["3"])
    }

    @Test func unverifiedPlannedProductKeepsItsUnverifiedStatusOnTheJob() throws {
        let unverified = chemical(
            id: dmiId, name: "Hand-entered product", number: "",
            actives: [active("Tebuconazole", group: group(.frac, "3"))],
            status: .unverified
        )
        let job = try roundTrip(
            insert(
                position([plannedProduct(unverified, groups: ["3"], availability: .availableUnverified)]),
                library: [unverified]
            )
        )
        let jobLine = try #require(job.chemicalLines.first)
        let frozen = try #require(jobLine.chemicalSnapshot)
        // The caveat is frozen with the chemistry. A job built on shaky chemistry
        // must never read as verified later just because it was written down.
        #expect(frozen.verificationStatus != .verified)
        #expect(ChemicalIntelligenceAvailability.resolve(snapshot: frozen).requiresQualification)
    }

    @Test func aPlannedProductMissingFromTheStoreFreezesNothingRatherThanGuessing() throws {
        let ghost = plannedProduct(dmi, groups: ["3"])
        // The library does NOT contain the planned product.
        let job = try roundTrip(insert(position([ghost]), library: []))
        let line = try #require(job.chemicalLines.first)

        // The link and the name survive so the operator can see what was intended,
        // but no chemistry is invented for a product nobody can find.
        #expect(line.chemicalId == dmiId)
        #expect(line.chemicalSnapshot == nil)
        #expect(line.activeIngredient == nil)
    }

    // MARK: - Reload restores provenance from stored fields

    @Test func reloadingAJobRestoresProvenanceFromStoredFieldsNotNameMatching() throws {
        let job = try roundTrip(
            insert(position([plannedProduct(dmi, groups: ["3"])]), library: [dmi])
        )
        let prefill = job.toPrefillRecord()
        let chem = try #require(prefill.tanks.first?.chemicals.first)

        // The stored id and the stored registered identity both ride into the
        // prefill, so re-resolution is by provenance...
        #expect(chem.savedChemicalId == dmiId)
        #expect(chem.chemicalSnapshot?.registrationIdentityKey == "AU:apvma:62764")

        // ...and it resolves by IDENTIFIER even when the product has since been
        // renamed, which name matching could never do.
        let renamed = chemical(
            id: dmiId, name: "Completely Different Name", number: "62764",
            actives: [active("Tebuconazole", group: group(.frac, "3"))]
        )
        let (resolved, match) = ChemicalSnapshotCapture.resolve(
            savedChemicalId: chem.savedChemicalId,
            productName: chem.name,
            registrationIdentityKey: chem.chemicalSnapshot?.registrationIdentityKey,
            in: [renamed]
        )
        #expect(resolved?.id == dmiId)
        #expect(match == .identifier)

        // Even with the id stripped, the stored registration identity still finds
        // it — provenance, not a string comparison.
        let (byIdentity, identityMatch) = ChemicalSnapshotCapture.resolve(
            savedChemicalId: nil,
            productName: "FRAC 3",
            registrationIdentityKey: chem.chemicalSnapshot?.registrationIdentityKey,
            in: [renamed]
        )
        #expect(byIdentity?.id == dmiId)
        #expect(identityMatch == .registrationIdentity)
    }

    @Test func unrelatedJobEditsDoNotDestroyProvenance() throws {
        let payload = insert(position([plannedProduct(dmi, groups: ["3"])]), library: [dmi])
        let job = try roundTrip(payload)

        // A portal edit that renames the job and changes its status, leaving the
        // resistance columns and chemical_lines untouched.
        var edited = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(payload)) as? [String: Any] ?? [:]
        edited["name"] = "Renamed by the portal"
        edited["status"] = "in_progress"
        let reloaded = try JSONDecoder().decode(
            BackendPlanSprayJob.self,
            from: try JSONSerialization.data(withJSONObject: edited)
        )

        #expect(reloaded.name == "Renamed by the portal")
        #expect(reloaded.status == "in_progress")
        // Everything resistance-critical is still there.
        #expect(reloaded.resistancePlanId == job.resistancePlanId)
        #expect(reloaded.resistancePositionId == job.resistancePositionId)
        #expect(reloaded.resistancePlanSourceRevision == job.resistancePlanSourceRevision)
        #expect(reloaded.resistancePositionSnapshot?.products.map(\.groupCodes) == [["3"]])
        let reloadedLine = try #require(reloaded.chemicalLines.first)
        let reloadedSnapshot = try #require(reloadedLine.chemicalSnapshot)
        #expect(ResistanceEventSource.groups(from: reloadedSnapshot).codes == ["FRAC:3"])
    }

    @Test func aMalformedLineCostsItsSnapshotNeverTheWholeJob() throws {
        // A portal write with an unreadable chemical_snapshot on one line.
        let json = """
        {
          "id": "CCCCCCCC-0000-0000-0000-000000000001",
          "vineyard_id": "AAAAAAAA-0000-0000-0000-000000000001",
          "name": "Spray 4",
          "resistance_plan_id": "plan-2026-powdery",
          "resistance_position_id": "position-4",
          "chemical_lines": [
            { "name": "Good line", "chemical_snapshot": { "product_name": "Good line", "activity_groups": ["3"] } },
            { "name": "Bad line", "chemical_snapshot": "not-an-object" }
          ]
        }
        """
        let job = try JSONDecoder().decode(BackendPlanSprayJob.self, from: Data(json.utf8))
        #expect(job.chemicalLines.count == 2)
        #expect(job.chemicalLines[0].chemicalSnapshot?.activityGroupCodes == ["3"])
        // The bad line survives as a line; only its unreadable snapshot is lost.
        #expect(job.chemicalLines[1].name == "Bad line")
        #expect(job.chemicalLines[1].chemicalSnapshot == nil)
        #expect(job.resistancePlanId == "plan-2026-powdery")
    }

    // MARK: - Completion → history

    @Test func completionCreatesTheNormalImmutableSnapshotAndLinksTheJob() throws {
        let payload = insert(position([plannedProduct(dmi, groups: ["3"])]), library: [dmi])
        let job = try roundTrip(payload)
        let jobLine = try #require(job.chemicalLines.first)
        let completed = try #require(
            complete(line: jobLine, library: [dmi], at: later)
        )
        let saved = record(
            lines: [SprayChemical(name: "Example DMI", savedChemicalId: dmiId, chemicalSnapshot: completed)],
            jobId: job.id
        )

        // The record fulfils the job — the Job → Record half of the chain.
        #expect(saved.sprayJobId == job.id)
        // ...and carries the normal frozen snapshot every application gets.
        #expect(saved.tanks[0].chemicals[0].hasResistanceSnapshot)
        #expect(completed.capturedAt == later)
        #expect(ResistanceEventSource.groups(from: completed).codes == ["FRAC:3"])
    }

    @Test func onlyCompletedSpraysReachResistanceHistory() throws {
        let line = SprayChemical(
            name: "Example DMI",
            savedChemicalId: dmiId,
            chemicalSnapshot: complete(
                line: SprayJobChemicalLine(chemicalId: dmiId, name: "Example DMI"),
                library: [dmi], at: later
            )
        )

        let completed = record(lines: [line])
        let template = record(lines: [line], isTemplate: true)
        let notFinished = record(lines: [line], endTime: nil)
        let deleted = record(lines: [line])

        let result = ResistanceEventSource.events(
            from: [
                ResistanceEventSource.input(from: completed),
                ResistanceEventSource.input(from: template),
                ResistanceEventSource.input(from: notFinished),
                ResistanceEventSource.input(from: deleted, isDeleted: true),
            ],
            seasonCalendar: calendar
        )

        // A template is a recipe, never an application.
        #expect(result.templateRecordIds == [template.id.uuidString])
        // A retracted record must not permanently consume an allowance.
        #expect(result.deletedRecordIds == [deleted.id.uuidString])
        // The unfinished one is kept but classed as planned, so the engine can
        // report that it excluded it rather than silently dropping it.
        let kinds = Dictionary(uniqueKeysWithValues: result.events.map { ($0.applicationId, $0.kind) })
        #expect(kinds[completed.id.uuidString] == .actual)
        #expect(kinds[notFinished.id.uuidString] == .planned)
        #expect(kinds[template.id.uuidString] == nil)
        #expect(kinds[deleted.id.uuidString] == nil)
    }

    // MARK: - End to end: the repeat warning

    @Test func frac3PlanToJobToCompletionThenAnotherFrac3Warns() throws {
        // 1. PLAN a FRAC 3 position, 2. create the JOB, 3. COMPLETE it.
        let job = try roundTrip(
            insert(position([plannedProduct(dmi, groups: ["3"])]), library: [dmi])
        )
        let jobLine = try #require(job.chemicalLines.first)
        let completed = try #require(
            complete(line: jobLine, library: [dmi], at: later)
        )
        let history = record(
            lines: [SprayChemical(name: "Example DMI", savedChemicalId: dmiId, chemicalSnapshot: completed)],
            jobId: job.id
        )

        // 4. That completed spray becomes resistance history, twice over.
        let products = ResistanceEventSource.productLines(from: history)
        #expect(products.map(\.groups.codes) == [["FRAC:3"]])
        let applied = (1...2).map { index in
            ResistanceApplicationEvent(
                applicationId: "applied-\(index)",
                kind: .actual,
                appliedAtEpochMs: day(index * 7),
                seasonId: season.id,
                vineyardId: vineyardId.uuidString,
                blockId: blockA,
                targets: [.powderyMildew],
                targetsRecorded: true,
                products: products
            )
        }

        // 5. Proposing ANOTHER FRAC 3 now warns.
        let candidate = ResistanceApplicationEvent(
            applicationId: "candidate",
            kind: .candidate,
            appliedAtEpochMs: day(21),
            seasonId: season.id,
            vineyardId: vineyardId.uuidString,
            blockId: blockA,
            targets: [.powderyMildew],
            targetsRecorded: true,
            products: products
        )
        let evaluation = ResistanceEngine.evaluate(
            ResistanceEvaluationRequest(
                jurisdiction: .australia,
                crop: .grape,
                disease: .powderyMildew,
                blockId: blockA,
                season: season,
                seasonCalendar: calendar,
                events: applied,
                candidate: candidate
            )
        )
        let consecutive = try #require(
            evaluation.ruleResults.first { $0.ruleId == "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE" }
        )
        #expect(consecutive.observedValue == 3)
        #expect(consecutive.threshold == 2)
        #expect(consecutive.status == .wouldExceedLimit)
        #expect(evaluation.status == .strategyExceeded)
    }

    @Test func aCoformulationCompletedFromAJobCountsInBothGroupHistories() throws {
        let job = try roundTrip(
            insert(position([plannedProduct(coformulation, groups: ["3", "7"])]), library: [coformulation])
        )
        let jobLine = try #require(job.chemicalLines.first)
        let completed = try #require(
            complete(line: jobLine, library: [coformulation], at: later)
        )
        let products = ResistanceEventSource.productLines(
            from: record(lines: [
                SprayChemical(name: "Example Duo", savedChemicalId: mixId, chemicalSnapshot: completed)
            ])
        )
        let event = ResistanceApplicationEvent(
            applicationId: "applied-duo",
            kind: .actual,
            appliedAtEpochMs: day(7),
            seasonId: season.id,
            vineyardId: vineyardId.uuidString,
            blockId: blockA,
            targets: [.powderyMildew],
            targetsRecorded: true,
            products: products
        )
        // Both groups reach the engine, in the strategy's own numbering.
        #expect(event.projected(into: .frac).componentGroups == ["3", "7"])
        #expect(event.coformulationSignatures.count == 1)
    }
}
