import Foundation

/// Operational phenology context for the vineyard-level advisor. One canonical row
/// per block + variety; mirrored pins are already represented by their growth row.
nonisolated struct DiseaseBlockStage: Sendable, Equatable {
    let vineyardId: UUID
    let paddockId: UUID?
    let variety: String?
    let stageCode: String
    let stageLabel: String?
    let observedAt: Date
    let el: Int
}

/// Advisory, not an infection model or a product recommendation. Parity contract:
/// Android DiseaseGrowthStagePolicy uses the same inclusive E-L intervals and
/// one-tier reduction outside them; never increases environmental pressure.
nonisolated enum DiseaseGrowthStagePolicy {
    static func resolve(records: [GrowthStageRecord], vineyardId: UUID, season: SeasonWindow, now: Date) -> [DiseaseBlockStage] {
        var latest: [String: GrowthStageRecord] = [:]
        for record in records where record.vineyardId == vineyardId && season.contains(record.observedAt) && record.observedAt <= now {
            guard let el = ELRipeness.parseElStage(record.stageCode), el == el.rounded() else { continue }
            let key = "\(record.paddockId?.uuidString ?? "unassigned")|\(record.varietyId?.uuidString ?? record.variety?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")"
            if let previous = latest[key], previous.observedAt > record.observedAt ||
                (previous.observedAt == record.observedAt && previous.id.uuidString >= record.id.uuidString) { continue }
            latest[key] = record
        }
        return latest.values.compactMap { record in
            guard let el = ELRipeness.parseElStage(record.stageCode) else { return nil }
            return DiseaseBlockStage(vineyardId: record.vineyardId, paddockId: record.paddockId,
                                     variety: record.variety, stageCode: record.stageCode,
                                     stageLabel: record.stageLabel, observedAt: record.observedAt, el: Int(el))
        }.sorted { a, b in
            let left = "\(a.paddockId?.uuidString ?? "")|\(a.variety ?? "")|\(a.stageCode)"
            let right = "\(b.paddockId?.uuidString ?? "")|\(b.variety ?? "")|\(b.stageCode)"
            return left < right
        }
    }

    static func stageText(_ stages: [DiseaseBlockStage]) -> String {
        let values = stages.map(\.el)
        guard let low = values.min(), let high = values.max() else { return "No current-season observation" }
        return low == high ? "EL\(low)" : "EL\(low)–EL\(high)"
    }

    /// A conservative vineyard summary: the highest remaining pressure among
    /// observed blocks. Unobserved blocks cannot be asserted safe; the screen
    /// describes observed blocks only. Latest stage is held fixed for all 7 days.
    static func adjust(_ base: DiseaseRiskAssessment, stages: [DiseaseBlockStage]) -> DiseaseRiskAssessment {
        guard !stages.isEmpty, let severity = base.severity else { return base }
        let final: AlertSeverity? = stages.map { stage in
            susceptible(base.model, at: stage.el) ? severity : reduced(severity)
        }.max { rank($0) < rank($1) } ?? severity
        return DiseaseRiskAssessment(model: base.model, severity: final, title: base.title,
                                     summary: base.summary, usedMeasuredWetness: base.usedMeasuredWetness)
    }

    static func changed(_ base: DiseaseRiskAssessment, _ final: DiseaseRiskAssessment) -> Bool {
        base.severity != final.severity
    }

    private static func susceptible(_ model: DiseaseModel, at el: Int) -> Bool {
        switch model {
        case .downyMildew: return (12...33).contains(el)
        case .powderyMildew: return (12...33).contains(el)
        case .botrytis: return (19...25).contains(el) || (33...47).contains(el)
        }
    }

    private static func reduced(_ severity: AlertSeverity) -> AlertSeverity? {
        switch severity {
        case .critical: return .warning
        case .warning: return nil
        case .info: return nil
        }
    }

    private static func rank(_ severity: AlertSeverity?) -> Int {
        switch severity {
        case .critical: return 3
        case .warning: return 2
        case .info: return 1
        case nil: return 0
        }
    }
}
