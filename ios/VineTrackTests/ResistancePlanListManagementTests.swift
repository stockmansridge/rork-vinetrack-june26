import Foundation
import Testing

@testable import VineTrack

/// Plan-list management tests: duplication identity rules, multiple plans for the
/// SAME season and disease, per-plan isolation, and archive.
///
/// These pin the Plan List contract: mobile never auto-selects a plan, so the data
/// layer must make several same-season/same-disease plans first-class — stable ids,
/// independent edits, independent archives, and duplicates that mint NEW identities
/// (position ids are the seam sql/201 spray jobs point at).
///
/// Mirrors `ResistancePlanDuplicationTest.kt` on Android case for case.
@MainActor
struct ResistancePlanListManagementTests {

    private let vineyard = "vy-1"

    private func makeRepository() -> ResistancePlanRepository {
        ResistancePlanRepository(
            local: InMemoryResistancePlanLocalStore(),
            remote: nil,
            clock: { 5_000 },
            currentUserId: { "user-1" }
        )
    }

    private func position(_ id: String, _ code: String, productId: String) -> ResistancePlannedPosition {
        ResistancePlannedPosition(
            id: id,
            products: [
                ResistancePlannedProduct(
                    id: productId,
                    groups: ResistanceGroupSignature.of([code]),
                    source: .group
                ),
            ]
        )
    }

    private func makePlan(
        id: String = "plan-a",
        seasonId: String = "2026/27",
        disease: ResistanceDisease = .powderyMildew,
        notes: String? = nil
    ) -> ResistancePlan {
        ResistancePlan(
            id: id,
            vineyardId: vineyard,
            seasonId: seasonId,
            seasonStartYear: 2026,
            disease: disease,
            jurisdiction: .australia,
            crop: .grape,
            blockIds: ["block-a", "block-b"],
            positions: [
                position("pos-1", "3", productId: "prod-1"),
                position("pos-2", "11", productId: "prod-2"),
            ],
            notes: notes,
            rulesetId: "AU_GRAPE_POWDERY_2026_07_22",
            rulesetVersion: "2026.07.22",
            createdAtEpochMs: 1_000,
            updatedAtEpochMs: 1_000
        )
    }

    // MARK: - Duplication mints new identities

    @Test func duplicateMintsNewPlanAndPositionIds() {
        let source = makePlan(notes: "Plan A")
        let copy = source.duplicated(atEpochMs: 9_000, by: nil)

        #expect(copy.id != source.id)

        // Every position id is NEW — sql/201 spray jobs point at position ids, so a
        // reused id would let jobs created from Plan A claim coverage on the copy.
        let sourcePositionIds = Set(source.positions.map { $0.id })
        let copyPositionIds = Set(copy.positions.map { $0.id })
        #expect(copyPositionIds.count == source.positions.count)
        #expect(copyPositionIds.isDisjoint(with: sourcePositionIds))

        // Product ids are minted fresh too.
        let sourceProductIds = Set(source.positions.flatMap { $0.products.map { $0.id } })
        let copyProductIds = Set(copy.positions.flatMap { $0.products.map { $0.id } })
        #expect(copyProductIds.count == sourceProductIds.count)
        #expect(copyProductIds.isDisjoint(with: sourceProductIds))
    }

    @Test func duplicateCopiesContentButNeverServerState() {
        var source = makePlan(notes: "Plan A")
        source.serverRevision = 7
        let copy = source.duplicated(atEpochMs: 9_000, by: nil)

        // Content copied verbatim, order preserved.
        #expect(copy.seasonId == source.seasonId)
        #expect(copy.seasonStartYear == source.seasonStartYear)
        #expect(copy.disease == source.disease)
        #expect(copy.blockIds == source.blockIds)
        #expect(copy.positions.map { $0.componentGroups } == source.positions.map { $0.componentGroups })
        #expect(copy.rulesetId == source.rulesetId)
        #expect(copy.rulesetVersion == source.rulesetVersion)

        // SERVER STATE is not content. The copy has never been accepted by the
        // server, so its first push must be a CREATE (sql/198) — never an update
        // asserting Plan A's revision.
        #expect(copy.serverRevision == nil)
        #expect(copy.deletedAtEpochMs == nil)
        #expect(copy.createdAtEpochMs == 9_000)
        #expect(copy.updatedAtEpochMs == 9_000)
        #expect(copy.notes == "Plan A (copy)")
    }

