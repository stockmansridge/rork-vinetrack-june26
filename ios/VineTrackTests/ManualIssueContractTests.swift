import Testing
import Foundation
@testable import VineTrack

/// Manual Issue contract tests — mirrored by Android's
/// `ManualIssueContractTest.kt`. The parity fixture values asserted here MUST
/// stay byte-identical to the Kotlin suite so both platforms produce the same
/// validation, marker derivation and customer-facing wording.
struct ManualIssueContractTests {

    // MARK: - Fixture (shared with Android)

    /// Straight north-south rows 1–6, 100 m long, 4 m apart, anchored at
    /// (-34.0, 138.0). Row r runs from (‑34.0, 138.0 + (r−1)·0.00004) to
    /// (‑33.999, same longitude). 0.001° lat ≈ 111 m.
    private func rowLines() -> [Int: (start: (latitude: Double, longitude: Double), end: (latitude: Double, longitude: Double))] {
        var lines: [Int: (start: (latitude: Double, longitude: Double), end: (latitude: Double, longitude: Double))] = [:]
        for row in 1...6 {
            let lon = 138.0 + Double(row - 1) * 0.00004
            lines[row] = (start: (latitude: -34.0, longitude: lon), end: (latitude: -33.999, longitude: lon))
        }
        return lines
    }

    private let blockPolygon: [(latitude: Double, longitude: Double)] = [
        (-34.0, 138.0), (-34.0, 138.0002), (-33.999, 138.0002), (-33.999, 138.0)
    ]

    // MARK: - Defaults

    @Test func defaultsMatchContract() {
        #expect(ManualIssueContract.defaultCategory == .general)
        #expect(ManualIssueContract.defaultPriority == .normal)
        #expect(ManualIssueContract.defaultStatus == .open)
    }

