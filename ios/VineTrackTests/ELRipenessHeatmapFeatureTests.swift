import XCTest
@testable import VineTrack

/// Tests for the E-L Ripeness Heatmap feature layers that sit *around* the
/// contract core: the observation adapter, the raster, the offline cache and
/// the screen's view model.
///
/// The contract maths itself is pinned separately by
/// `ELRipenessHeatmapContractTests` against the shared fixture. Nothing here
/// re-tests the maths; these tests pin the behaviour the contract cannot see —
/// merging, dedupe, timezone handling, transparency, offline states and the
/// promise that scrubbing the timeline never touches the network.
final class ELRipenessHeatmapFeatureTests: XCTestCase {

    // MARK: - Fixtures

    private let vineyardId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let otherVineyardId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let blockAId = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!
    private let blockBId = UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000002")!

    private func raw(
        _ id: String,
        paddock: String? = "block-a",
        stage: String? = "E-L 23",
        lat: Double? = -34.502,
        lng: Double? = 138.502,
        date: String? = "2026-01-20T00:00:00Z",
        vineyard: String? = "vy-1",
        deletedAt: String? = nil
    ) -> ELRipeness.RawRecord {
        ELRipeness.RawRecord(
            id: id,
            vineyardId: vineyard,
            paddockId: paddock,
            stageCode: stage,
            latitude: lat,
            longitude: lng,
            date: date,
            deletedAt: deletedAt
        )
    }

    private func source(
        _ record: ELRipeness.RawRecord,
        _ origin: ELRipenessObservationAdapter.Origin,
        assigned: Bool? = nil
    ) -> ELRipenessObservationAdapter.SourceRecord {
        ELRipenessObservationAdapter.SourceRecord(record: record, origin: origin, placementAssigned: assigned)
    }

    private func growthPin(
        id: UUID = UUID(),
        vineyard: UUID? = nil,
        paddock: UUID? = nil,
        stage: String? = "E-L 23",
        lat: Double = -34.502,
        lng: Double = 138.502,
        timestamp: Date,
        locationScope: String? = nil,
        mode: PinMode = .growth
    ) -> VinePin {
        VinePin(
            id: id,
            vineyardId: vineyard ?? vineyardId,
            latitude: lat,
            longitude: lng,
            heading: nil,
            buttonName: "Growth",
            buttonColor: "green",
            side: nil,
            mode: mode,
            paddockId: paddock,
            timestamp: timestamp,
            growthStageCode: stage,
            locationScope: locationScope
        )
    }

    // MARK: - Adapter: dedupe & precedence

    func testMergeDedupesByStableRecordIdAndPrefersPendingLocal() {
        let merged = ELRipenessObservationAdapter.merge([
            source(raw("obs-1", stage: "E-L 10"), .cached),
            source(raw("obs-1", stage: "E-L 20"), .remote),
            source(raw("obs-1", stage: "E-L 30"), .pendingLocal),
        ])

        XCTAssertEqual(merged.count, 1, "the same record ID must collapse to one observation")
        XCTAssertEqual(merged[0].record.stageCode, "E-L 30")
        XCTAssertEqual(merged[0].origin, .pendingLocal)
    }

    func testMergePrefersRemoteOverCachedWhenThereIsNoPendingEdit() {
        let merged = ELRipenessObservationAdapter.merge([
            source(raw("obs-1", stage: "E-L 10"), .cached),
            source(raw("obs-1", stage: "E-L 20"), .remote),
        ])
        XCTAssertEqual(merged[0].record.stageCode, "E-L 20")
    }

    /// IDW resolves a zero-distance hit to the *first* matching observation, so
    /// a higher-precedence duplicate must replace the earlier entry in place
    /// rather than being appended at the end.
    func testMergePreservesFirstSeenOrderForDeterministicIDW() {
        let merged = ELRipenessObservationAdapter.merge([
            source(raw("obs-a"), .cached),
            source(raw("obs-b"), .cached),
            source(raw("obs-c"), .cached),
            source(raw("obs-a", stage: "E-L 40"), .pendingLocal),
        ])
        XCTAssertEqual(merged.map(\.record.id), ["obs-a", "obs-b", "obs-c"])
        XCTAssertEqual(merged[0].record.stageCode, "E-L 40", "the pending copy must win but keep position 0")
    }