    @Test func displayTitlePrefersNameAndFallsBackToSeasonDisease() {
        #expect(makePlan(notes: "Early cover strategy").displayTitle == "Early cover strategy")
        #expect(makePlan(notes: nil).displayTitle == "Powdery Mildew — 2026/27")
        #expect(makePlan(notes: "   \n ").displayTitle == "Powdery Mildew — 2026/27")
        // Only the first line of a multi-line note becomes the title.
        #expect(makePlan(notes: "Plan B\nlong details here").displayTitle == "Plan B")
    }

    // MARK: - Multiple plans, same season + disease

    @Test func plansForSameSeasonAndDiseaseCoexistIndependently() {
        let repository = makeRepository()
        repository.load(vineyardId: vineyard)

        repository.save(makePlan(id: "plan-a", notes: "Plan A"))
        repository.save(makePlan(id: "plan-b", notes: "Plan B"))

        #expect(repository.plans.count == 2)
        #expect(repository.plans(seasonId: "2026/27", disease: .powderyMildew).count == 2)
        #expect(repository.plan(id: "plan-a")?.notes == "Plan A")
        #expect(repository.plan(id: "plan-b")?.notes == "Plan B")
    }

    @Test func editingOnePlanNeverTouchesItsSibling() throws {
        let repository = makeRepository()
        repository.load(vineyardId: vineyard)
        repository.save(makePlan(id: "plan-a", notes: "Plan A"))
        repository.save(makePlan(id: "plan-b", notes: "Plan B"))

        let planA = try #require(repository.plan(id: "plan-a"))
        repository.save(planA.addingPosition(atEpochMs: 2_000))

        #expect(repository.plan(id: "plan-a")?.positions.count == 3)
        let untouched = try #require(repository.plan(id: "plan-b"))
        #expect(untouched.positions.count == 2)
        #expect(untouched.updatedAtEpochMs == 1_000)
        #expect(untouched.notes == "Plan B")
    }

    @Test func archivingOnePlanLeavesTheOtherLive() {
        let repository = makeRepository()
        repository.load(vineyardId: vineyard)
        repository.save(makePlan(id: "plan-a"))
        repository.save(makePlan(id: "plan-b"))

        repository.delete(id: "plan-a")

        #expect(repository.plan(id: "plan-a") == nil)
        #expect(repository.plan(id: "plan-b") != nil)
        #expect(repository.plans.count == 1)
        // The archived plan stays queued as a tombstone so the delete propagates —
        // the existing sql/196 soft-delete contract, unchanged.
        #expect(repository.isPending(id: "plan-a"))
    }

    @Test func duplicateSavedThroughRepositoryIsItsOwnRow() throws {
        let repository = makeRepository()
        repository.load(vineyardId: vineyard)
        repository.save(makePlan(id: "plan-a", notes: "Plan A"))

        let source = try #require(repository.plan(id: "plan-a"))
        let copy = source.duplicated(atEpochMs: 9_000, by: nil)
        repository.save(copy)

        #expect(repository.plans.count == 2)

        // Editing the copy leaves the source untouched — and vice versa.
        let stored = try #require(repository.plan(id: copy.id))
        repository.save(stored.settingBlockIds(["block-c"], atEpochMs: 9_500))
        #expect(repository.plan(id: "plan-a")?.blockIds == ["block-a", "block-b"])
        #expect(repository.plan(id: copy.id)?.blockIds == ["block-c"])
    }
}