    @Test func categoryValuesAreStable() {
        #expect(ManualIssueCategory.allCases.map(\.rawValue) == [
            "general", "action_required", "inspection", "planning",
            "infrastructure", "vine_or_row", "safety", "other"
        ])
    }

    @Test func priorityValuesAreStable() {
        #expect(ManualIssuePriority.allCases.map(\.rawValue) == ["low", "normal", "high", "urgent"])
    }

    @Test func statusValuesAreStable() {
        #expect(ManualIssueStatus.allCases.map(\.rawValue) == ["open", "in_progress", "completed", "cancelled"])
        #expect(ManualIssueStatus.open.isActive)
        #expect(ManualIssueStatus.inProgress.isActive)
        #expect(!ManualIssueStatus.completed.isActive)
        #expect(!ManualIssueStatus.cancelled.isActive)
    }

    @Test func scopeValuesAreStable() {
        #expect(ManualIssueLocationScope.allCases.map(\.rawValue) == ["point", "row", "block"])
    }

    // MARK: - Validation

    @Test func titleIsRequired() {
        let error = ManualIssueContract.validationError(
            title: "   ", scope: .point, latitude: -34.0, longitude: 138.0,
            paddockId: UUID(), segments: []
        )
        #expect(error != nil)
    }

    @Test func pointRequiresCoordinates() {
        let error = ManualIssueContract.validationError(
            title: "Leak", scope: .point, latitude: nil, longitude: nil,
            paddockId: nil, segments: []
        )
        #expect(error != nil)
    }

    @Test func validPointPasses() {
        let error = ManualIssueContract.validationError(
            title: "Leak", scope: .point, latitude: -34.0, longitude: 138.0,
            paddockId: nil, segments: []
        )
        #expect(error == nil)
    }

    @Test func rowRequiresSegmentsAndBlock() {
        let noSegments = ManualIssueContract.validationError(
            title: "Netting", scope: .row, latitude: -34.0, longitude: 138.0,
            paddockId: UUID(), segments: []
        )
        #expect(noSegments != nil)
        let noBlock = ManualIssueContract.validationError(
            title: "Netting", scope: .row, latitude: -34.0, longitude: 138.0,
            paddockId: nil, segments: [ManualIssueSegment(row: 2, segment: 1)]
        )
        #expect(noBlock != nil)
        let valid = ManualIssueContract.validationError(
            title: "Netting", scope: .row, latitude: -34.0, longitude: 138.0,
            paddockId: UUID(), segments: [ManualIssueSegment(row: 2, segment: 1)]
        )
        #expect(valid == nil)
    }

    @Test func blockRequiresBlock() {
        let error = ManualIssueContract.validationError(
            title: "Out of production", scope: .block, latitude: -34.0, longitude: 138.0,
            paddockId: nil, segments: []
        )
        #expect(error != nil)
    }

    // MARK: - Segments

    @Test func canonicalSegmentsDedupeAndSort() {
        let raw = [
            ManualIssueSegment(row: 3, segment: 2),
            ManualIssueSegment(row: 2, segment: 4),
            ManualIssueSegment(row: 3, segment: 2),
            ManualIssueSegment(row: 2, segment: 1)
        ]
        let canonical = ManualIssueContract.canonicalSegments(raw)
        #expect(canonical == [
            ManualIssueSegment(row: 2, segment: 1),
            ManualIssueSegment(row: 2, segment: 4),
            ManualIssueSegment(row: 3, segment: 2)
        ])
    }

    // MARK: - Marker derivation (parity fixture)

    @Test func segmentMidpointUsesQuarterFractions() {
        let mid = ManualIssueContract.segmentMidpoint(
            rowStart: (latitude: -34.0, longitude: 138.0),
            rowEnd: (latitude: -33.999, longitude: 138.0),
            quarter: 1
        )
        // Quarter 1 midpoint = 1/8 along the row.
        #expect(abs(mid.latitude - (-34.0 + 0.001 * 0.125)) < 1e-12)
        #expect(abs(mid.longitude - 138.0) < 1e-12)
    }

    /// Parity fixture: whole row 2 (all 4 quarters) → marker at the row 2
    /// midline centre: lat -33.9995, lon 138.00004.
    @Test func wholeRowMarkerIsRowMidpoint() {
        let segments = (1...4).map { ManualIssueSegment(row: 2, segment: $0) }
        let marker = ManualIssueContract.markerCoordinate(segments: segments, rowLines: rowLines())
        #expect(marker != nil)
        #expect(abs((marker?.latitude ?? 0) - (-33.9995)) < 1e-9)
        #expect(abs((marker?.longitude ?? 0) - 138.00004) < 1e-9)
    }

    /// Parity fixture: rows 2–3 whole + row 5 quarters 1–2 → mean of the ten
    /// quarter midpoints. Expected lat = -33.99957500000000 (10 quarters:
    /// 8 whole-row quarters mean -33.9995, 2 partial mean -33.99990625 →
    /// combined -33.99958125? — computed exactly below), lon mean likewise.
    @Test func multiRowMarkerIsMeanOfQuarterMidpoints() {
        var segments = (1...4).map { ManualIssueSegment(row: 2, segment: $0) }
        segments += (1...4).map { ManualIssueSegment(row: 3, segment: $0) }
        segments += [ManualIssueSegment(row: 5, segment: 1), ManualIssueSegment(row: 5, segment: 2)]
        let lines = rowLines()
        let marker = ManualIssueContract.markerCoordinate(segments: segments, rowLines: lines)
        // Independent computation.
        var latSum = 0.0
        var lonSum = 0.0
        for segment in ManualIssueContract.canonicalSegments(segments) {
            let line = lines[segment.row]!
            let mid = ManualIssueContract.segmentMidpoint(rowStart: line.start, rowEnd: line.end, quarter: segment.segment)
            latSum += mid.latitude
            lonSum += mid.longitude
        }
        #expect(marker != nil)
        #expect(abs((marker?.latitude ?? 0) - latSum / 10.0) < 1e-12)
        #expect(abs((marker?.longitude ?? 0) - lonSum / 10.0) < 1e-12)
    }

    @Test func markerIsNilWithoutGeometry() {
        let marker = ManualIssueContract.markerCoordinate(
            segments: [ManualIssueSegment(row: 99, segment: 1)],
            rowLines: rowLines()
        )
        #expect(marker == nil)
    }

    @Test func blockCentroidIsMeanOfBoundary() {
        let centroid = ManualIssueContract.blockCentroid(points: blockPolygon)
        #expect(abs((centroid?.latitude ?? 0) - (-33.9995)) < 1e-9)
        #expect(abs((centroid?.longitude ?? 0) - 138.0001) < 1e-9)
    }

    // MARK: - Customer-facing wording (parity fixture)

    @Test func wholeRowSummaryUsesRanges() {
        var segments: [ManualIssueSegment] = []
        for row in [2, 3, 4, 6] {
            segments += (1...4).map { ManualIssueSegment(row: row, segment: $0) }
        }
        #expect(ManualIssueContract.rowSelectionSummary(segments) == "Rows 2–4, 6")
    }

    @Test func singleWholeRowSummary() {
        let segments = (1...4).map { ManualIssueSegment(row: 8, segment: $0) }
        #expect(ManualIssueContract.rowSelectionSummary(segments) == "Row 8")
    }

    @Test func partialRowSummaryListsSections() {
        let segments = [ManualIssueSegment(row: 5, segment: 1), ManualIssueSegment(row: 5, segment: 2)]
        #expect(ManualIssueContract.rowSelectionSummary(segments) == "Row 5 (sections 1–2)")
    }

    @Test func mixedSummaryPutsWholeRowsFirst() {
        var segments = (1...4).map { ManualIssueSegment(row: 2, segment: $0) }
        segments += (1...4).map { ManualIssueSegment(row: 3, segment: $0) }
        segments += [ManualIssueSegment(row: 5, segment: 1), ManualIssueSegment(row: 5, segment: 2)]
        #expect(ManualIssueContract.rowSelectionSummary(segments) == "Rows 2–3 · Row 5 (sections 1–2)")
    }

    @Test func nonContiguousSectionsUseCommaList() {
        let segments = [ManualIssueSegment(row: 5, segment: 1), ManualIssueSegment(row: 5, segment: 3)]
        #expect(ManualIssueContract.rowSelectionSummary(segments) == "Row 5 (sections 1, 3)")
    }

    @Test func attachedRowLabelPreservesDecimalPathRow() {
        // Exact path-row 19.5 stays intact in the wording and the data.
        #expect(ManualIssueContract.attachedRowLabel(drivingRowNumber: 19.5, pinRowNumber: 19, side: nil) == "On row 19.5")
        #expect(ManualIssueContract.attachedRowLabel(drivingRowNumber: nil, pinRowNumber: 15, side: "Left") == "On row 15 · left side")
        #expect(ManualIssueContract.attachedRowLabel(drivingRowNumber: nil, pinRowNumber: nil, side: nil) == nil)
    }

    // MARK: - Record behaviour

    @Test func recordDecodesCanonicalJson() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "vineyard_id": "22222222-2222-2222-2222-222222222222",
          "paddock_id": "33333333-3333-3333-3333-333333333333",
          "title": "Irrigation leak",
          "description": "Dripper line burst",
          "category": "infrastructure",
          "priority": "high",
          "status": "open",
          "location_scope": "row",
          "latitude": -33.9995,
          "longitude": 138.00004,
          "snapped_latitude": null,
          "snapped_longitude": null,
          "driving_row_number": null,
          "pin_row_number": null,
          "pin_side": null,
          "along_row_distance_m": null,
          "snapped_to_row": false,
          "assigned_user_id": null,
          "due_date": "2026-09-01",
          "linked_work_task_id": null,
          "photo_path": null,
          "created_by": null,
          "created_at": "2026-08-06T01:00:00.000000+00:00",
          "updated_at": "2026-08-06T01:00:00.000000+00:00",
          "client_updated_at": "2026-08-06T01:00:00.000000+00:00",
          "deleted_at": null,
          "completed_at": null,
          "completed_by_user_id": null,
          "completed_by": null,
          "segments": [{"row": 2, "segment": 1}, {"row": 2, "segment": 2}]
        }
        """
        let record = try JSONDecoder().decode(ManualIssueRecord.self, from: Data(json.utf8))
        #expect(record.title == "Irrigation leak")
        #expect(record.categoryValue == .infrastructure)
        #expect(record.priorityValue == .high)
        #expect(record.statusValue == .open)
        #expect(record.scopeValue == .row)
        #expect(record.isActive)
        #expect(record.segments?.count == 2)
        #expect(record.locationSummary == "Row 2 (sections 1–2)")
        #expect(record.dueDate == "2026-09-01")
    }

    @Test func blockScopeSummaryIsWholeBlock() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "vineyard_id": "22222222-2222-2222-2222-222222222222",
          "paddock_id": "33333333-3333-3333-3333-333333333333",
          "title": "Out of production",
          "category": "planning",
          "priority": "normal",
          "status": "cancelled",
          "location_scope": "block",
          "latitude": -33.9995,
          "longitude": 138.0001,
          "snapped_to_row": false,
          "segments": null
        }
        """
        let record = try JSONDecoder().decode(ManualIssueRecord.self, from: Data(json.utf8))
        #expect(record.locationSummary == "Whole block")
        #expect(!record.isActive)
        #expect(record.statusValue == .cancelled)
    }

    /// The create RPC params encode with the exact argument names sql/169
    /// declares — a drift here breaks offline replay.
    @Test func createParamsEncodeRpcArgumentNames() throws {
        let params = ManualIssueCreateParams(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            vineyardId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            title: "Leak",
            locationScope: "row",
            paddockId: nil,
            description: nil,
            category: "general",
            priority: "normal",
            latitude: -34.0,
            longitude: 138.0,
            clientUpdatedAt: "2026-08-06T01:00:00.000Z",
            segments: [ManualIssueSegment(row: 2, segment: 1)]
        )
        let data = try JSONEncoder().encode(params)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["p_id"] != nil)
        #expect(object["p_vineyard_id"] != nil)
        #expect(object["p_title"] as? String == "Leak")
        #expect(object["p_location_scope"] as? String == "row")
        #expect(object["p_category"] as? String == "general")
        #expect(object["p_priority"] as? String == "normal")
        #expect(object["p_client_updated_at"] != nil)
        #expect((object["p_segments"] as? [[String: Any]])?.count == 1)
    }

    /// A queued offline op round-trips through Codable without loss —
    /// legacy-cache safety for the outbox.
    @Test func pendingOpRoundTripsThroughCodable() throws {
        let params = ManualIssueCreateParams(
            id: UUID(),
            vineyardId: UUID(),
            title: "Leak",
            locationScope: "point",
            latitude: -34.0,
            longitude: 138.0,
            clientUpdatedAt: "2026-08-06T01:00:00.000Z"
        )
        let op = ManualIssuePendingOp(
            id: UUID(), issueId: params.id, kind: .create,
            createParams: params, updateParams: nil, status: nil,
            queuedAt: Date(), attempts: 0, lastError: nil
        )
        let data = try JSONEncoder().encode([op])
        let decoded = try JSONDecoder().decode([ManualIssuePendingOp].self, from: data)
        #expect(decoded.count == 1)
        #expect(decoded.first?.issueId == params.id)
        #expect(decoded.first?.kind == .create)
        #expect(decoded.first?.createParams?.title == "Leak")
    }

    /// Replay order: creates land before updates/status/cancel/delete so a
    /// dependent write never targets a not-yet-created issue.
    @Test func replayOrderIsCreateFirst() {
        #expect(ManualIssuePendingOp.Kind.create.replayOrder < ManualIssuePendingOp.Kind.update.replayOrder)
        #expect(ManualIssuePendingOp.Kind.update.replayOrder < ManualIssuePendingOp.Kind.status.replayOrder)
        #expect(ManualIssuePendingOp.Kind.status.replayOrder < ManualIssuePendingOp.Kind.cancel.replayOrder)
        #expect(ManualIssuePendingOp.Kind.cancel.replayOrder < ManualIssuePendingOp.Kind.delete.replayOrder)
    }

    /// Manual issues are a pin mode — the raw value written to pins.mode.
    @Test func pinModeRawValueIsStable() {
        #expect(PinMode.manualIssue.rawValue == "ManualIssue")
    }
}