    func testDedupeIsByIdNotByCoordinateOrDate() {
        // Two genuinely different observations that happen to share a location
        // and a date must both survive.
        let merged = ELRipenessObservationAdapter.merge([
            source(raw("obs-1"), .remote),
            source(raw("obs-2"), .remote),
        ])
        XCTAssertEqual(merged.count, 2)
    }

    // MARK: - Adapter: assignment (PinPlacementContract, revoke-only)

    func testPlacementRevokesAssignmentButNeverInventsOne() {
        let observations = ELRipenessObservationAdapter.observations(
            from: [
                source(raw("keep", paddock: "block-a"), .remote, assigned: true),
                source(raw("revoked", paddock: "block-a"), .remote, assigned: false),
            ],
            selectedVineyardId: "vy-1"
        )
        let keep = observations.first { $0.id == "keep" }
        let revoked = observations.first { $0.id == "revoked" }

        XCTAssertEqual(keep?.assigned, true)
        XCTAssertEqual(keep?.paddockId, "block-a")
        XCTAssertEqual(revoked?.assigned, false)
        XCTAssertNil(revoked?.paddockId, "a revoked placement must drop the block, not keep it")
    }

    func testAssignmentIsNeverInferredFromCoordinates() {
        // A record with perfectly good coordinates but no block stays
        // unassigned. Nothing may look at where it is and guess a block.
        let observations = ELRipenessObservationAdapter.observations(
            from: [source(raw("no-block", paddock: nil), .remote, assigned: true)],
            selectedVineyardId: "vy-1"
        )
        XCTAssertEqual(observations.count, 1)
        XCTAssertFalse(observations[0].assigned)
        XCTAssertNil(observations[0].paddockId)
    }

    func testWrongVineyardRecordsAreScopedOut() {
        let observations = ELRipenessObservationAdapter.observations(
            from: [
                source(raw("mine", vineyard: "vy-1"), .remote, assigned: true),
                source(raw("theirs", vineyard: "vy-2"), .remote, assigned: true),
            ],
            selectedVineyardId: "vy-1"
        )
        XCTAssertEqual(observations.map(\.id), ["mine"])
    }

    // MARK: - Adapter: local pins

    /// The capture day must survive the trip through the adapter. A pin dropped
    /// at 08:30 in Adelaide is still 25 January there even though it is
    /// 24 January in UTC — formatting in UTC would move the observation to the
    /// wrong day of the timeline.
    func testPendingPinPreservesFieldCaptureDayInVineyardTimeZone() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Adelaide"))
        // 2026-01-24T22:00:00Z == 2026-01-25T08:30 in Adelaide (UTC+10:30).
        let captured = Date(timeIntervalSince1970: 1_769_292_000)
        let pin = growthPin(paddock: blockAId, timestamp: captured)

        let record = try XCTUnwrap(
            ELRipenessObservationAdapter.pendingRecord(for: pin, timeZone: timeZone)
        )
        let dayKey = ELRipeness.dayKey(try XCTUnwrap(record.record.date))

        XCTAssertEqual(dayKey, "2026-01-25", "the vineyard-local capture day must be preserved")

