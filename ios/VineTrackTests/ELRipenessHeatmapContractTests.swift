import XCTest
@testable import VineTrack

/// Equivalence test against the shipped Portal E-L Ripeness Heatmap, driven by
/// the canonical contract package (contract v1.0.0).
///
/// The same fixture drives `ElRipenessHeatmapContractTest` on Android. Both
/// suites must agree with the Portal and therefore with each other.
///
/// ## Two documented defects in the supplied companion files
///
/// 1. **`cell_weight` in halo / gradient modes** was generated from the
///    *rounded* `max_influence_deg` published in the same file (6 decimal
///    places) rather than from the full-precision radius. Affects `sp-C-near`,
///    `sp-B-centre` and `sp-B-near-shared-edge`, each by ~1e-4. It never
///    changes a rendered alpha, so it is cosmetic — but a correct
///    implementation cannot reproduce those three numbers at full precision.
///    This suite pins the published value through the documented
///    rounded-radius path AND pins the full-precision value.
/// 2. **`excluded_reason` for the two northern records** is reported as
///    `no_observation_date`, but both carry a valid `date`. The real cause is
///    vineyard scoping (contract section 10: "Wrong vineyard — never fetched").
///    Their `vintage` values are correct and are pinned here, because they are
///    what proves the 1 January boundary.
final class ELRipenessHeatmapContractTests: XCTestCase {

