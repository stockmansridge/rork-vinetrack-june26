import Foundation

/// Current-vintage datasets shared by progression and both Vintage formats.
nonisolated enum SprayProgramProgression {
    private static let stagePattern = #"(?i)(?<![a-z0-9])e-?l[\s.\-]*(?:stage\s*)?([0-9]{1,3})(?![0-9])"#

    static func stage(_ record: SprayRecord) -> Int? {
        let text = record.sprayReference + " " + record.notes
        guard let regex = try? NSRegularExpression(pattern: stagePattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text), let stage = Int(text[range]),
              GrowthStage.allStages.contains(where: { ELStageParser.stageNumber(fromCode: $0.code) == stage }) else { return nil }
        return stage
    }

    static func stage(_ step: SprayProgramStep) -> Int? {
        let value = step.elStage ?? stage(step.record)
        return value.flatMap { number in
            GrowthStage.allStages.contains { ELStageParser.stageNumber(fromCode: $0.code) == number } ? number : nil
        }
    }

    static func normalizedName(_ name: String) -> String {
        name.replacingOccurrences(of: stagePattern, with: "", options: .regularExpression)
            .lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func completed(records: [SprayRecord], trips: [Trip], vineyardId: UUID?, window: SeasonWindow) -> [SprayRecord] {
        SprayProgramOperationalRecords.unique(records).filter { record in
            record.vineyardId == vineyardId && record.hasRecordedEventDate && window.contains(record.date) &&
            SprayCompletionResolver.status(record: record, trip: trips.first { $0.id == record.canonicalTripId }) == .completed
        }
    }

    static func remaining(steps: [SprayProgramStep], completed: [SprayRecord]) -> [SprayProgramStep] {
        let highest = completed.compactMap { record in
            record.sprayJobId.flatMap { id in steps.first { $0.id == id }.flatMap { stage($0) } } ?? stage(record)
        }.max()
        return steps.filter { step in
            guard let highest else { return true }
            let stepStage = stage(step)
            if let stepStage, stepStage < highest { return false }
            return !completed.contains { record in
                if let provenance = record.sprayJobId { return provenance == step.id }
                guard let stepStage, stage(record) == stepStage else { return false }
                let name = normalizedName(step.name)
                return !name.isEmpty && normalizedName(record.sprayReference) == name
            }
        }.sorted { left, right in
            let lhs = stage(left) ?? Int.max
            let rhs = stage(right) ?? Int.max
            if lhs != rhs { return lhs < rhs }
            if left.name != right.name { return left.name < right.name }
            return left.id.uuidString < right.id.uuidString
        }
    }
}
