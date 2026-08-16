import Foundation
import Testing
@testable import VineTrack

/// Block attribution contract (sql/195): WHICH blocks an application treated.
///
/// The properties under test are the ones that make per-block resistance history
/// trustworthy, and each of them was genuinely absent before this work:
///
///  1. **Attribution is persisted at all.** The Blocks-step selection reached the
///     geometry engine and was then discarded; now it survives.
///  2. **Identity is the block id, never the name.** A rename must not move
///     history, and a deleted block must not erase it.
///  3. **Attribution cannot disagree with the geometry.** Both are projected from
///     the same resolved block list, so "calculated from A+C, recorded as A+B" is
///     unrepresentable rather than merely unlikely.
///  4. **Unknown stays unknown.** A pre-195 record reads back as "blocks not
///     recorded" and is never assigned to a block by inference.
///
/// The Android suites `SprayBlockAttributionTest` and
/// `SprayManualBlockAttributionTest` assert the same fixtures.
struct SprayBlockAttributionTests {

    private let tolerance = 0.0001
    private let calendar = ResistanceSeasonCalendar()

    private let vineyardId = UUID()
    private let blockAId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let blockBId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let blockCId = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let ghostBlockId = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!

    // MARK: - Fixtures

    private func paddock(id: UUID, name: String) -> Paddock {
        var block = Paddock(vineyardId: vineyardId, name: name, rowWidth: 3.2)
        block.id = id
        block.rowLengthOverride = 10_000
        return block
    }

    private var vineyardBlocks: [Paddock] {
        [
            paddock(id: blockAId, name: "Home Block"),
            paddock(id: blockBId, name: "River Block"),
            paddock(id: blockCId, name: "Hill Block"),
        ]
    }

    private func blockInput(
        id: UUID,
        name: String?,
        grossHa: Double,
        rowLength: Double? = 10_000,
        rowSpacing: Double? = 3.2,
        rowCount: Int? = 40
    ) -> SprayBlockInput {
        SprayBlockInput(
            blockId: id.uuidString,
            blockName: name,
            grossAreaHectares: grossHa,
            mappedRowLengthMetres: rowLength,
            rowSpacingMetres: rowSpacing,
            rowCount: rowCount
        )
    }

    private func plan(for blocks: [SprayBlockInput]) -> SprayApplicationPlan {
        let geometry = SprayGeometryResolver.resolve(blocks)
        return SprayApplicationPlanner.plan(
            blocks: blocks,
            mode: .wholeBlock,
            bandWidth: nil,
            carrier: SprayCarrierVolumeCalculator.perHectare(
                litresPerHectare: 300,
                areaHectares: geometry.grossAreaHectares,
                rowLengthMetres: geometry.totalRowLengthMetres,
                rowSpacingMetres: geometry.uniformRowSpacingMetres
            ),
            tankCapacityLitres: 3_000,
            productLines: []
        )
    }

    /// What the canonical resolver says about a selection — the reference values.
    private func resolverBlocks(_ ids: [UUID]) -> [SprayApplicationBlockSnapshot] {
        let all = vineyardBlocks
        let inputs = ids.compactMap { id in all.first { $0.id == id } }
            .map { SprayBlockInput.from(paddock: $0) }
        return SprayApplicationBlockSnapshot.project(SprayGeometryResolver.resolve(inputs).blocks) ?? []
    }

    private func record(
        id: UUID = UUID(),
        blocks: [SprayApplicationBlockSnapshot]?,
        targets: [SprayTarget]? = [.powderyMildew],
        endTime: Date? = Date(timeIntervalSince1970: 1_790_000_000),
        isTemplate: Bool = false
    ) -> SprayRecord {
        SprayRecord(
            id: id,
            vineyardId: vineyardId,
            date: Date(timeIntervalSince1970: 1_789_000_000),
            endTime: endTime,
            isTemplate: isTemplate,
            applicationGeometry: SprayApplicationSnapshot(targets: targets, blocks: blocks)
        )
    }

    // MARK: - 1. Attribution is persisted

