import Foundation

/// Block-qualified preview context survives pattern expansion without minting IDs on recomposition.
enum TripOccurrencePlanner {
    struct Candidate: Identifiable, Hashable {
        let vineyardId: UUID
        let blockId: UUID
        let blockName: String
        let label: Double
        let rows: [PaddockRow]
        var id: String { "\(blockId.uuidString.lowercased())|\(label)|\(rows.map { $0.id.uuidString.lowercased() }.joined(separator: "|"))" }
        var display: String { "\(blockName) · Path \(TripRowSequencePlanner.formatPath(label))" }
    }

    static func candidates(_ blocks: [Paddock]) -> [Candidate] {
        var seen: Set<String> = []
        return blocks.sorted(by: TripRowSequencePlanner.rowOrderSort).flatMap { block in
            let labels = Set(block.rows.flatMap { [$0.calculationRowNumber - 0.5, $0.calculationRowNumber + 0.5] }).sorted()
            return labels.map { label in
                Candidate(vineyardId: block.vineyardId, blockId: block.id, blockName: block.name, label: label,
                          rows: block.rows.filter { abs($0.calculationRowNumber - label) <= 0.5 }.sorted { $0.calculationRowNumber < $1.calculationRowNumber })
            }
        }.filter { seen.insert($0.id).inserted }
    }

    static func plan(_ candidates: [Candidate], pattern: TrackingPattern, startKey: String?, higherFirst: Bool) -> [Candidate] {
        guard pattern != .freeDrive, !candidates.isEmpty else { return [] }
        let sorted = higherFirst ? candidates : candidates.reversed().map { $0 }
        let start = sorted.firstIndex { $0.id == startKey } ?? 0
        let ordered = Array(sorted[start...]) + Array(sorted[..<start])
        if pattern == .everySecondRow {
            return ordered.filter { Int(($0.label - ordered[0].label).rounded()) % 2 == 0 }
        }
        let indices = TripRowSequencePlanner.plannedSequence(paths: ordered.indices.map { Double($0) }, pattern: pattern, startPath: 0, higherFirst: true)
        return indices.map { ordered[Int($0)] }
    }

    static func preview(_ planned: [Candidate], maxItems: Int = 10) -> String {
        var passes: [String: Int] = [:]
        let lines = planned.prefix(maxItems).map { candidate in
            let pass = (passes[candidate.id] ?? 0) + 1; passes[candidate.id] = pass
            return "\(candidate.display) · Pass \(pass)"
        }
        return lines.joined(separator: " → ") + (planned.count > maxItems ? " → …" : "")
    }

    /// Called once at durable acceptance. Native snapshots are validated, never silently downgraded.
    static func commit(_ candidates: [Candidate], vineyardId: UUID) throws -> TripOccurrenceCoverage.JSON {
        typealias JSON = TripOccurrenceCoverage.JSON
        guard !candidates.isEmpty, candidates.allSatisfy({ $0.vineyardId == vineyardId && $0.rows.count <= 2 && Set($0.rows.map(\.id)).count == $0.rows.count }) else { throw TripOccurrenceCoverage.Failure.scopeConflict }
        var refs: [String: JSON] = [:]
        var passes: [String: Int] = [:]
        var items: [JSON] = []
        var ids: [String] = []
        for candidate in candidates {
            if refs[candidate.id] == nil {
                let resolved = !candidate.rows.isEmpty && candidate.rows.allSatisfy { row in
                    row.hasStoredIdentity && [row.startPoint, row.endPoint].allSatisfy {
                        $0.latitude.isFinite && $0.longitude.isFinite && abs($0.latitude) <= 90 && abs($0.longitude) <= 180
                    }
                }
                let snapshots: [JSON] = resolved ? candidate.rows.map { row in
                    .object(["id": .string(row.id.uuidString.lowercased()), "number": .number(row.calculationRowNumber),
                        "startPoint": .object(["latitude": .number(row.startPoint.latitude), "longitude": .number(row.startPoint.longitude)]),
                        "endPoint": .object(["latitude": .number(row.endPoint.latitude), "longitude": .number(row.endPoint.longitude)])])
                } : []
                refs[candidate.id] = .object([
                    "pathId": .string(UUID().uuidString.lowercased()),
                    "rowIds": .array(resolved ? candidate.rows.map { .string($0.id.uuidString.lowercased()) } : []),
                    "candidateRowIds": .array(candidate.rows.map { .string($0.id.uuidString.lowercased()) }),
                    "rowSnapshots": .array(snapshots), "geometryRevision": .string(resolved ? "native-snapshot-v1" : "unresolved"),
                    "boundarySide": .string(candidate.rows.count == 1 ? (candidate.label < candidate.rows[0].calculationRowNumber ? "before" : "after") : "between")
                ])
            }
            let id = UUID().uuidString.lowercased(); ids.append(id)
            let pass = (passes[candidate.id] ?? 0) + 1; passes[candidate.id] = pass
            items.append(.object(["occurrenceId": .string(id), "blockId": .string(candidate.blockId.uuidString.lowercased()),
                "blockNameSnapshot": .string(candidate.blockName), "pathNumber": .number(candidate.label),
                "passOrdinal": .number(Double(pass)), "physicalPathRef": refs[candidate.id] ?? .null]))
        }
        let states = Dictionary(uniqueKeysWithValues: ids.map { ($0, JSON.object([
            "status": .string("incomplete"), "lastOperationId": .null, "source": .null, "tankSessionIds": .array([])])) })
        let result: JSON = .object(["contract": .string("vinetrack.planned-occurrence"), "schemaVersion": .number(1),
            "planId": .string(UUID().uuidString.lowercased()), "revision": .number(0), "planRevision": .number(1),
            "items": .array(items), "activeOrder": .array(ids.map { .string($0) }), "retired": .array([]),
            "states": .object(states), "plannedCursorId": .string(ids[0]), "selectedOccurrenceId": .null])
        _ = try TripOccurrenceCoverage.requireDocument(result)
        return result
    }
}
