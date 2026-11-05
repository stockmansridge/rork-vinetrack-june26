import Foundation
import XCTest
@testable import VineTrack

final class GPSPersistencePerformanceTests: XCTestCase {
    @MainActor func testPairedGPSBaselineIncludesRealDirtyMetadataAndRowGuidance() async throws {
        var results: [String] = []
        for size in [100, 2_000, 10_000, 60_000] {
            var times: [Double] = []
            for compact in [false, true] {
                let fixture = try GPSPersistenceFixture(points: size, compact: compact)
                defer { fixture.cleanup() }
                // Warm one save without counting it; compare six appended fixes.
                fixture.append(0)
                let start = fixture.gps.count
                for index in 1...6 {
                    fixture.append(index)
                    await Task.yield()
                }
                XCTAssertTrue(fixture.verify(), "All accepted points and 500 retained queue entries must survive a fresh store")
                XCTAssertTrue(fixture.tracking.rowGuidanceAvailable, "The row-guidance work must actually run")
                XCTAssertTrue(fixture.storage.contains { $0.dataset == .metadata && $0.operation == .save && $0.succeeded })
                XCTAssertTrue(fixture.storage.contains { $0.dataset == .trips && $0.operation == .read && $0.reusedDecode })
                let samples = fixture.gps.dropFirst(start).map(\.totalMS)
                XCTAssertEqual(samples.count, 6)
                times.append(GPSPersistenceFixture.percentile(samples))
                results.append("points=\(size) compact=\(compact)\n\(fixture.summary)")
            }
            if size == 60_000 {
                XCTAssertLessThan(times[1], times[0] * 0.90, "The candidate must measurably improve paired large-history GPS occupancy")
            }
        }
        let report = results.joined(separator: "\n\n")
        print("P0_PAIRED_GPS\n" + report)
        let attachment = XCTAttachment(string: report); attachment.name = "Paired real GPS phase measurements"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testTripCompactAndLegacyAreSemanticallyIdenticalWithFailureAndExternalWriter() throws {
        let fixture = try GPSPersistenceFixture(points: 2_000, compact: true)
        defer { fixture.cleanup() }
        fixture.append(0)
        let original = try XCTUnwrap(fixture.store.deviceOwnedTrip)
        let file = fixture.directory.appendingPathComponent(TripRepository.storageKey + ".json")
        let compact = try Data(contentsOf: file)
        let legacy = PersistenceStore(directory: fixture.directory)
        legacy.compactTripEncodingForTesting = false
        try legacy.saveOrThrow([original], key: TripRepository.storageKey)
        let pretty = try Data(contentsOf: file)
        XCTAssertLessThan(compact.count, pretty.count)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: compact) as? NSArray,
                       try JSONSerialization.jsonObject(with: pretty) as? NSArray)
        XCTAssertEqual(fixture.persistence.load(key: TripRepository.storageKey) as [Trip]?, [original])
        var changed = original
        changed.startEngineHours = 123.12345678912345
        changed.isPaused = true
        try legacy.saveOrThrow([changed], key: TripRepository.storageKey)
        XCTAssertEqual(fixture.persistence.load(key: TripRepository.storageKey) as [Trip]?, [changed])
        fixture.persistence.durableSaveFailureForTesting = { _ in CocoaError(.fileWriteUnknown) }
        XCTAssertThrowsError(try fixture.persistence.saveOrThrow([original], key: TripRepository.storageKey))
        XCTAssertEqual(PersistenceStore(directory: fixture.directory).load(key: TripRepository.storageKey) as [Trip]?, [changed])
        fixture.persistence.durableSaveFailureForTesting = nil
        try Data("corrupt".utf8).write(to: file, options: .atomic)
        let outcome: PersistenceStore.LoadOutcome<[Trip]> = fixture.persistence.loadOutcome(key: TripRepository.storageKey)
        guard case .failed = outcome else { XCTFail("A compact-write memo must never hide corruption"); return }
    }

    @MainActor func testOfflineUploadActuallyOverlapsGPSAndRetainsQueue() async throws {
        let fixture = try GPSPersistenceFixture(points: 100, compact: true)
        defer { fixture.cleanup() }
        let push = Task { @MainActor in try await fixture.sync.pushLocalTrips(vineyardId: fixture.vineyard) }
        var overlap = false
        for index in 0..<25 {
            try await Task.sleep(for: .milliseconds(20))
            if fixture.transport.inFlight > 0 { overlap = true }
            fixture.append(index)
        }
        _ = await push.result
        XCTAssertTrue(overlap)
        XCTAssertGreaterThan(fixture.transport.attempts, 0)
        XCTAssertEqual(fixture.metadata.pendingUpserts.count, 501)
        XCTAssertTrue(fixture.verify())
    }

    @MainActor func testSustainedEmptyRouteRecordingWithConcurrentOfflineSync() async throws {
        let fixture = try GPSPersistenceFixture(points: 0, compact: true)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.store.deviceOwnedTrip?.pathPoints.count, 0)
        let started = ProcessInfo.processInfo.systemUptime
        var rss: [Double] = [GPSPersistenceFixture.rssMB()]
        var count = 0
        var overlappingFixes = 0
        let syncTask = Task { @MainActor in
            for _ in 0..<60 {
                fixture.sync.clearRetryCooldowns()
                do { try await fixture.sync.pushLocalTrips(vineyardId: fixture.vineyard) }
                catch { /* Expected offline failure; the next sweep must still run. */ }
                try await Task.sleep(for: .seconds(2))
            }
        }
        defer { syncTask.cancel() }
        while ProcessInfo.processInfo.systemUptime - started < 120 {
            try Task.checkCancellation()
            if fixture.transport.inFlight > 0 { overlappingFixes += 1 }
            fixture.append(count)
            count += 1
            if count % 200 == 0 { rss.append(GPSPersistenceFixture.rssMB()) }
            try await Task.sleep(for: .milliseconds(50))
        }
        syncTask.cancel()
        _ = await syncTask.result
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        rss.append(GPSPersistenceFixture.rssMB())
        XCTAssertGreaterThanOrEqual(elapsed, 120)
        XCTAssertGreaterThan(count, 1_000)
        XCTAssertEqual(fixture.injectedIDs.count, count)
        XCTAssertEqual(fixture.store.deviceOwnedTrip?.pathPoints.count, count)
        XCTAssertGreaterThan(overlappingFixes, 0, "The GPS fixes must overlap actual awaited production sync requests")
        XCTAssertGreaterThan(fixture.transport.attempts, 0)
        XCTAssertTrue(fixture.verify())
        XCTAssertEqual(fixture.metadata.pendingUpserts.count, 501, "An offline transport must never acknowledge any queued identity")
        let report = "elapsed=\(elapsed)s; requested interval=50ms plus processing; accepted=\(count); overlapping=\(overlappingFixes); offline attempts=\(fixture.transport.attempts)\nRSS MB=\(rss)\n\(fixture.summary)\nFresh persistence-instance readback verified; not a process restart, live HTTP or leak/jetsam diagnosis."
        print("P0_SUSTAINED_GPS\n" + report)
        let attachment = XCTAttachment(string: report); attachment.name = "120 second point-by-point recording and offline sync"
        attachment.lifetime = .keepAlways; add(attachment)
    }
}