    @Test func singleBlockSelectionIsPersistedWithIdentityAndGeometry() {
        let snapshot = SprayApplicationSnapshot(
            plan: plan(for: [blockInput(id: blockAId, name: "Home Block", grossHa: 10)])
        )

        let blocks = try! #require(snapshot.blocks)
        #expect(blocks.count == 1)
        #expect(blocks[0].blockId == blockAId.uuidString)
        #expect(blocks[0].blockName == "Home Block")
        #expect(abs((blocks[0].grossAreaHa ?? 0) - 10) < tolerance)
        #expect(abs((blocks[0].rowLengthMetres ?? 0) - 10_000) < tolerance)
        #expect(abs((blocks[0].rowSpacingMetres ?? 0) - 3.2) < tolerance)
        #expect(blocks[0].rowCount == 40)
        #expect(blocks[0].geometrySource == .mappedRows)
        #expect(blocks[0].geometryQuality == .authoritative)
        #expect(snapshot.hasRecordedBlocks)
        #expect(snapshot.treatedBlockIds == [blockAId.uuidString])
    }

    @Test func multipleBlocksArePersistedAsOneApplication() {
        let snapshot = SprayApplicationSnapshot(
            plan: plan(for: [
                blockInput(id: blockAId, name: "Home Block", grossHa: 10),
                blockInput(id: blockCId, name: "Hill Block", grossHa: 14),
            ])
        )

        #expect(snapshot.treatedBlockIds == [blockAId.uuidString, blockCId.uuidString])
        // One spray covering two blocks stays ONE record with two attributed
        // blocks — never two records, which would double-count the pass.
        #expect(abs((snapshot.grossAreaHa ?? 0) - 24) < tolerance)
    }

    @Test func duplicateSelectionCollapsesToOneBlock() {
        let normalised = SprayApplicationBlockSnapshot.normalised([
            SprayApplicationBlockSnapshot(blockId: blockAId.uuidString, blockName: "Home Block"),
            SprayApplicationBlockSnapshot(blockId: blockAId.uuidString, blockName: "Home Block"),
        ])

        // A block counted twice would double a per-block resistance history.
        #expect(normalised?.count == 1)
    }

    @Test func emptySelectionIsNilNotAnEmptyArray() {
        // "Treated no blocks" is not a state a real application can be in, which is
        // why sql/195 rejects `[]`. Absence has exactly one spelling.
        #expect(SprayApplicationBlockSnapshot.normalised([]) == nil)
        #expect(SprayApplicationBlockSnapshot.normalised(nil) == nil)
    }

    // MARK: - 2. The geometry/attribution invariant

    @Test func attributionIdsAlwaysEqualTheGeometryBlockIds() {
        let inputs = [
            blockInput(id: blockAId, name: "Home Block", grossHa: 10),
            blockInput(id: blockCId, name: "Hill Block", grossHa: 14),
        ]
        let applicationPlan = plan(for: inputs)
        let snapshot = SprayApplicationSnapshot(plan: applicationPlan)

        // The invariant: attribution is a PROJECTION of the same resolved list the
        // aggregates were summed from, so the two cannot drift.
        #expect(snapshot.treatedBlockIds == applicationPlan.geometry.blocks.map(\.blockId))
    }

    @Test func perBlockAreasReconcileWithTheAggregate() {
        let snapshot = SprayApplicationSnapshot(
            plan: plan(for: [
                blockInput(id: blockAId, name: "Home Block", grossHa: 10),
                blockInput(id: blockCId, name: "Hill Block", grossHa: 14),
            ])
        )

        let blocks = try! #require(snapshot.blocks)
        let summedArea = blocks.compactMap(\.grossAreaHa).reduce(0, +)
        let summedRows = blocks.compactMap(\.rowLengthMetres).reduce(0, +)
        #expect(abs(summedArea - (snapshot.grossAreaHa ?? 0)) < tolerance)
        #expect(abs(summedRows - (snapshot.canonicalRowLengthMetres ?? 0)) < tolerance)
    }

