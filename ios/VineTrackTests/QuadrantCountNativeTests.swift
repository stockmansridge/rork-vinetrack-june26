import Foundation
import Testing
@testable import VineTrack

@MainActor
struct QuadrantCountNativeTests {
    @Test func independentNormalizationAndRealRepositoryRestartRetainRawEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = PersistenceStore(directory: root)
        let vm = YieldEstimationViewModel()
        let vineyard = UUID(), block = UUID()
        vm.startNewTrip(); vm.countMethod = "quadrant"; vm.selectedPaddockIds = [block]
        vm.sampleSites = [SampleSite(paddockId: block, rowNumber: 1, latitude: 1, longitude: 2, siteIndex: 1),
                          SampleSite(paddockId: block, rowNumber: 2, latitude: 3, longitude: 4, siteIndex: 2)]
        let a = try #require(QuadrantCountMeasurement.make(rawBunchCount: 12, sectionLengthCm: 60, vineSpacingCm: 100, isSystemAdmin: true))
        let b = try #require(QuadrantCountMeasurement.make(rawBunchCount: 12, sectionLengthCm: 50, vineSpacingCm: 100, isSystemAdmin: true))
        #expect(a.bunchesPerVine == 20); #expect(b.bunchesPerVine == 24)
        #expect(vm.recordQuadrantCount(siteId: vm.sampleSites[0].id, measurement: a, recordedBy: "fixture", isSystemAdmin: true))
        #expect(vm.recordQuadrantCount(siteId: vm.sampleSites[1].id, measurement: b, recordedBy: "fixture", isSystemAdmin: true))
        let original = vm.toSession(vineyardId: vineyard, samplesPerHectare: 20)
        try YieldRepository(persistence: disk).saveLocalSession(original, at: Date())
        let repo = YieldRepository(persistence: PersistenceStore(directory: root))
        let saved = try #require(repo.loadAllSessions().first)
        #expect(saved.id == original.id && saved.quadrantSectionLengthCm == 50)
        #expect(saved.sampleSites[0].bunchCountEntry?.quadrant == a)
        #expect(saved.sampleSites[1].bunchCountEntry?.quadrant == b)
        let mean = saved.sampleSites.reduce(0.0) { $0 + ($1.bunchCountEntry?.bunchesPerVine ?? 0) } / 2
        #expect(mean == 22)
        let paddock = Paddock(id: block, vineyardId: vineyard, name: "Fixture", vineSpacing: 1,
            vineCountOverride: 1000, varietyAllocations: [PaddockVarietyAllocation(varietyId: vineyard, percent: 100, name: "Shiraz", varietyKey: "shiraz")])
        let weights = [CurrentYieldEstimate.key(blockId: block, varietyKey: "shiraz"):
            YieldMasterWeight(bunchWeightGrams: 150, source: "variety_default", recordId: UUID(), varietyKey: "shiraz")]
        let estimate = CurrentYieldEstimate.trip(session: saved, paddocks: [paddock], weights: weights)
        #expect(estimate.blocks.first?.averageBunches == 22)
        #expect(abs(try #require(estimate.totalTonnes) - 3.3) < 1e-12)
        #expect(estimate.countMethod == "Quadrant Count")
        let wire = try JSONEncoder().encode(BackendYieldEstimationSession.upsert(from: saved, createdBy: nil, clientUpdatedAt: Date()))
        let object = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let payload = try #require(object["payload"] as? [String: Any])
        #expect(payload["countMethod"] as? String == "quadrant")
        let restored = YieldEstimationViewModel(); restored.loadSession(saved)
        #expect(restored.isQuadrantCount && restored.quadrantSectionLengthCm == 50)
        let token = try #require(repo.pendingSessionIntents()[saved.id]?.token)
        try repo.acknowledgeSessionSaves([saved.id: token])
        #expect(repo.pendingSessionSaves().isEmpty)
        #expect(repo.loadAllSessions().first?.sampleSites[0].bunchCountEntry?.quadrant == a)
    }

    @Test func failedDurableSampleCommitRollsBackRecordedStateAndPreservesEarlierIntent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = PersistenceStore(directory: root), vineyard = UUID(), block = UUID()
        let store = MigratedDataStore(persistence: disk); store.selectedVineyardId = vineyard
        let vm = YieldEstimationViewModel(); vm.startNewTrip(); vm.countMethod = "quadrant"
        vm.sampleSites = [SampleSite(paddockId: block, rowNumber: 1, latitude: 1, longitude: 2, siteIndex: 1)]
        let site = vm.sampleSites[0].id
        #expect(store.saveYieldSession(vm.toSession(vineyardId: vineyard, samplesPerHectare: 20), isSystemAdmin: true))
        let token = store.yieldRepo.pendingSessionIntents()[vm.sessionId!]?.token
        disk.durableSaveFailureForTesting = { _ in CocoaError(.fileWriteOutOfSpace) }
        let measurement = try #require(QuadrantCountMeasurement.make(rawBunchCount: 12, sectionLengthCm: 50, vineSpacingCm: 100, isSystemAdmin: true))
        let accepted = vm.saveQuadrantCount(siteId: site, measurement: measurement, recordedBy: "fixture", isSystemAdmin: true) {
            store.saveYieldSession(vm.toSession(vineyardId: vineyard, samplesPerHectare: 20), isSystemAdmin: true)
        }
        #expect(!accepted); #expect(vm.recordedSiteCount == 0); #expect(vm.quadrantSectionLengthCm == 60)
        #expect(store.yieldRepo.pendingSessionIntents()[vm.sessionId!]?.token == token)
        disk.durableSaveFailureForTesting = nil
        #expect(vm.saveQuadrantCount(siteId: site, measurement: measurement, recordedBy: "fixture", isSystemAdmin: true) {
            store.saveYieldSession(vm.toSession(vineyardId: vineyard, samplesPerHectare: 20), isSystemAdmin: true)
        })
        #expect(vm.recordedSiteCount == 1 && vm.quadrantSectionLengthCm == 50)
    }

    @Test func durableRoleGatePreventsMetadataStrippingButLeavesLegacyAvailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: root)), vineyard = UUID()
        store.selectedVineyardId = vineyard
        let quadrant = YieldEstimationSession(vineyardId: vineyard, countMethod: "quadrant", quadrantSectionLengthCm: 60)
        #expect(!store.saveYieldSession(quadrant))
        #expect(store.yieldRepo.loadAllSessions().isEmpty)
        #expect(store.saveYieldSession(quadrant, isSystemAdmin: true))
        var stripped = quadrant; stripped.countMethod = nil; stripped.quadrantSectionLengthCm = nil
        #expect(!store.saveYieldSession(stripped, isSystemAdmin: true))
        #expect(!store.saveYieldSession(quadrant, isSystemAdmin: false))
        #expect(store.saveYieldSession(YieldEstimationSession(vineyardId: vineyard)))
        #expect(store.yieldRepo.loadAllSessions().count == 2)
    }

    @Test func invalidMeasurementsAndNonAdminAreRejectedAndZeroIsValid() {
        for count in [-1.0, 1.5, .infinity, .nan] {
            #expect(QuadrantCountMeasurement.make(rawBunchCount: count, sectionLengthCm: 60, vineSpacingCm: 100, isSystemAdmin: true) == nil)
        }
        for spacing: Double? in [nil, 0, -1, .infinity, .nan] {
            #expect(QuadrantCountMeasurement.make(rawBunchCount: 12, sectionLengthCm: 60, vineSpacingCm: spacing, isSystemAdmin: true) == nil)
        }
        for length in [0.0, -1, .infinity, .nan] {
            #expect(QuadrantCountMeasurement.make(rawBunchCount: 12, sectionLengthCm: length, vineSpacingCm: 100, isSystemAdmin: true) == nil)
        }
        #expect(QuadrantCountMeasurement.make(rawBunchCount: 12, sectionLengthCm: 60, vineSpacingCm: 100, isSystemAdmin: false) == nil)
        #expect(QuadrantCountMeasurement.make(rawBunchCount: 0, sectionLengthCm: 60, vineSpacingCm: 100, isSystemAdmin: true)?.bunchesPerVine == 0)
    }

    @Test func rejectedCompletionDoesNotLockOrChangeSnapshots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = PersistenceStore(directory: root), vineyard = UUID()
        let store = MigratedDataStore(persistence: disk); store.selectedVineyardId = vineyard
        let vm = YieldEstimationViewModel(); vm.startNewTrip(); vm.countMethod = "quadrant"
        #expect(store.saveYieldSession(vm.toSession(vineyardId: vineyard, samplesPerHectare: 20), isSystemAdmin: true))
        let original = store.yieldRepo.pendingSessionIntents()[vm.sessionId!]?.token
        disk.durableSaveFailureForTesting = { _ in CocoaError(.fileWriteOutOfSpace) }
        #expect(!vm.saveCompletion(paddocks: []) {
            store.saveYieldSession(vm.toSession(vineyardId: vineyard, samplesPerHectare: 20), isSystemAdmin: true)
        })
        #expect(!vm.isCompleted && vm.completedAt == nil && vm.blockVineCounts.isEmpty)
        #expect(store.yieldRepo.pendingSessionIntents()[vm.sessionId!]?.token == original)
        disk.durableSaveFailureForTesting = nil
        #expect(vm.saveCompletion(paddocks: []) {
            store.saveYieldSession(vm.toSession(vineyardId: vineyard, samplesPerHectare: 20), isSystemAdmin: true)
        })
        #expect(vm.isCompleted && store.yieldRepo.loadAllSessions().first?.isCompleted == true)
    }

    @Test func legacyDecodeAndFullVineEntryRemainUnchanged() throws {
        let entry = try JSONDecoder().decode(BunchCountEntry.self, from: Data("{\"bunchesPerVine\":9,\"recordedAt\":0,\"recordedBy\":\"a\"}".utf8))
        #expect(entry.quadrant == nil && entry.bunchesPerVine == 9)
        let vm = YieldEstimationViewModel(); vm.startNewTrip()
        vm.sampleSites = [SampleSite(paddockId: UUID(), rowNumber: 1, latitude: 1, longitude: 2, siteIndex: 1)]
        vm.recordBunchCount(siteId: vm.sampleSites[0].id, bunchesPerVine: 12.5, recordedBy: "fixture")
        #expect(vm.sampleSites[0].bunchCountEntry?.bunchesPerVine == 12.5)
        let session = vm.toSession(vineyardId: UUID(), samplesPerHectare: 20)
        #expect(!session.isQuadrantCount && session.countMethod == nil && session.quadrantSectionLengthCm == nil)
    }
}