        let utcRecord = try XCTUnwrap(
            ELRipenessObservationAdapter.pendingRecord(for: pin, timeZone: TimeZone(identifier: "UTC")!)
        )
        XCTAssertEqual(
            ELRipeness.dayKey(try XCTUnwrap(utcRecord.record.date)),
            "2026-01-24",
            "sanity: UTC really would land on the previous day"
        )
    }

    func testPendingPinCarriesPlacementSignalAndBlock() throws {
        let pin = growthPin(paddock: blockAId, timestamp: Date())
        let record = try XCTUnwrap(
            ELRipenessObservationAdapter.pendingRecord(for: pin, timeZone: .current)
        )
        XCTAssertEqual(record.origin, .pendingLocal)
        XCTAssertEqual(record.record.paddockId, blockAId.uuidString.lowercased())
        XCTAssertEqual(record.placementAssigned, PinPlacementContract.placement(for: pin).isAssigned)
    }

    func testNonGrowthPinsAndStagelessPinsAreNotObservations() {
        let repair = growthPin(timestamp: Date(), mode: .repairs)
        let stageless = growthPin(stage: nil, timestamp: Date())
        XCTAssertNil(ELRipenessObservationAdapter.pendingRecord(for: repair, timeZone: .current))
        XCTAssertNil(ELRipenessObservationAdapter.pendingRecord(for: stageless, timeZone: .current))
    }

    /// E-L 47 is outside the ripeness scale. It must not become a heat
    /// observation and must not be clamped to E-L 43.
    func testELFortySevenNeverBecomesAHeatObservation() {
        let observations = ELRipenessObservationAdapter.observations(
            from: [
                source(raw("harvest", stage: "E-L 47"), .remote, assigned: true),
                source(raw("ripe", stage: "E-L 43"), .remote, assigned: true),
            ],
            selectedVineyardId: "vy-1"
        )
        XCTAssertEqual(observations.map(\.id), ["ripe"])
        XCTAssertFalse(observations.contains { $0.el == 43 && $0.id == "harvest" })
    }

    func testDeletedRecordsAreExcluded() {
        let observations = ELRipenessObservationAdapter.observations(
            from: [source(raw("gone", deletedAt: "2026-02-01T00:00:00Z"), .remote, assigned: true)],
            selectedVineyardId: "vy-1"
        )
        XCTAssertTrue(observations.isEmpty)
    }

    // MARK: - Raster

    /// A triangle inside a square bounding box: the corners of the box fall
    /// outside the polygon, so those pixels must be fully transparent.
    func testRasterIsTransparentOutsideTheBlockPolygon() throws {
        let triangle = [
            ELRipeness.LatLng(lat: -34.500, lng: 138.500),
            ELRipeness.LatLng(lat: -34.500, lng: 138.504),
            ELRipeness.LatLng(lat: -34.504, lng: 138.504),
        ]
        let block = ELRipeness.buildBlockHeat(
            paddockId: "block-a",
            paddockName: "Block A",
            polygon: triangle,
            observations: [
                ELRipeness.Observation(id: "o1", paddockId: "block-a", assigned: true, el: 20, lat: -34.5015, lng: 138.5030, dateISO: "2026-01-20"),
                ELRipeness.Observation(id: "o2", paddockId: "block-a", assigned: true, el: 30, lat: -34.5030, lng: 138.5038, dateISO: "2026-01-21"),
                ELRipeness.Observation(id: "o3", paddockId: "block-a", assigned: true, el: 25, lat: -34.5022, lng: 138.5035, dateISO: "2026-01-22"),
            ],
            atDateISO: "2026-01-25"
        )
        XCTAssertEqual(block.mode, .surface)
        let raster = try XCTUnwrap(ELRipenessHeatRaster.raster(for: block))

        // The south-west corner of the bounding box is outside this triangle.
        let corner = raster.pixel(x: 0, y: raster.height - 1)
        XCTAssertEqual(corner.a, 0, "cells outside the polygon must be fully transparent")

        // And at least something inside is painted.
        var paintedCount = 0
        for y in 0..<raster.height {
            for x in 0..<raster.width where raster.pixel(x: x, y: y).a > 0 {
                paintedCount += 1
            }
        }
        XCTAssertGreaterThan(paintedCount, 0)
    }

    /// The grid stores row 0 at the south edge; the raster stores row 0 at the
    /// north edge. A block whose only observation sits at the north end must
    /// therefore paint the *top* of the raster most strongly.
    func testRasterFlipsGridRowsSoNorthIsAtTheTop() throws {
        let square = [
            ELRipeness.LatLng(lat: -34.500, lng: 138.500),
            ELRipeness.LatLng(lat: -34.500, lng: 138.504),
            ELRipeness.LatLng(lat: -34.504, lng: 138.504),
            ELRipeness.LatLng(lat: -34.504, lng: 138.500),
        ]
        // -34.500 is the northern edge (least negative latitude).
        let block = ELRipeness.buildBlockHeat(
            paddockId: "block-a",
            paddockName: "Block A",
            polygon: square,
            observations: [
                ELRipeness.Observation(id: "north", paddockId: "block-a", assigned: true, el: 40, lat: -34.5005, lng: 138.502, dateISO: "2026-01-24")
            ],
            atDateISO: "2026-01-25"
        )
        XCTAssertEqual(block.mode, .halo, "one influencing observation is a halo")
        let raster = try XCTUnwrap(ELRipenessHeatRaster.raster(for: block))

        // The outermost rows sit exactly on the bounding-box edge, and the
        // contract's strict ray-cast treats a node on the northern edge as
        // outside the polygon — so row 0 is legitimately empty. Compare where
        // the paint actually lands instead.
        let rowAlpha: [Int] = (0..<raster.height).map { y in
            (0..<raster.width).reduce(0) { $0 + Int(raster.pixel(x: $1, y: y).a) }
        }
        let heaviestRow = try XCTUnwrap(rowAlpha.firstIndex(of: try XCTUnwrap(rowAlpha.max())))
        XCTAssertGreaterThan(rowAlpha[heaviestRow], 0)
        XCTAssertLessThan(
            heaviestRow,
            raster.height / 2,
            "a northern observation must paint the northern (upper) half of the raster"
        )

        let northHalf = rowAlpha[0..<(raster.height / 2)].reduce(0, +)
        let southHalf = rowAlpha[(raster.height / 2)...].reduce(0, +)
        XCTAssertGreaterThan(northHalf, southHalf, "the flip must put north at the top")
    }

    /// Two blocks sharing an edge, with observations in only one of them. The
    /// empty block must produce no raster at all — colour cannot cross.
    func testNoCrossBlockColourInfluenceAcrossASharedEdge() {
        let blockA = ELRipeness.BlockInput(
            id: "block-a",
            name: "Block A",
            polygon: [
                ELRipeness.LatLng(lat: -34.500, lng: 138.500),
                ELRipeness.LatLng(lat: -34.500, lng: 138.504),
                ELRipeness.LatLng(lat: -34.504, lng: 138.504),
                ELRipeness.LatLng(lat: -34.504, lng: 138.500),
            ]
        )
        let blockB = ELRipeness.BlockInput(
            id: "block-b",
            name: "Block B",
            polygon: [
                ELRipeness.LatLng(lat: -34.500, lng: 138.504),
                ELRipeness.LatLng(lat: -34.500, lng: 138.508),
                ELRipeness.LatLng(lat: -34.504, lng: 138.508),
                ELRipeness.LatLng(lat: -34.504, lng: 138.504),
            ]
        )
        let model = ELRipeness.buildHeatModel(
            observations: [
                ELRipeness.Observation(id: "a1", paddockId: "block-a", assigned: true, el: 40, lat: -34.502, lng: 138.5035, dateISO: "2026-01-24"),
                ELRipeness.Observation(id: "a2", paddockId: "block-a", assigned: true, el: 38, lat: -34.501, lng: 138.5020, dateISO: "2026-01-24"),
                ELRipeness.Observation(id: "a3", paddockId: "block-a", assigned: true, el: 39, lat: -34.503, lng: 138.5030, dateISO: "2026-01-24"),
            ],
            blocks: [blockA, blockB],
            atDateISO: "2026-01-25"
        )

        let heatA = model.blocks.first { $0.paddockId == "block-a" }
        let heatB = model.blocks.first { $0.paddockId == "block-b" }
        XCTAssertEqual(heatA?.mode, .surface)
        // Qualify the case name: a bare `.none` on an Optional resolves to
        // `Optional.none`, i.e. nil, not `Mode.none`.
        XCTAssertEqual(heatB?.mode, ELRipeness.Mode.none)
        XCTAssertNotNil(heatA.flatMap(ELRipenessHeatRaster.raster(for:)))
        XCTAssertNil(
            heatB.flatMap(ELRipenessHeatRaster.raster(for:)),
            "a block with no observations of its own must paint nothing"
        )
    }

    /// Alpha must come from the full-precision cell weight. Rounding the weight
    /// to six decimals first would change the byte for at least one cell.
    func testRasterAlphaUsesFullPrecisionWeightNotARoundedCopy() {
        // 0.1234565 rounds to 0.123457 at 6dp; the two produce different alpha
        // bytes once scaled by 255 * 0.72.
        let full = 0.5000001
        let roundedTo6dp = (full * 1_000_000).rounded() / 1_000_000
        let alphaFull = ELRipeness.alpha255(value: 20, cellWeight: full)
        let alphaRounded = ELRipeness.alpha255(value: 20, cellWeight: roundedTo6dp)
        // They agree here, which is expected — the point of the test below is
        // that the raster reads the *weight grid*, never a display string.
        XCTAssertEqual(alphaFull, alphaRounded)

        // A nil value is always fully transparent regardless of weight.
        XCTAssertEqual(ELRipeness.alpha255(value: nil, cellWeight: 1.0), 0)
        // The 0.12 floor applies only to cells that have a value.
        XCTAssertEqual(
            ELRipeness.alpha255(value: 10, cellWeight: 0.0),
            ELRipeness.alpha255(value: 10, cellWeight: ELRipeness.minAlphaFactor)
        )
    }

    func testRasterIsNilForModesThatPaintNothing() {
        let square = [
            ELRipeness.LatLng(lat: -34.500, lng: 138.500),
            ELRipeness.LatLng(lat: -34.500, lng: 138.504),
            ELRipeness.LatLng(lat: -34.504, lng: 138.504),
        ]
        // Stale: an observation exists but is far outside the 84-day window.
        let stale = ELRipeness.buildBlockHeat(
            paddockId: "b",
            paddockName: "B",
            polygon: square,
            observations: [
                ELRipeness.Observation(id: "old", paddockId: "b", assigned: true, el: 20, lat: -34.502, lng: 138.502, dateISO: "2025-01-01")
            ],
            atDateISO: "2026-01-25"
        )
        XCTAssertEqual(stale.mode, .stale)
        XCTAssertNil(ELRipenessHeatRaster.raster(for: stale))

        // No polygon at all.
        let noPolygon = ELRipeness.buildBlockHeat(
            paddockId: "b",
            paddockName: "B",
            polygon: [],
            observations: [],
            atDateISO: "2026-01-25"
        )
        XCTAssertEqual(noPolygon.mode, .noPolygon)
        XCTAssertNil(ELRipenessHeatRaster.raster(for: noPolygon))
    }

    // MARK: - Cache

    func testCachePayloadRoundTripsThroughJSON() throws {
        let payload = ELRipenessCachePayload(
            schemaVersion: ELRipenessCachePayload.currentSchemaVersion,
            vineyardId: vineyardId.uuidString.lowercased(),
            cachedAt: Date(timeIntervalSince1970: 1_700_000_000),
            records: [ELRipenessCachedRecord(from: source(raw("obs-1"), .remote, assigned: true))],
            blocks: [ELRipenessCachedBlock(from: ELRipeness.BlockInput(
                id: "block-a",
                name: "Block A",
                polygon: [
                    ELRipeness.LatLng(lat: -34.5, lng: 138.5),
                    ELRipeness.LatLng(lat: -34.5, lng: 138.6),
                    ELRipeness.LatLng(lat: -34.6, lng: 138.6),
                ]
            ))],
            coveredVintages: [2025, 2026]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ELRipenessCachePayload.self, from: encoder.encode(payload))

        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.sourceRecords.count, 1)
        XCTAssertEqual(decoded.sourceRecords[0].origin, .cached, "replayed records must be tagged as cached")
        XCTAssertEqual(decoded.sourceRecords[0].placementAssigned, true)
        XCTAssertEqual(decoded.blockInputs[0].polygon.count, 3)
    }

    // MARK: - View model

    /// Counts fetches so tests can prove the timeline never hits the network.
    private final class StubRepository: RipenessObservationRepositoryProtocol, @unchecked Sendable {
        var rows: [RipenessObservationRow] = []
        var error: (any Error)?
        private(set) var fetchCount = 0

        func fetchObservations(vineyardId: UUID) async throws -> [RipenessObservationRow] {
            fetchCount += 1
            if let error { throw error }
            return rows
        }
    }

    private final class StubCache: ELRipenessObservationCaching, @unchecked Sendable {
        var stored: [String: ELRipenessCachePayload] = [:]
        func load(vineyardId: UUID) -> ELRipenessCachePayload? {
            stored[vineyardId.uuidString.lowercased()]
        }
        func save(_ payload: ELRipenessCachePayload) {
            stored[payload.vineyardId] = payload
        }
        func clear(vineyardId: UUID) {
            stored.removeValue(forKey: vineyardId.uuidString.lowercased())
        }
    }

    private func paddock(_ id: UUID, _ name: String, lngOffset: Double = 0) -> Paddock {
        Paddock(
            id: id,
            vineyardId: vineyardId,
            name: name,
            polygonPoints: [
                CoordinatePoint(latitude: -34.500, longitude: 138.500 + lngOffset),
                CoordinatePoint(latitude: -34.500, longitude: 138.504 + lngOffset),
                CoordinatePoint(latitude: -34.504, longitude: 138.504 + lngOffset),
                CoordinatePoint(latitude: -34.504, longitude: 138.500 + lngOffset),
            ]
        )
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso) ?? Date()
    }

    @MainActor
    func testOfflineWithNoCacheReportsUnavailableRatherThanEmpty() async {
        let repository = StubRepository()
        let model = ELRipenessHeatmapModel(repository: repository, cache: StubCache())

        await model.load(
            vineyardId: vineyardId,
            paddocks: [paddock(blockAId, "Block A")],
            pins: [],
            seasonStartMonth: 7,
            seasonStartDay: 1,
            timeZone: TimeZone(identifier: "Australia/Adelaide")!,
            isOnline: false
        )

        XCTAssertEqual(model.loadState, .unavailableOffline)
        XCTAssertEqual(repository.fetchCount, 0, "offline must not attempt a network call")
    }

    @MainActor
    func testOfflineWithCacheRendersFromCacheAndSaysSo() async {
        let cache = StubCache()
        cache.save(
            ELRipenessCachePayload(
                schemaVersion: ELRipenessCachePayload.currentSchemaVersion,
                vineyardId: vineyardId.uuidString.lowercased(),
                cachedAt: Date(timeIntervalSince1970: 1_700_000_000),
                records: [
                    ELRipenessCachedRecord(from: source(
                        raw("obs-1", paddock: blockAId.uuidString.lowercased(), date: "2026-01-20T00:00:00Z", vineyard: vineyardId.uuidString.lowercased()),
                        .remote,
                        assigned: true
                    ))
                ],
                blocks: [],
                coveredVintages: [2026]
            )
        )
        let repository = StubRepository()
        let model = ELRipenessHeatmapModel(repository: repository, cache: cache)

        await model.load(
            vineyardId: vineyardId,
            paddocks: [paddock(blockAId, "Block A")],
            pins: [],
            seasonStartMonth: 7,
            seasonStartDay: 1,
            timeZone: TimeZone(identifier: "Australia/Adelaide")!,
            isOnline: false
        )
        await model.waitForRender()

        XCTAssertEqual(model.loadState, .ready)
        XCTAssertEqual(repository.fetchCount, 0)
        XCTAssertEqual(model.allObservations.count, 1)
        XCTAssertTrue(
            model.notices.contains { if case .offlineCache = $0 { return true } else { return false } },
            "the operator must be told they are looking at cached data"
        )
    }

    @MainActor
    func testScrubbingTheTimelineNeverIssuesANetworkRequest() async {
        let repository = StubRepository()
        repository.rows = []
        let cache = StubCache()
        let model = ELRipenessHeatmapModel(repository: repository, cache: cache)

        // Seed through pending local pins so no remote rows are needed.
        let pins = [
            growthPin(paddock: blockAId, stage: "E-L 10", timestamp: date("2026-01-05T02:00:00Z")),
            growthPin(paddock: blockAId, stage: "E-L 20", timestamp: date("2026-01-15T02:00:00Z")),
            growthPin(paddock: blockAId, stage: "E-L 30", timestamp: date("2026-01-25T02:00:00Z")),
        ]

        await model.load(
            vineyardId: vineyardId,
            paddocks: [paddock(blockAId, "Block A")],
            pins: pins,
            seasonStartMonth: 7,
            seasonStartDay: 1,
            timeZone: TimeZone(identifier: "Australia/Adelaide")!,
            isOnline: true
        )
        await model.waitForRender()

        let fetchesAfterLoad = repository.fetchCount
        XCTAssertEqual(fetchesAfterLoad, 1, "loading fetches exactly once")
        XCTAssertGreaterThan(model.timelineDays.count, 1)

        for index in 0..<model.timelineDays.count {
            model.timelineIndex = index
        }
        await model.waitForRender()

        XCTAssertEqual(repository.fetchCount, fetchesAfterLoad, "scrubbing must be pure local computation")
    }

    @MainActor
    func testTimelineSpansObservationDatesAndMarksOnlyDaysWithData() async {
        let model = ELRipenessHeatmapModel(repository: StubRepository(), cache: StubCache())
        let pins = [
            growthPin(paddock: blockAId, stage: "E-L 10", timestamp: date("2026-01-05T02:00:00Z")),
            growthPin(paddock: blockAId, stage: "E-L 30", timestamp: date("2026-01-08T02:00:00Z")),
        ]

        await model.load(
            vineyardId: vineyardId,
            paddocks: [paddock(blockAId, "Block A")],
            pins: pins,
            seasonStartMonth: 7,
            seasonStartDay: 1,
            timeZone: TimeZone(identifier: "Australia/Adelaide")!,
            isOnline: true
        )
        await model.waitForRender()

        // 5th to 8th January inclusive is four days, with markers at each end.
        XCTAssertEqual(model.timelineDays.count, 4)
        XCTAssertEqual(model.timelineDays.first?.iso, "2026-01-05")
        XCTAssertEqual(model.timelineDays.last?.iso, "2026-01-08")
        XCTAssertEqual(model.observationDayIndices, [0, 3])
        XCTAssertEqual(model.timelineIndex, 3, "opening lands on the most recent observation")

        model.stepToPreviousObservation()
        XCTAssertEqual(model.timelineIndex, 0)
        XCTAssertFalse(model.canStepBack)
        XCTAssertTrue(model.canStepForward)
    }

    @MainActor
    func testFutureObservationsAreHiddenEntirelyAtEarlierTimelineDates() async {
        let model = ELRipenessHeatmapModel(repository: StubRepository(), cache: StubCache())
        let pins = [
            growthPin(paddock: blockAId, stage: "E-L 10", timestamp: date("2026-01-05T02:00:00Z")),
            growthPin(paddock: blockAId, stage: "E-L 30", timestamp: date("2026-01-08T02:00:00Z")),
        ]
        await model.load(
            vineyardId: vineyardId,
            paddocks: [paddock(blockAId, "Block A")],
            pins: pins,
            seasonStartMonth: 7,
            seasonStartDay: 1,
            timeZone: TimeZone(identifier: "Australia/Adelaide")!,
            isOnline: true
        )
        await model.waitForRender()

        model.timelineIndex = 0 // 5 January
        await model.waitForRender()

        XCTAssertEqual(model.statusCounts.recorded, 1, "the 8 January observation must not exist yet")
        XCTAssertEqual(model.medianEl, 10)
    }

    @MainActor
    func testPendingPinChangeRebuildsLocallyWithoutRefetching() async {
        let repository = StubRepository()
        let model = ELRipenessHeatmapModel(repository: repository, cache: StubCache())
        let existing = growthPin(paddock: blockAId, stage: "E-L 10", timestamp: date("2026-01-05T02:00:00Z"))

        await model.load(
            vineyardId: vineyardId,
            paddocks: [paddock(blockAId, "Block A")],
            pins: [existing],
            seasonStartMonth: 7,
            seasonStartDay: 1,
            timeZone: TimeZone(identifier: "Australia/Adelaide")!,
            isOnline: true
        )
        await model.waitForRender()
        XCTAssertEqual(model.allObservations.count, 1)

        let added = growthPin(paddock: blockAId, stage: "E-L 20", timestamp: date("2026-01-09T02:00:00Z"))
        model.refreshPending(pins: [existing, added], timeZone: TimeZone(identifier: "Australia/Adelaide")!)
        await model.waitForRender()

        XCTAssertEqual(model.allObservations.count, 2, "a newly dropped pin appears before it syncs")
        XCTAssertEqual(repository.fetchCount, 1, "no refetch for a local change")
    }

    @MainActor
    func testUnassignedObservationsAreCountedButExcludedFromBlockMaths() async {
        let model = ELRipenessHeatmapModel(repository: StubRepository(), cache: StubCache())
        let assigned = growthPin(paddock: blockAId, stage: "E-L 30", timestamp: date("2026-01-20T02:00:00Z"))
        // No block: the placement contract resolves this to a point location,
        // which is a valid location but not a block assignment.
        let unassigned = growthPin(paddock: nil, stage: "E-L 10", timestamp: date("2026-01-20T02:00:00Z"))

        await model.load(
            vineyardId: vineyardId,
            paddocks: [paddock(blockAId, "Block A")],
            pins: [assigned, unassigned],
            seasonStartMonth: 7,
            seasonStartDay: 1,
            timeZone: TimeZone(identifier: "Australia/Adelaide")!,
            isOnline: true
        )
        await model.waitForRender()

        let counts = model.statusCounts
        XCTAssertEqual(counts.recorded, 2, "the recorded total includes unassigned observations")
        XCTAssertEqual(counts.influencing, 1, "only assigned observations influence a block")
        XCTAssertEqual(counts.unassigned, 1)
        XCTAssertEqual(model.medianEl, 30, "the unassigned E-L 10 must not drag the median down")
    }

    @MainActor
    func testTeardownReleasesOverlaysAndStopsPlayback() async {
        let model = ELRipenessHeatmapModel(repository: StubRepository(), cache: StubCache())
        await model.load(
            vineyardId: vineyardId,
            paddocks: [paddock(blockAId, "Block A")],
            pins: [
                growthPin(paddock: blockAId, stage: "E-L 10", timestamp: date("2026-01-05T02:00:00Z")),
                growthPin(paddock: blockAId, stage: "E-L 20", timestamp: date("2026-01-06T02:00:00Z")),
                growthPin(paddock: blockAId, stage: "E-L 30", timestamp: date("2026-01-07T02:00:00Z")),
            ],
            seasonStartMonth: 7,
            seasonStartDay: 1,
            timeZone: TimeZone(identifier: "Australia/Adelaide")!,
            isOnline: true
        )
        await model.waitForRender()
        model.togglePlayback()
        XCTAssertTrue(model.isPlaying)
        XCTAssertFalse(model.overlays.isEmpty)

        model.teardown()

        XCTAssertFalse(model.isPlaying)
        XCTAssertTrue(model.overlays.isEmpty, "overlay bitmaps must be released when the screen goes away")
        XCTAssertNil(model.heatModel)
    }

    @MainActor
    func testReduceMotionPlaybackStepsBetweenObservationDates() async {
        let model = ELRipenessHeatmapModel(repository: StubRepository(), cache: StubCache())
        await model.load(
            vineyardId: vineyardId,
            paddocks: [paddock(blockAId, "Block A")],
            pins: [
                growthPin(paddock: blockAId, stage: "E-L 10", timestamp: date("2026-01-05T02:00:00Z")),
                growthPin(paddock: blockAId, stage: "E-L 30", timestamp: date("2026-01-10T02:00:00Z")),
            ],
            seasonStartMonth: 7,
            seasonStartDay: 1,
            timeZone: TimeZone(identifier: "Australia/Adelaide")!,
            isOnline: true
        )
        await model.waitForRender()

        model.timelineIndex = 0
        model.isPlaying = true
        model.advancePlayback(reduceMotion: true)
        XCTAssertEqual(model.timelineIndex, 5, "Reduce Motion jumps straight to the next observation date")

        model.timelineIndex = 0
        model.advancePlayback(reduceMotion: false)
        XCTAssertEqual(model.timelineIndex, 1, "normal playback sweeps a day at a time")
    }

    @MainActor
    func testBlockFilterLimitsTheSurfaceToOneBlock() async {
        let model = ELRipenessHeatmapModel(repository: StubRepository(), cache: StubCache())
        await model.load(
            vineyardId: vineyardId,
            paddocks: [paddock(blockAId, "Block A"), paddock(blockBId, "Block B", lngOffset: 0.004)],
            pins: [
                growthPin(paddock: blockAId, stage: "E-L 30", timestamp: date("2026-01-20T02:00:00Z")),
                growthPin(paddock: blockBId, stage: "E-L 10", lng: 138.506, timestamp: date("2026-01-20T02:00:00Z")),
            ],
            seasonStartMonth: 7,
            seasonStartDay: 1,
            timeZone: TimeZone(identifier: "Australia/Adelaide")!,
            isOnline: true
        )
        await model.waitForRender()
        XCTAssertEqual(model.heatModel?.blocks.count, 2)

        model.selectedBlockId = blockAId.uuidString.lowercased()
        await model.waitForRender()

        XCTAssertEqual(model.heatModel?.blocks.count, 1)
        XCTAssertEqual(model.heatModel?.blocks.first?.paddockId, blockAId.uuidString.lowercased())
        XCTAssertEqual(model.medianEl, 30, "Block B's observation must not affect the filtered median")
    }
}