    // MARK: - 3. Encode / decode

    @Test func attributionSurvivesAnOfflineJSONRoundTrip() throws {
        let snapshot = SprayApplicationSnapshot(
            plan: plan(for: [
                blockInput(id: blockAId, name: "Home Block", grossHa: 10),
                blockInput(id: blockCId, name: "Hill Block", grossHa: 14),
            ])
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SprayApplicationSnapshot.self, from: encoded)

        #expect(decoded.blocks == snapshot.blocks)
        #expect(decoded.treatedBlockIds == [blockAId.uuidString, blockCId.uuidString])
    }

    @Test func aRecordWithNoStoredBlocksDecodesAsNotRecorded() throws {
        let json = Data(#"{"grossAreaHa":10.0}"#.utf8)

        let decoded = try JSONDecoder().decode(SprayApplicationSnapshot.self, from: json)

        // Silence must not become an empty array, which would read as "recorded as
        // treating nothing".
        #expect(decoded.blocks == nil)
        #expect(!decoded.hasRecordedBlocks)
    }

    @Test func blockWithoutAnIdIsRejectedRatherThanGuessed() {
        let json = Data(#"[{"blockName":"Home Block"}]"#.utf8)

        // Identity is the id. A name alone is not attribution and must not decode
        // into one.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([SprayApplicationBlockSnapshot].self, from: json)
        }
    }

    // MARK: - 4. Rename and deletion

    @Test func renamingABlockDoesNotChangeStoredAttribution() {
        let stored = [
            SprayApplicationBlockSnapshot(blockId: blockAId.uuidString, blockName: "North Three")
        ]

        // The vineyard now calls it "Home Block". The stored id is untouched, so the
        // record still belongs to the same block.
        let resolved = try! #require(
            SprayBlockAttributionDisplay.resolve(stored, paddocks: vineyardBlocks)
        )
        #expect(resolved[0].blockId == blockAId.uuidString)
        // Display prefers the CURRENT name, so the reader can find it in the app.
        #expect(resolved[0].name == "Home Block")
        #expect(resolved[0].isLive)
    }