    private var fixture: [String: Any] = [:]
    private var expected: [String: Any] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture = try ELRipenessContractFixtures.fixture()
        expected = try ELRipenessContractFixtures.expected()
    }

    // MARK: - JSON helpers

    private func arr(_ dict: [String: Any], _ key: String) -> [[String: Any]] {
        (dict[key] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }
    private func rawArr(_ dict: [String: Any], _ key: String) -> [Any] {
        dict[key] as? [Any] ?? []
    }
    private func obj(_ dict: [String: Any], _ key: String) -> [String: Any] {
        dict[key] as? [String: Any] ?? [:]
    }
    private func str(_ dict: [String: Any], _ key: String) -> String {
        dict[key] as? String ?? ""
    }
    private func strOrNil(_ dict: [String: Any], _ key: String) -> String? {
        guard let v = dict[key], !(v is NSNull) else { return nil }
        return v as? String
    }
    private func dbl(_ dict: [String: Any], _ key: String) -> Double {
        (dict[key] as? NSNumber)?.doubleValue ?? 0
    }
    private func dblOrNil(_ dict: [String: Any], _ key: String) -> Double? {
        guard let v = dict[key], !(v is NSNull) else { return nil }
        return (v as? NSNumber)?.doubleValue
    }
    private func int(_ dict: [String: Any], _ key: String) -> Int {
        (dict[key] as? NSNumber)?.intValue ?? 0
    }
    private func bool(_ dict: [String: Any], _ key: String) -> Bool {
        (dict[key] as? NSNumber)?.boolValue ?? false
    }
    private func ids(_ dict: [String: Any], _ key: String) -> [String] {
        (dict[key] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    // MARK: - Fixture → domain

    private let southVineyardId = "vy-fixture-south"

    /// Canonical assignment signal from a fixture `placement` block, exactly as
    /// contract section 10 derives it: a placement row can only revoke or
    /// confirm; absence of any signal falls back to `paddock_id`.
    private func explicitAssigned(_ placement: [String: Any]?) -> Bool? {
        guard let placement else { return nil }
        let flag: Bool? = {
            guard let v = placement["is_location_assigned"], !(v is NSNull) else { return nil }
            return (v as? NSNumber)?.boolValue
        }()
        let warning = strOrNil(placement, "location_warning_code")
        let hasSignal = flag != nil || !(warning ?? "").isEmpty
        guard hasSignal else { return nil }
        return flag == true && warning != "unassigned_location"
    }

    private func fixtureObservations(vineyardId: String? = nil) -> [[String: Any]] {
        let target = vineyardId ?? southVineyardId
        return arr(fixture, "observations").filter { str($0, "vineyard_id") == target }
    }

    private func rawRecords() -> [ELRipeness.RawRecord] {
        fixtureObservations().map { o in
            ELRipeness.RawRecord(
                id: str(o, "id"),
                paddockId: strOrNil(o, "paddock_id"),
                stageCode: strOrNil(o, "growth_stage_code"),
                latitude: dblOrNil(o, "latitude"),
                longitude: dblOrNil(o, "longitude"),
                date: strOrNil(o, "date"),
                deletedAt: strOrNil(o, "deleted_at")
            )
        }
    }

    private func assignedById() -> [String: Bool] {
        var out: [String: Bool] = [:]
        for o in fixtureObservations() {
            if let explicit = explicitAssigned(o["placement"] as? [String: Any]) {
                out[str(o, "id")] = explicit
            }
        }
        return out
    }

    private func blocks() -> [ELRipeness.BlockInput] {
        arr(fixture, "blocks").map { b in
            ELRipeness.BlockInput(
                id: str(b, "id"),
                name: strOrNil(b, "name"),
                polygon: arr(b, "polygon_points").map {
                    ELRipeness.LatLng(lat: dbl($0, "lat"), lng: dbl($0, "lng"))
                }
            )
        }
    }

    /// Season-filtered observations for the southern fixture vineyard, Vintage 2026.
    private func seasonObservations() -> [ELRipeness.Observation] {
        let all = ELRipeness.toObservations(rawRecords(), assignedById: assignedById())
        return ELRipenessSeason.filter(all, toVintage: 2026, month: 7, day: 1)
    }

    // MARK: - Section 0: constants

    func testConstantsMatchTheContract() {
        let c = obj(expected, "constants")
        XCTAssertEqual(dbl(c, "EL_MIN"), ELRipeness.elMin)
        XCTAssertEqual(dbl(c, "EL_MAX"), ELRipeness.elMax)
        XCTAssertEqual(dbl(c, "IDW_POWER"), ELRipeness.idwPower)
        XCTAssertEqual(dbl(c, "RECENCY_HALF_LIFE_DAYS"), ELRipeness.recencyHalfLifeDays)
        XCTAssertEqual(dbl(c, "RECENCY_MAX_AGE_DAYS"), ELRipeness.recencyMaxAgeDays)
        XCTAssertEqual(dbl(c, "RECENCY_TAPER_DAYS"), ELRipeness.recencyTaperDays)
        XCTAssertEqual(int(c, "GRID_RESOLUTION"), ELRipeness.gridResolution)
        XCTAssertEqual(dbl(c, "MAX_ALPHA"), ELRipeness.maxAlpha)
        XCTAssertEqual(dbl(c, "MIN_ALPHA_FACTOR"), ELRipeness.minAlphaFactor)
        XCTAssertEqual(dbl(c, "HALO_FRACTION"), ELRipeness.haloFraction)
        XCTAssertEqual(dbl(c, "GRADIENT_FRACTION"), ELRipeness.gradientFraction)
        XCTAssertEqual(dbl(c, "ZERO_DISTANCE_EPSILON_D2"), ELRipeness.zeroDistanceEpsilonD2)

        let stops = arr(c, "EL_COLOUR_STOPS")
        XCTAssertEqual(stops.count, ELRipeness.colourStops.count)
        for (i, s) in stops.enumerated() {
            let mine = ELRipeness.colourStops[i]
            XCTAssertEqual(dbl(s, "el"), mine.el)
            XCTAssertEqual(int(obj(s, "rgb"), "r"), mine.rgb.r)
            XCTAssertEqual(int(obj(s, "rgb"), "g"), mine.rgb.g)
            XCTAssertEqual(int(obj(s, "rgb"), "b"), mine.rgb.b)
            XCTAssertEqual(str(s, "hex"), mine.rgb.hex)
        }
    }

    // MARK: - Section 1: E-L parsing

    func testEveryElParsingCaseMatches() {
        for c in arr(expected, "el_parsing") {
            let input: String? = {
                guard let v = c["input"], !(v is NSNull) else { return nil }
                if let s = v as? String { return s }
                if let n = v as? NSNumber { return n.stringValue }
                return nil
            }()
            let want = dblOrNil(c, "parsed")
            let got = ELRipeness.parseElStage(input)
            if let want {
                XCTAssertNotNil(got, "parseElStage(\(input ?? "nil")) must parse")
                XCTAssertEqual(got ?? .nan, want, accuracy: 1e-12, "parseElStage(\(input ?? "nil"))")
            } else {
                XCTAssertNil(got, "parseElStage(\(input ?? "nil")) must be excluded")
            }
        }
    }

    func testElFortySevenIsExcludedAndNeverClampedToFortyThree() {
        XCTAssertNil(ELRipeness.parseElStage("E-L 47"))
        XCTAssertNil(ELRipeness.parseElStage("47"))
        XCTAssertNil(ELRipeness.parseElStage("44"))
        XCTAssertNil(ELRipeness.parseElStage("43.0000001"))
        XCTAssertEqual(ELRipeness.parseElStage("43"), 43)
    }

    // MARK: - Section 2: colour

    func testColourScaleMatchesAtEveryPublishedStop() {
        for c in arr(expected, "colour_scale") {
            let el = dbl(c, "el")
            let rgb = ELRipeness.elColour(el)
            XCTAssertEqual(int(obj(c, "rgb"), "r"), rgb.r, "R at E-L \(el)")
            XCTAssertEqual(int(obj(c, "rgb"), "g"), rgb.g, "G at E-L \(el)")
            XCTAssertEqual(int(obj(c, "rgb"), "b"), rgb.b, "B at E-L \(el)")
            XCTAssertEqual(str(c, "hex"), rgb.hex, "hex at E-L \(el)")
        }
    }

    // MARK: - Section 3: recency and dates

    func testRecencyWeightsMatchToTenDecimalPlaces() {
        for c in arr(expected, "recency") {
            let age = dbl(c, "ageDays")
            XCTAssertEqual(
                ELRipeness.recencyWeight(ageDays: age), dbl(c, "weight"),
                accuracy: 1e-10, "recencyWeight(\(age))"
            )
        }
    }

    func testTaperEngagesOnlyAfterDaySeventyAndZeroLandsOnDayEightyFour() {
        XCTAssertGreaterThan(ELRipeness.recencyWeight(ageDays: 70), ELRipeness.recencyWeight(ageDays: 71))
        XCTAssertEqual(ELRipeness.recencyWeight(ageDays: 84), 0)
        XCTAssertEqual(ELRipeness.recencyWeight(ageDays: 85), 0)
        XCTAssertGreaterThan(ELRipeness.recencyWeight(ageDays: 83), 0)
    }

    func testDayArithmeticIsWholeDayAndIgnoresTimeAndTimezone() {
        XCTAssertEqual(ELRipeness.daysBetween("2026-01-10T23:59:59Z", "2026-01-10T00:00:00Z"), 0)
        XCTAssertEqual(ELRipeness.daysBetween("2026-01-10T23:00:00Z", "2026-01-11T01:00:00Z"), 1)
        XCTAssertEqual(ELRipeness.daysBetween("2025-11-02T00:00:00Z", "2026-01-25T00:00:00Z"), 84)
        XCTAssertEqual(ELRipeness.daysBetween("not-a-date", "2026-01-25"), 0)
    }

    // MARK: - Section 4: vintage

    func testVintageAssignmentMatchesEveryPublishedConfiguration() {
        for c in arr(expected, "vintage_assignment") {
            let m = int(c, "season_start_month")
            let d = int(c, "season_start_day")
            let date = str(c, "date")
            XCTAssertEqual(
                ELRipenessSeason.vintage(forDayKey: date, month: m, day: d), int(c, "vintage"),
                "\(str(c, "config")) @ \(date)"
            )
        }
    }

    func testSeasonRangesMatchIncludingTheFirstOfJanuaryBoundary() {
        for c in arr(expected, "season_ranges") {
            let range = ELRipenessSeason.seasonRange(
                month: int(c, "m"), day: int(c, "d"), vintage: int(c, "vintage")
            )
            XCTAssertEqual(range.startISO, str(c, "startISO"))
            XCTAssertEqual(range.endISO, str(c, "endISO"))
        }
    }

    func testMissingSeasonSettingsFallBackToFirstOfJuly() {
        let s = ELRipenessSeason.normaliseSeasonSettings(month: nil, day: nil)
        XCTAssertEqual(s.month, 7)
        XCTAssertEqual(s.day, 1)
        XCTAssertEqual(ELRipenessSeason.normaliseSeasonSettings(month: 13, day: 5).month, 7)
        XCTAssertEqual(ELRipenessSeason.normaliseSeasonSettings(month: 7, day: 0).day, 1)
        XCTAssertEqual(ELRipenessSeason.normaliseSeasonSettings(month: 2, day: 31).day, 29)
        XCTAssertEqual(ELRipenessSeason.normaliseSeasonSettings(month: 4, day: 31).day, 30)
    }

    func testNorthernRecordsPinTheFirstOfJanuaryVintageBoundary() {
        // Season start 1/1: 31 Dec 2025 closes Vintage 2026; 1 Jan 2026 opens
        // Vintage 2027. The boundary is inclusive of the start day.
        XCTAssertEqual(ELRipenessSeason.vintage(forDayKey: "2025-12-31T00:00:00Z", month: 1, day: 1), 2026)
        XCTAssertEqual(ELRipenessSeason.vintage(forDayKey: "2026-01-01T00:00:00Z", month: 1, day: 1), 2027)
    }

    // MARK: - Section 10: normalisation and assignment

    func testObservationNormalisationMatchesRecordByRecord() {
        let southRaw = rawRecords()
        var included: [String: ELRipeness.Observation] = [:]
        for o in ELRipeness.toObservations(southRaw, assignedById: assignedById()) { included[o.id] = o }
        let northIds = Set(
            arr(fixture, "observations")
                .filter { str($0, "vineyard_id") != southVineyardId }
                .map { str($0, "id") }
        )

        for c in arr(expected, "observation_normalisation") {
            let id = str(c, "id")
            let shouldInclude = bool(c, "included_in_observations")

            if northIds.contains(id) {
                // Contract section 10: another vineyard's records are never
                // fetched. The file labels this `no_observation_date`, which is
                // wrong (both records carry a `date`) — the scoping outcome is
                // what matters and is asserted here.
                XCTAssertFalse(shouldInclude, "\(id) belongs to another vineyard")
                continue
            }

            let obs = included[id]
            XCTAssertEqual(obs != nil, shouldInclude, "\(id) inclusion")

            guard shouldInclude, let obs else {
                guard let record = southRaw.first(where: { $0.id == id }) else {
                    XCTFail("missing fixture record \(id)")
                    continue
                }
                let reason = ELRipeness.exclusionReason(record)
                XCTAssertNotNil(reason, "\(id) must have an exclusion reason")
                XCTAssertEqual(reason?.rawValue, str(c, "excluded_reason"), "\(id) exclusion reason")
                continue
            }

            XCTAssertEqual(obs.el, dbl(c, "parsed_el"), accuracy: 1e-12, "\(id) parsed E-L")
            XCTAssertEqual(obs.assigned, bool(c, "assigned"), "\(id) assigned")
            XCTAssertEqual(obs.paddockId, strOrNil(c, "resolved_paddock_id"), "\(id) resolved block")
            XCTAssertEqual(
                ELRipenessSeason.vintage(forDayKey: obs.dateISO, month: 7, day: 1),
                int(c, "vintage"), "\(id) vintage"
            )
        }
    }

    func testRevokedPlacementLeavesAVisibleButUnassignedObservation() throws {
        let obs = try XCTUnwrap(
            ELRipeness.toObservations(rawRecords(), assignedById: assignedById())
                .first { $0.id == "obs-u1-unassigned" }
        )
        XCTAssertEqual(obs.el, 25, "still a normalised, visible pin")
        XCTAssertFalse(obs.assigned, "placement revoked the assignment")
        XCTAssertNil(obs.paddockId, "and with it the block identity")
    }

    func testPlacementCanOnlyRevokeOrConfirmNeverRelocate() {
        // No signal at all -> fall back to paddock_id.
        var r = ELRipeness.resolveAssignment(explicitAssigned: nil, paddockId: "BLOCK_A")
        XCTAssertTrue(r.assigned); XCTAssertEqual(r.paddockId, "BLOCK_A")
        r = ELRipeness.resolveAssignment(explicitAssigned: nil, paddockId: nil)
        XCTAssertFalse(r.assigned); XCTAssertNil(r.paddockId)
        // Confirmed -> keeps the record's own block.
        r = ELRipeness.resolveAssignment(explicitAssigned: true, paddockId: "BLOCK_A")
        XCTAssertTrue(r.assigned); XCTAssertEqual(r.paddockId, "BLOCK_A")
        // Revoked -> drops the block entirely.
        r = ELRipeness.resolveAssignment(explicitAssigned: false, paddockId: "BLOCK_A")
        XCTAssertFalse(r.assigned); XCTAssertNil(r.paddockId)
        // Confirmed but no block -> still unassigned.
        r = ELRipeness.resolveAssignment(explicitAssigned: true, paddockId: nil)
        XCTAssertFalse(r.assigned); XCTAssertNil(r.paddockId)
    }

    // MARK: - Sections 7 and 9: modes and medians

    func testBlockModeSelectionMatchesTheTruthTable() {
        for c in arr(expected, "block_mode_selection") {
            let mode = ELRipeness.blockHeatMode(
                influencing: int(c, "influencing"),
                hasPolygon: bool(c, "has_polygon"),
                totalObservations: int(c, "total")
            )
            XCTAssertEqual(mode.rawValue, str(c, "mode"),
                           "influencing=\(int(c, "influencing")) polygon=\(bool(c, "has_polygon"))")
        }
    }

    func testMediansMatchOddEvenAndEmpty() {
        for c in arr(expected, "median_cases") {
            let values = (c["values"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
            let got = ELRipeness.medianStage(values)
            if let want = dblOrNil(c, "median") {
                XCTAssertEqual(got ?? .nan, want, accuracy: 1e-12, "median of \(values)")
            } else {
                XCTAssertNil(got)
            }
        }
    }

    func testElDisplayFormattingMatches() {
        XCTAssertEqual(ELRipeness.formatEl(25), "E-L 25")
        XCTAssertEqual(ELRipeness.formatEl(12.5), "E-L 12.5")
        XCTAssertEqual(ELRipeness.formatEl(23.5), "E-L 23.5")
        XCTAssertEqual(ELRipeness.formatEl(nil), "—")
    }

    // MARK: - Per-date model

    func testStatusCountsMatchAtEveryTimelineDate() {
        let obs = seasonObservations()
        for pd in arr(expected, "per_date") {
            let date = str(pd, "date")
            let model = ELRipeness.buildHeatModel(observations: obs, blocks: blocks(), atDateISO: date)

            XCTAssertEqual(model.qualifying.count, int(pd, "recorded_observations_available"), "\(date) recorded")
            XCTAssertEqual(model.influencing.count, int(pd, "influencing_observations"), "\(date) influencing")
            XCTAssertEqual(model.stale.count, int(pd, "stale_observations"), "\(date) stale")
            XCTAssertEqual(model.unassigned.map(\.id), ids(pd, "unassigned_ids"), "\(date) unassigned")

            if let median = dblOrNil(pd, "typical_recorded_stage") {
                XCTAssertEqual(model.medianEl ?? .nan, median, accuracy: 1e-6, "\(date) median")
            } else {
                XCTAssertNil(model.medianEl)
            }
            XCTAssertEqual(ELRipeness.formatEl(model.medianEl), str(pd, "typical_recorded_stage_display"))
        }
    }

    func testRecordedTotalCountsAnUnassignedPinThatIsInNeitherPartition() {
        // 2026-01-25: 14 recorded = 11 influencing + 2 stale + 1 unassigned.
        // Both partitions are computed over ASSIGNED observations only, so a
        // revoked pin is counted once in the total and never again. The totals
        // are not meant to balance.
        let model = ELRipeness.buildHeatModel(
            observations: seasonObservations(), blocks: blocks(), atDateISO: "2026-01-25"
        )
        XCTAssertEqual(model.qualifying.count, 14)
        XCTAssertEqual(model.influencing.count, 11)
        XCTAssertEqual(model.stale.count, 2)
        XCTAssertEqual(model.unassigned.map(\.id), ["obs-u1-unassigned"])
        XCTAssertEqual(
            model.influencing.count + model.stale.count + model.unassigned.count, 14,
            "the residual record is the revoked placement, not a miscount"
        )
    }

    func testPerBlockModeIdsMedianGeometryAndRecencyWeightsMatch() {
        let obs = seasonObservations()
        for pd in arr(expected, "per_date") {
            let date = str(pd, "date")
            let model = ELRipeness.buildHeatModel(observations: obs, blocks: blocks(), atDateISO: date)
            var byId: [String: ELRipeness.BlockHeat] = [:]
            for b in model.blocks { byId[b.paddockId] = b }

            for eb in arr(pd, "blocks") {
                let id = str(eb, "paddock_id")
                guard let block = byId[id] else { XCTFail("missing block \(id)"); continue }
                let tag = "\(date)/\(id)"

                XCTAssertEqual(block.mode.rawValue, str(eb, "mode"), "\(tag) mode")
                XCTAssertEqual(block.observations.map(\.id), ids(eb, "observation_ids"), "\(tag) observations")
                XCTAssertEqual(block.influencing.map(\.id), ids(eb, "influencing_ids"), "\(tag) influencing")
                XCTAssertEqual(block.stale.map(\.id), ids(eb, "stale_ids"), "\(tag) stale")

                if let median = dblOrNil(eb, "median_el") {
                    XCTAssertEqual(block.medianEl ?? .nan, median, accuracy: 1e-6, "\(tag) median")
                } else {
                    XCTAssertNil(block.medianEl, "\(tag) median")
                }
                XCTAssertEqual(ELRipeness.formatEl(block.medianEl), str(eb, "median_display"), "\(tag) median display")

                if let diag = dblOrNil(eb, "polygon_diagonal_deg") {
                    XCTAssertEqual(block.diagonal ?? .nan, diag, accuracy: 5e-7, "\(tag) diagonal")
                } else {
                    XCTAssertNil(block.diagonal, "\(tag) diagonal")
                }

                if let maxInf = dblOrNil(eb, "max_influence_deg") {
                    XCTAssertEqual(block.maxInfluenceDeg ?? .nan, maxInf, accuracy: 5e-7, "\(tag) maxInfluence")
                } else {
                    XCTAssertNil(block.maxInfluenceDeg, "\(tag) maxInfluence")
                }

                XCTAssertEqual(block.grid != nil, bool(eb, "grid_present"), "\(tag) grid present")
                if bool(eb, "grid_present") {
                    let res = (eb["grid_resolution"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
                    XCTAssertEqual(block.grid?.count, res.first, "\(tag) grid rows")
                    XCTAssertEqual(block.grid?.first?.count, res.last, "\(tag) grid cols")
                    let gb = obj(eb, "grid_bounds")
                    XCTAssertEqual(block.gridBounds?.minLat ?? .nan, dbl(gb, "minLat"), accuracy: 1e-9, "\(tag) minLat")
                    XCTAssertEqual(block.gridBounds?.maxLat ?? .nan, dbl(gb, "maxLat"), accuracy: 1e-9, "\(tag) maxLat")
                    XCTAssertEqual(block.gridBounds?.minLng ?? .nan, dbl(gb, "minLng"), accuracy: 1e-9, "\(tag) minLng")
                    XCTAssertEqual(block.gridBounds?.maxLng ?? .nan, dbl(gb, "maxLng"), accuracy: 1e-9, "\(tag) maxLng")
                } else {
                    XCTAssertNil(block.weightGrid, "\(tag) weight grid")
                    XCTAssertNil(block.gridBounds, "\(tag) grid bounds")
                }

                let weights = arr(eb, "recency_weights")
                XCTAssertEqual(block.points.count, weights.count, "\(tag) weight count")
                for (i, w) in weights.enumerated() where i < block.points.count {
                    let o = block.influencing[i]
                    XCTAssertEqual(o.id, str(w, "id"), "\(tag) weight id")
                    XCTAssertEqual(ELRipeness.daysBetween(o.dateISO, date), int(w, "age_days"), "\(tag) age")
                    XCTAssertEqual(block.points[i].w, dbl(w, "weight"), accuracy: 1e-10, "\(tag) weight")
                }
            }
        }
    }

    func testSamplePointsMatchForInsidePolygonIdwColourAndAlpha() {
        let obs = seasonObservations()
        for pd in arr(expected, "per_date") {
            let date = str(pd, "date")
            let model = ELRipeness.buildHeatModel(observations: obs, blocks: blocks(), atDateISO: date)
            var byId: [String: ELRipeness.BlockHeat] = [:]
            for b in model.blocks { byId[b.paddockId] = b }

            for sp in arr(pd, "sample_points") {
                guard let block = byId[str(sp, "block")] else { XCTFail("missing block"); continue }
                let tag = "\(date)/\(str(sp, "id"))"
                let lat = dbl(sp, "lat")
                let lng = dbl(sp, "lng")

                let inside = ELRipeness.pointInPolygon(
                    ELRipeness.LatLng(lat: lat, lng: lng), block.polygon
                )
                XCTAssertEqual(inside, bool(sp, "inside_polygon"), "\(tag) inside polygon")

                let radius = block.maxInfluenceDeg ?? .infinity
                let sample = inside
                    ? ELRipeness.evaluateCell(lat: lat, lng: lng, points: block.points, maxInfluence: radius)
                    : ELRipeness.CellSample.empty

                if let wantEl = dblOrNil(sp, "idw_el") {
                    XCTAssertEqual(sample.value ?? .nan, wantEl, accuracy: 1e-6, "\(tag) idw")
                } else {
                    XCTAssertNil(sample.value, "\(tag) idw")
                }

                if let wantRgb = sp["rgb"] as? [String: Any], let value = sample.value {
                    let rgb = ELRipeness.elColour(value)
                    XCTAssertEqual(int(wantRgb, "r"), rgb.r, "\(tag) R")
                    XCTAssertEqual(int(wantRgb, "g"), rgb.g, "\(tag) G")
                    XCTAssertEqual(int(wantRgb, "b"), rgb.b, "\(tag) B")
                    XCTAssertEqual(str(sp, "hex"), rgb.hex, "\(tag) hex")
                } else {
                    XCTAssertNil(sample.value, "\(tag) rgb")
                }

                XCTAssertEqual(
                    ELRipeness.alpha255(value: sample.value, cellWeight: sample.weight),
                    int(sp, "alpha_0_255"), "\(tag) alpha"
                )

                assertSampleWeight(tag: tag, sp: sp, block: block, sample: sample, lat: lat, lng: lng)
            }
        }
    }

    /// Pins `cell_weight` against the published file while accounting for
    /// defect 1 (see the type comment): in halo / gradient modes the file's
    /// value was generated from the rounded `max_influence_deg`. Both the
    /// published number and the full-precision number are asserted, so a real
    /// regression in either still fails.
    private func assertSampleWeight(
        tag: String,
        sp: [String: Any],
        block: ELRipeness.BlockHeat,
        sample: ELRipeness.CellSample,
        lat: Double,
        lng: Double
    ) {
        guard let want = dblOrNil(sp, "cell_weight") else {
            XCTAssertNil(sample.weight, "\(tag) weight")
            return
        }
        guard let actual = sample.weight else {
            XCTFail("\(tag) expected a cell weight")
            return
        }
        if abs(want - actual) <= 1e-6 { return }

        // Only a falloff-bearing cell may differ, and only via the rounding artifact.
        guard let radius = block.maxInfluenceDeg else {
            XCTFail("\(tag) weight differs but the block has no finite radius")
            return
        }
        let rounded = ELRipeness.jsRound(radius * 1e6) / 1e6
        let viaRounded = ELRipeness.evaluateCell(
            lat: lat, lng: lng, points: block.points, maxInfluence: rounded
        ).weight
        XCTAssertNotNil(viaRounded, "\(tag) rounded-radius weight")
        XCTAssertEqual(viaRounded ?? .nan, want, accuracy: 1e-6,
                       "\(tag) weight via published rounded radius")
        XCTAssertLessThan(abs(want - actual), 2e-4, "\(tag) artifact must stay cosmetic")
    }

    // MARK: - Block isolation

    func testAdjacentBlocksNeverShareObservationsAcrossTheSharedEdge() {
        let iso = obj(expected, "block_isolation")
        let model = ELRipeness.buildHeatModel(
            observations: seasonObservations(), blocks: blocks(), atDateISO: str(iso, "date")
        )
        let a = model.blocks.first { $0.paddockId == "BLOCK_A" }?.influencing.map(\.id) ?? []
        let b = model.blocks.first { $0.paddockId == "BLOCK_B" }?.influencing.map(\.id) ?? []

        XCTAssertEqual(a, ids(iso, "block_a_influencing_ids"))
        XCTAssertEqual(b, ids(iso, "block_b_influencing_ids"))
        XCTAssertTrue(Set(a).intersection(Set(b)).isEmpty, "influencing sets must be disjoint")
    }

    func testABlockOnlyEverInterpolatesFromItsOwnObservations() throws {
        let model = ELRipeness.buildHeatModel(
            observations: seasonObservations(), blocks: blocks(), atDateISO: "2026-01-25"
        )
        let blockA = try XCTUnwrap(model.blocks.first { $0.paddockId == "BLOCK_A" })
        // 0.00001 deg west of the shared edge: still Block A's own surface.
        let sample = ELRipeness.evaluateCell(
            lat: -34.5020, lng: 138.50399, points: blockA.points,
            maxInfluence: blockA.maxInfluenceDeg ?? .infinity
        )
        XCTAssertEqual(sample.value ?? .nan, 33.092982, accuracy: 1e-6)
        XCTAssertFalse(
            blockA.influencing.contains { $0.id.hasPrefix("obs-b") },
            "Block B's E-L 35 pin must not bleed across"
        )
    }

    // MARK: - Zero distance, halo, staleness

    func testZeroDistanceHitTakesTheExactValueAndStopsTheLoop() throws {
        let model = ELRipeness.buildHeatModel(
            observations: seasonObservations(), blocks: blocks(), atDateISO: "2026-01-25"
        )
        let blockA = try XCTUnwrap(model.blocks.first { $0.paddockId == "BLOCK_A" })
        let sample = ELRipeness.evaluateCell(
            lat: -34.5020, lng: 138.5020, points: blockA.points, maxInfluence: .infinity
        )
        XCTAssertEqual(sample.value, 23, "obs-a2's exact E-L, unblended")
        XCTAssertEqual(sample.weight ?? .nan, ELRipeness.recencyWeight(ageDays: 5),
                       accuracy: 1e-12, "and obs-a2's own recency weight")
    }

    func testHaloClipsHardAtItsRim() throws {
        let model = ELRipeness.buildHeatModel(
            observations: seasonObservations(), blocks: blocks(), atDateISO: "2026-01-25"
        )
        let blockC = try XCTUnwrap(model.blocks.first { $0.paddockId == "BLOCK_C" })
        XCTAssertEqual(blockC.mode, .halo)
        // Inside the polygon but beyond 0.22 x diagonal -> nothing is painted.
        let far = ELRipeness.evaluateCell(
            lat: -34.5062, lng: 138.5038, points: blockC.points,
            maxInfluence: try XCTUnwrap(blockC.maxInfluenceDeg)
        )
        XCTAssertNil(far.value, "beyond the rim")
        XCTAssertEqual(ELRipeness.alpha255(value: far.value, cellWeight: far.weight), 0)
    }

    func testStaleOnlyBlocksPaintNothingAndReportNoMedian() {
        let model = ELRipeness.buildHeatModel(
            observations: seasonObservations(), blocks: blocks(), atDateISO: "2026-04-30"
        )
        for id in ["BLOCK_B", "BLOCK_C", "BLOCK_F"] {
            guard let block = model.blocks.first(where: { $0.paddockId == id }) else {
                XCTFail("missing \(id)"); continue
            }
            XCTAssertEqual(block.mode, .stale, "\(id) mode")
            XCTAssertNil(block.grid, "\(id) grid")
            XCTAssertNil(block.medianEl, "\(id) median")
            XCTAssertEqual(ELRipeness.formatEl(block.medianEl), "—")
        }
    }

    func testPolygonLessBlockKeepsItsObservationsButNeverPaints() throws {
        let model = ELRipeness.buildHeatModel(
            observations: seasonObservations(), blocks: blocks(), atDateISO: "2026-01-25"
        )
        let blockE = try XCTUnwrap(model.blocks.first { $0.paddockId == "BLOCK_E" })
        XCTAssertEqual(blockE.mode, .noPolygon)
        XCTAssertEqual(blockE.observations.map(\.id), ["obs-e1"])
        XCTAssertNil(blockE.grid)
        XCTAssertNil(blockE.gridBounds)
        // It still counts toward the map-level influencing total.
        XCTAssertTrue(model.influencing.contains { $0.id == "obs-e1" })
    }

    func testFutureObservationIsHiddenEntirelyAndReturnsLater() throws {
        let obs = seasonObservations()
        let atJan = ELRipeness.buildHeatModel(observations: obs, blocks: blocks(), atDateISO: "2026-01-25")
        XCTAssertFalse(atJan.qualifying.contains { $0.id == "obs-a6-future" }, "hidden at 25 Jan")

        let atApr = ELRipeness.buildHeatModel(observations: obs, blocks: blocks(), atDateISO: "2026-04-30")
        let blockA = try XCTUnwrap(atApr.blocks.first { $0.paddockId == "BLOCK_A" })
        XCTAssertEqual(blockA.influencing.map(\.id), ["obs-a6-future"], "it alone drives the surface later")
        XCTAssertEqual(blockA.mode, .halo)
    }

    func testExactlyEightyFourDayOldObservationContributesNothing() throws {
        let model = ELRipeness.buildHeatModel(
            observations: seasonObservations(), blocks: blocks(), atDateISO: "2026-01-25"
        )
        let blockA = try XCTUnwrap(model.blocks.first { $0.paddockId == "BLOCK_A" })
        XCTAssertTrue(blockA.observations.contains { $0.id == "obs-a5-day84" }, "still a visible historical pin")
        XCTAssertTrue(blockA.stale.contains { $0.id == "obs-a5-day84" }, "but stale")
        XCTAssertFalse(blockA.influencing.contains { $0.id == "obs-a5-day84" }, "and never influencing")
    }

    func testHistoricalPlaybackMakesAStaleObservationInfluencingAgain() throws {
        let obs = seasonObservations()
        let later = ELRipeness.buildHeatModel(observations: obs, blocks: blocks(), atDateISO: "2026-01-25")
        XCTAssertTrue(
            try XCTUnwrap(later.blocks.first { $0.paddockId == "BLOCK_A" })
                .stale.contains { $0.id == "obs-a5-day84" }
        )

        let earlier = ELRipeness.buildHeatModel(observations: obs, blocks: blocks(), atDateISO: "2026-01-08")
        XCTAssertTrue(
            try XCTUnwrap(earlier.blocks.first { $0.paddockId == "BLOCK_A" })
                .influencing.contains { $0.id == "obs-a5-day84" },
            "moving the timeline back restores its influence"
        )
    }

    func testCivilDatesRoundTripWithoutTimezoneDrift() throws {
        let d = try XCTUnwrap(CivilDate(dayKey: "2026-01-01"))
        XCTAssertEqual(d.adding(days: -1).iso, "2025-12-31")
        XCTAssertEqual(try XCTUnwrap(CivilDate(dayKey: "2027-01-01")).adding(days: -1).iso, "2026-12-31")
        XCTAssertEqual(try XCTUnwrap(CivilDate(dayKey: "2024-03-01")).adding(days: -1).iso, "2024-02-29")
        XCTAssertNil(CivilDate(dayKey: "nonsense"))
    }
}