    @Test func aDeletedBlockKeepsItsAttributionAndItsStoredName() {
        let stored = [
            SprayApplicationBlockSnapshot(
                blockId: ghostBlockId.uuidString,
                blockName: "Old Trial Block"
            )
        ]

        let resolved = try! #require(
            SprayBlockAttributionDisplay.resolve(stored, paddocks: vineyardBlocks)
        )
        // The id survives even though the live lookup fails, and readability does
        // not depend on the block still existing.
        #expect(resolved[0].blockId == ghostBlockId.uuidString)
        #expect(resolved[0].name == "Old Trial Block")
        #expect(!resolved[0].isLive)
    }

    @Test func unknownBlockOnlyWhenNeitherNameExists() {
        let stored = [SprayApplicationBlockSnapshot(blockId: ghostBlockId.uuidString)]

        let resolved = try! #require(
            SprayBlockAttributionDisplay.resolve(stored, paddocks: vineyardBlocks)
        )
        #expect(resolved[0].name == SprayBlockAttributionDisplay.unknownBlock)
    }

    @Test func nameCollisionAcrossVineyardsCannotMoveHistory() {
        var otherVineyard = Paddock(vineyardId: UUID(), name: "Home Block")
        otherVineyard.id = ghostBlockId

        let stored = [
            SprayApplicationBlockSnapshot(blockId: blockAId.uuidString, blockName: "Home Block")
        ]
        let resolved = try! #require(
            SprayBlockAttributionDisplay.resolve(
                stored,
                paddocks: vineyardBlocks + [otherVineyard]
            )
        )

        // Resolution is by id, so an identical name elsewhere is irrelevant.
        #expect(resolved.count == 1)
        #expect(resolved[0].blockId == blockAId.uuidString)
    }

    @Test func idCasingDifferencesResolveToTheSameBlock() {
        // iOS writes uppercase `uuidString`; Postgres and Android use lowercase. The
        // same block legitimately arrives in both spellings.
        let stored = [
            SprayApplicationBlockSnapshot(
                blockId: blockAId.uuidString.lowercased(),
                blockName: "Stored"
            )
        ]

        let resolved = try! #require(
            SprayBlockAttributionDisplay.resolve(stored, paddocks: vineyardBlocks)
        )
        #expect(resolved[0].isLive)
        #expect(resolved[0].name == "Home Block")
    }

    // MARK: - 5. Templates

    @Test func templateKeepsBlockIdentityAndDropsPerBlockGeometry() {
        let snapshot = SprayApplicationSnapshot(
            plan: plan(for: [blockInput(id: blockAId, name: "Home Block", grossHa: 10)])
        )

        let template = try! #require(snapshot.templateConfiguration())
        let blocks = try! #require(template.blocks)

        // Identity is reusable intent: "my powdery spray on the home blocks".
        #expect(blocks[0].blockId == blockAId.uuidString)
        #expect(blocks[0].blockName == "Home Block")
        // The per-block OUTPUTS are not: they must be recalculated per spray, for
        // the same reason the aggregates are cleared.
        #expect(blocks[0].grossAreaHa == nil)
        #expect(blocks[0].rowLengthMetres == nil)
        #expect(blocks[0].rowSpacingMetres == nil)
        #expect(blocks[0].rowCount == nil)
        #expect(blocks[0].geometrySource == nil)
        #expect(blocks[0].geometryQuality == nil)
        #expect(template.grossAreaHa == nil)
        #expect(template.canonicalRowLengthMetres == nil)
    }

    @Test func templateInstantiationFreezesTheOperatorsFinalSelection() {
        let template = try! #require(
            SprayApplicationSnapshot(
                plan: plan(for: [blockInput(id: blockAId, name: "Home Block", grossHa: 10)])
            ).templateConfiguration()
        )

        // The operator opens the template and changes the selection to A + C. The NEW
        // spray must freeze what they finally chose, not what the template said.
        let newSpray = SprayApplicationSnapshot(
            plan: plan(for: [
                blockInput(id: blockAId, name: "Home Block", grossHa: 10),
                blockInput(id: blockCId, name: "Hill Block", grossHa: 14),
            ])
        )

        #expect(template.treatedBlockIds == [blockAId.uuidString])
        #expect(newSpray.treatedBlockIds == [blockAId.uuidString, blockCId.uuidString])
        // The new spray carries real geometry; the template never did.
        #expect(newSpray.grossAreaHa != nil)
    }

    @Test func templateBlockThatNoLongerExistsIsDetectable() {
        let template = SprayApplicationSnapshot(
            blocks: [
                SprayApplicationBlockSnapshot(
                    blockId: ghostBlockId.uuidString,
                    blockName: "Old Trial Block"
                )
            ]
        )

        let liveIds = Set(vineyardBlocks.map { $0.id.uuidString.lowercased() })
        let missing = template.treatedBlockIds.filter { !liveIds.contains($0.lowercased()) }

        // Surfaced, never silently substituted with another block.
        #expect(missing == [ghostBlockId.uuidString])
    }

    @Test func templatesAreExcludedFromResistanceHistory() {
        let template = record(blocks: resolverBlocks([blockAId]), isTemplate: true)

        let result = ResistanceEventSource.events(
            from: [ResistanceEventSource.input(from: template)],
            seasonCalendar: calendar
        )

        // A template is intent, not an application: it must never consume a block's
        // resistance allowance.
        #expect(result.events.isEmpty)
        #expect(result.templateRecordIds == [template.id.uuidString])
        // And it is NOT reported as unresolved attribution — it is not a real spray.
        #expect(!result.hasUnresolvedBlockAttribution)
    }

    // MARK: - 6. Manual form attribution domain

    @Test func manualCreateWithTwoBlocksPersistsExactlyThoseTwo() {
        let attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds: [blockAId.uuidString, blockCId.uuidString],
            recordedBlocks: nil,
            availableBlocks: vineyardBlocks,
            isEdit: false
        )

        let blocks = try! #require(attribution)
        #expect(blocks.blockIds == [blockAId.uuidString, blockCId.uuidString])
        #expect(!blocks.blockIds.contains(blockBId.uuidString))
        #expect(blocks[0].blockName == "Home Block")
        #expect(blocks[1].blockName == "Hill Block")
    }

    @Test func manualCreateWithNoSelectionRecordsNothing() {
        let attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds: [],
            recordedBlocks: nil,
            availableBlocks: vineyardBlocks,
            isEdit: false
        )

        #expect(attribution == nil)
        #expect(SprayManualBlockAttribution.geometryToPersist(existing: nil, blocks: nil) == nil)
    }

    @Test func manualAttributionValuesComeFromTheCanonicalResolver() {
        let attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds: [blockAId.uuidString, blockCId.uuidString],
            recordedBlocks: nil,
            availableBlocks: vineyardBlocks,
            isEdit: false
        )

        // Manual entry must not become a second geometry implementation.
        #expect(attribution == resolverBlocks([blockAId, blockCId]))
    }

    @Test func editingAnUnrelatedFieldOnALegacyRecordLeavesAttributionNil() {
        let attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds: [],
            recordedBlocks: nil,
            availableBlocks: vineyardBlocks,
            isEdit: true
        )

        // Nobody is asked to invent where a historical spray went, and the vineyard's
        // current blocks are never adopted on their behalf.
        #expect(attribution == nil)
        #expect(
            SprayManualBlockAttribution.geometryToPersist(existing: nil, blocks: attribution) == nil
        )
    }

    @Test func nilBecomesABlockOnlyWhenTheOperatorDeliberatelySelectsIt() {
        let corrected = SprayManualBlockAttribution.resolve(
            selectedBlockIds: [blockAId.uuidString],
            recordedBlocks: nil,
            availableBlocks: vineyardBlocks,
            isEdit: true
        )

        #expect(corrected?.blockIds == [blockAId.uuidString])
        let geometry = try! #require(
            SprayManualBlockAttribution.geometryToPersist(existing: nil, blocks: corrected)
        )
        #expect(geometry.hasRecordedBlocks)
        // A correction records ONLY what was chosen.
        #expect(geometry.treatedBlockIds == [blockAId.uuidString])
    }

    @Test func editingAnUnrelatedFieldPreservesCalculatedGeometry() {
        let original = resolverBlocks([blockAId, blockCId])
        let stored = SprayApplicationSnapshot(
            grossAreaHa: 24,
            treatedAreaHa: 7.5,
            bandWidthTotalMetres: 1.2,
            canonicalRowLengthMetres: 31_250,
            totalCarrierLitres: 2_250,
            blocks: original
        )

        // Selection untouched — the operator only changed the wind speed.
        let attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds: original.blockIds,
            recordedBlocks: stored.blocks,
            availableBlocks: vineyardBlocks,
            isEdit: true
        )
        let persisted = try! #require(
            SprayManualBlockAttribution.geometryToPersist(existing: stored, blocks: attribution)
        )

        // Every frozen aggregate survives. This is the regression that mattered: the
        // form used to rebuild the snapshot and silently clear all of these.
        #expect(abs((persisted.grossAreaHa ?? 0) - 24) < tolerance)
        #expect(abs((persisted.treatedAreaHa ?? 0) - 7.5) < tolerance)
        #expect(abs((persisted.canonicalRowLengthMetres ?? 0) - 31_250) < tolerance)
        #expect(abs((persisted.bandWidthTotalMetres ?? 0) - 1.2) < tolerance)
        #expect(abs((persisted.totalCarrierLitres ?? 0) - 2_250) < tolerance)
        #expect(persisted.blocks == original)
    }

    @Test func unchangedSelectionIsReturnedVerbatimRatherThanRefrozen() {
        // A stored snapshot that deliberately disagrees with today's geometry, as
        // happens after a block is resurveyed.
        let historical = [
            SprayApplicationBlockSnapshot(
                blockId: blockAId.uuidString,
                blockName: "Home Block (2019 survey)",
                grossAreaHa: 4,
                rowLengthMetres: 5_000
            )
        ]

        let attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds: [blockAId.uuidString],
            recordedBlocks: historical,
            availableBlocks: vineyardBlocks,
            isEdit: true
        )

        // Today's resolver would say 10,000 m. The record keeps saying 5,000 m,
        // because that is what was true when the spray happened.
        #expect(attribution == historical)
        #expect(abs((attribution?[0].rowLengthMetres ?? 0) - 5_000) < tolerance)
    }

    @Test func aDeletedBlockKeepsItsAttributionWhenTheSelectionChanges() {
        let stored = [
            SprayApplicationBlockSnapshot(
                blockId: ghostBlockId.uuidString,
                blockName: "Old Trial Block",
                grossAreaHa: 1.5
            )
        ] + resolverBlocks([blockAId])

        // The operator now also ticks C. The ghost block must survive.
        let attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds: [ghostBlockId.uuidString, blockAId.uuidString, blockCId.uuidString],
            recordedBlocks: stored,
            availableBlocks: vineyardBlocks,
            isEdit: true
        )

        let blocks = try! #require(attribution)
        #expect(blocks.blockIds == [
            ghostBlockId.uuidString, blockAId.uuidString, blockCId.uuidString,
        ])
        #expect(blocks[0].blockName == "Old Trial Block")
        #expect(abs((blocks[0].grossAreaHa ?? 0) - 1.5) < tolerance)
    }

    @Test func selectionOrderIsPreservedAndDuplicatesCollapse() {
        let attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds: [blockCId.uuidString, blockAId.uuidString, blockCId.uuidString],
            recordedBlocks: nil,
            availableBlocks: vineyardBlocks,
            isEdit: false
        )

        #expect(attribution?.blockIds == [blockCId.uuidString, blockAId.uuidString])
    }

    // MARK: - 7. Export display rule

    @Test func exportListsHumanNamesAndMachineIds() {
        let stored = resolverBlocks([blockAId, blockCId])

        #expect(
            SprayBlockAttributionDisplay.summary(stored, paddocks: vineyardBlocks)
                == "Home Block, Hill Block"
        )
        #expect(
            SprayBlockAttributionDisplay.namesCell(stored, paddocks: vineyardBlocks)
                == "Home Block; Hill Block"
        )
        #expect(
            SprayBlockAttributionDisplay.idsCell(stored)
                == "\(blockAId.uuidString); \(blockCId.uuidString)"
        )
    }

    @Test func exportOfUnrecordedAttributionSaysSoAndLeavesMachineCellsEmpty() {
        // The PDF gets prose a human can act on...
        #expect(
            SprayBlockAttributionDisplay.summary(nil, paddocks: vineyardBlocks)
                == SprayBlockAttributionDisplay.notRecorded
        )
        // ...and the machine cells stay empty, so no parser has to match English.
        #expect(SprayBlockAttributionDisplay.namesCell(nil, paddocks: vineyardBlocks).isEmpty)
        #expect(SprayBlockAttributionDisplay.idsCell(nil).isEmpty)
    }

    @Test func exportNeverListsCurrentBlocksForAnUnknownRecord() {
        let summary = SprayBlockAttributionDisplay.summary(nil, paddocks: vineyardBlocks)

        #expect(!summary.contains("Home Block"))
        #expect(!summary.contains("River Block"))
        #expect(!summary.contains("Hill Block"))
    }

    @Test func exportIdCellStaysSplittableOnItsSeparator() {
        let stored = resolverBlocks([blockAId, blockBId, blockCId])

        let parsed = SprayBlockAttributionDisplay.idsCell(stored)
            .components(separatedBy: SprayBlockAttributionDisplay.machineSeparator)

        #expect(parsed == [blockAId.uuidString, blockBId.uuidString, blockCId.uuidString])
    }

    // MARK: - 8. Resistance projection from persisted history

    @Test func persistedAttributionProjectsOneEventPerTreatedBlock() {
        let spray = record(blocks: resolverBlocks([blockAId, blockCId]))

        // No override: the adapter reads the record's own persisted attribution.
        let result = ResistanceEventSource.events(
            from: [ResistanceEventSource.input(from: spray)],
            seasonCalendar: calendar
        )

        #expect(result.events.count == 2)
        #expect(Set(result.events.map(\.blockId)) == [blockAId.uuidString, blockCId.uuidString])
        // Block B was never sprayed and must not appear.
        #expect(!result.events.contains { $0.blockId == blockBId.uuidString })
        // Both projected events belong to the SAME application, so cost and spray
        // history never double-count the pass.
        #expect(Set(result.events.map(\.applicationId)) == [spray.id.uuidString])
        #expect(!result.hasUnresolvedBlockAttribution)
    }

    @Test func aLegacyRecordIsReportedUnresolvedAndEntersNoBlockHistory() {
        let legacy = record(blocks: nil)

        let result = ResistanceEventSource.events(
            from: [ResistanceEventSource.input(from: legacy)],
            seasonCalendar: calendar
        )

        #expect(result.events.isEmpty)
        #expect(result.hasUnresolvedBlockAttribution)
        #expect(result.unattributedToBlockRecordIds == [legacy.id.uuidString])
    }

    @Test func unresolvedAndAttributedApplicationsCoexistWithoutContamination() {
        let attributed = record(blocks: resolverBlocks([blockAId]))
        let legacy = record(blocks: nil)

        let result = ResistanceEventSource.events(
            from: [
                ResistanceEventSource.input(from: attributed),
                ResistanceEventSource.input(from: legacy),
            ],
            seasonCalendar: calendar
        )

        // Block A's definite history contains exactly the attributed spray...
        #expect(result.events.map(\.applicationId) == [attributed.id.uuidString])
        // ...while the legacy spray is reported separately, so a per-block answer can
        // be qualified as incomplete rather than presented as clean.
        #expect(result.unattributedToBlockRecordIds == [legacy.id.uuidString])
    }

    // MARK: - 9. The three unknowns stay separate dimensions

    @Test func knownBlockWithUnknownTargetIsTargetUncertaintyOnly() {
        let spray = record(blocks: resolverBlocks([blockAId]), targets: nil)

        let result = ResistanceEventSource.events(
            from: [ResistanceEventSource.input(from: spray)],
            seasonCalendar: calendar
        )

        // The block is known, so this is NOT block-attribution uncertainty.
        #expect(!result.hasUnresolvedBlockAttribution)
        #expect(result.events.count == 1)
        #expect(result.events[0].blockId == blockAId.uuidString)
        // The target is what is missing, and it stays missing.
        #expect(!result.events[0].targetsRecorded)
    }

    @Test func unknownBlockWithKnownTargetIsBlockUncertaintyOnly() {
        let spray = record(blocks: nil, targets: [.powderyMildew])

        let result = ResistanceEventSource.events(
            from: [ResistanceEventSource.input(from: spray)],
            seasonCalendar: calendar
        )

        #expect(result.hasUnresolvedBlockAttribution)
        let unresolved = try! #require(result.unresolvedBlockApplications.first)
        // The target IS known, so a caller can say precisely which disease the
        // incomplete attribution bears on.
        #expect(unresolved.targetsRecorded)
        #expect(unresolved.targets == [.powderyMildew])
        #expect(unresolved.mayConcern(.powderyMildew))
        #expect(!unresolved.mayConcern(.downyMildew))
    }

    @Test func unrecordedTargetsOnAnUnattributedSprayMayConcernAnyDisease() {
        let spray = record(blocks: nil, targets: nil)

        let result = ResistanceEventSource.events(
            from: [ResistanceEventSource.input(from: spray)],
            seasonCalendar: calendar
        )

        let unresolved = try! #require(result.unresolvedBlockApplications.first)
        // Two unknowns compound rather than cancel.
        #expect(unresolved.mayConcern(.powderyMildew))
        #expect(unresolved.mayConcern(.downyMildew))
    }

    @Test func blockAttributionIsIndependentOfChemistryAvailability() {
        // No chemical snapshot anywhere, yet the block attribution is fully known.
        let spray = record(blocks: resolverBlocks([blockAId, blockCId]))

        let result = ResistanceEventSource.events(
            from: [ResistanceEventSource.input(from: spray)],
            seasonCalendar: calendar
        )

        #expect(!result.hasUnresolvedBlockAttribution)
        #expect(Set(result.events.map(\.blockId)) == [blockAId.uuidString, blockCId.uuidString])
        #expect(result.events.allSatisfy { $0.products.isEmpty })
    }

    // MARK: - 10. Candidate per-block scoping

    @Test func aCandidateSelectionProjectsPerBlockRatherThanVineyardWide() {
        let candidateBlocks = SprayManualBlockAttribution.resolve(
            selectedBlockIds: [blockAId.uuidString, blockCId.uuidString],
            recordedBlocks: nil,
            availableBlocks: vineyardBlocks,
            isEdit: false
        )
        // No endTime: not yet applied, so this is a PLANNED event.
        let candidate = record(blocks: candidateBlocks, endTime: nil)

        let result = ResistanceEventSource.events(
            from: [ResistanceEventSource.input(from: candidate)],
            seasonCalendar: calendar
        )

        // Two blocks in, two independently-evaluable events out. Never one
        // vineyard-wide event to be filtered down afterwards.
        #expect(result.events.count == 2)
        #expect(Set(result.events.map(\.blockId)) == [blockAId.uuidString, blockCId.uuidString])
        #expect(!result.events.contains { $0.blockId == blockBId.uuidString })
        #expect(result.events.allSatisfy { $0.kind == .planned })
    }

    @Test func candidateEventsCarryEachBlocksOwnHistorySeparately() {
        // A has prior history; C does not. The projection must keep them apart so a
        // per-block evaluation cannot borrow A's history for C.
        let history = record(blocks: resolverBlocks([blockAId]))
        let candidate = record(blocks: resolverBlocks([blockAId, blockCId]), endTime: nil)

        let result = ResistanceEventSource.events(
            from: [
                ResistanceEventSource.input(from: history),
                ResistanceEventSource.input(from: candidate),
            ],
            seasonCalendar: calendar
        )

        let byBlock = Dictionary(grouping: result.events, by: \.blockId)
        #expect(
            Set(byBlock[blockAId.uuidString]?.map(\.applicationId) ?? [])
                == [history.id.uuidString, candidate.id.uuidString]
        )
        #expect(
            byBlock[blockCId.uuidString]?.map(\.applicationId) == [candidate.id.uuidString]
        )
    }

    // MARK: - 11. No historical guessing

    @Test func attributionIsNeverDerivedFromRowNumbersOrNames() {
        // Row numbers are not unique across blocks and carry no block reference, so
        // they must never become attribution.
        let legacy = record(blocks: nil)

        let result = ResistanceEventSource.events(
            from: [ResistanceEventSource.input(from: legacy)],
            seasonCalendar: calendar
        )

        #expect(result.events.isEmpty)
        #expect(result.unattributedToBlockRecordIds == [legacy.id.uuidString])
    }

    @Test func anExplicitAuthoritativeOverrideIsTheOnlyWayToSupplyBlocks() {
        // The override exists for an import that has genuinely authoritative external
        // attribution. It is not a hook for inference, and without it nothing is
        // invented.
        let legacy = record(blocks: nil)

        let guessed = ResistanceEventSource.events(
            from: [ResistanceEventSource.input(from: legacy)],
            seasonCalendar: calendar
        )
        let supplied = ResistanceEventSource.events(
            from: [
                ResistanceEventSource.input(
                    from: legacy,
                    blockIdsOverride: [blockAId.uuidString]
                )
            ],
            seasonCalendar: calendar
        )

        #expect(guessed.events.isEmpty)
        #expect(supplied.events.map(\.blockId) == [blockAId.uuidString])
    }
}
