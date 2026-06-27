import Foundation

/// A single diesel fill recorded against a tractor. Operators record litres
/// added and the engine hours at the fill; VineTrack derives an hourly fuel
/// usage rate (litres/hour) from consecutive logs for the same tractor.
/// The rate is calculated for display only in Phase 1 — it is never persisted.
nonisolated struct TractorFuelLog: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var tractorId: UUID?
    /// Preferred link to a `VineyardMachine`. Nullable; `tractorId` is kept
    /// as the legacy fallback link for rows created before the Vineyard
    /// Machines model. New fuel logs should set this.
    var machineId: UUID?
    var fillDateTime: Date
    var litresAdded: Double
    var engineHours: Double?
    var operatorUserId: UUID?
    var operatorName: String?
    var costPerLitre: Double?
    var totalCost: Double?
    var filledToFull: Bool?
    var notes: String?

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        tractorId: UUID? = nil,
        machineId: UUID? = nil,
        fillDateTime: Date = Date(),
        litresAdded: Double = 0,
        engineHours: Double? = nil,
        operatorUserId: UUID? = nil,
        operatorName: String? = nil,
        costPerLitre: Double? = nil,
        totalCost: Double? = nil,
        filledToFull: Bool? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.tractorId = tractorId
        self.machineId = machineId
        self.fillDateTime = fillDateTime
        self.litresAdded = litresAdded
        self.engineHours = engineHours
        self.operatorUserId = operatorUserId
        self.operatorName = operatorName
        self.costPerLitre = costPerLitre
        self.totalCost = totalCost
        self.filledToFull = filledToFull
        self.notes = notes
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, vineyardId, tractorId, machineId, fillDateTime, litresAdded, engineHours
        case operatorUserId, operatorName, costPerLitre, totalCost, filledToFull, notes
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        vineyardId = try container.decode(UUID.self, forKey: .vineyardId)
        tractorId = try container.decodeIfPresent(UUID.self, forKey: .tractorId)
        machineId = try container.decodeIfPresent(UUID.self, forKey: .machineId)
        fillDateTime = try container.decodeIfPresent(Date.self, forKey: .fillDateTime) ?? Date()
        litresAdded = try container.decodeIfPresent(Double.self, forKey: .litresAdded) ?? 0
        engineHours = try container.decodeIfPresent(Double.self, forKey: .engineHours)
        operatorUserId = try container.decodeIfPresent(UUID.self, forKey: .operatorUserId)
        operatorName = try container.decodeIfPresent(String.self, forKey: .operatorName)
        costPerLitre = try container.decodeIfPresent(Double.self, forKey: .costPerLitre)
        totalCost = try container.decodeIfPresent(Double.self, forKey: .totalCost)
        filledToFull = try container.decodeIfPresent(Bool.self, forKey: .filledToFull)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }
}

/// Display-only litres/hour calculation derived from two consecutive fuel
/// logs for the same tractor. Never persisted in Phase 1.
nonisolated struct TractorFuelRateResult: Sendable, Equatable {
    enum Reliability: Sendable, Equatable {
        /// Both fills marked filled-to-full — most reliable.
        case reliable
        /// Calculated, but one/both fills were not to a full tank.
        case estimate
    }

    enum Warning: Sendable, Equatable {
        case missingEngineHours
        case engineHoursWentBackwards
        case engineHoursDeltaZero
        case unrealisticRate
        case notFilledToFull
    }

    let litresPerHour: Double?
    let engineHoursDelta: Double?
    let reliability: Reliability
    let warnings: [Warning]
}

nonisolated enum TractorFuelRateCalculator {
    /// Lower/upper sanity bounds for litres/hour. Outside this range the rate
    /// is flagged as unrealistic (kept, but cautioned).
    static let minRealisticLitresPerHour: Double = 1
    static let maxRealisticLitresPerHour: Double = 80

    /// Calculate the display litres/hour for `current` relative to `previous`
    /// (the most recent earlier fill for the same tractor). Returns warnings
    /// describing why a rate could not be computed or may be inaccurate.
    static func rate(current: TractorFuelLog, previous: TractorFuelLog?) -> TractorFuelRateResult {
        typealias Warning = TractorFuelRateResult.Warning
        var warnings: [Warning] = []

        guard let previous else {
            // First log for the tractor — nothing to compare against.
            if current.engineHours == nil { warnings.append(.missingEngineHours) }
            return TractorFuelRateResult(
                litresPerHour: nil,
                engineHoursDelta: nil,
                reliability: .estimate,
                warnings: warnings
            )
        }

        guard let curHours = current.engineHours, let prevHours = previous.engineHours else {
            warnings.append(.missingEngineHours)
            return TractorFuelRateResult(
                litresPerHour: nil,
                engineHoursDelta: nil,
                reliability: .estimate,
                warnings: warnings
            )
        }

        let delta = curHours - prevHours
        if delta < 0 {
            warnings.append(.engineHoursWentBackwards)
            return TractorFuelRateResult(
                litresPerHour: nil,
                engineHoursDelta: delta,
                reliability: .estimate,
                warnings: warnings
            )
        }
        if delta == 0 {
            warnings.append(.engineHoursDeltaZero)
            return TractorFuelRateResult(
                litresPerHour: nil,
                engineHoursDelta: 0,
                reliability: .estimate,
                warnings: warnings
            )
        }

        let lph = current.litresAdded / delta

        let bothFull = (current.filledToFull == true) && (previous.filledToFull == true)
        if !bothFull { warnings.append(.notFilledToFull) }
        if lph < minRealisticLitresPerHour || lph > maxRealisticLitresPerHour {
            warnings.append(.unrealisticRate)
        }

        return TractorFuelRateResult(
            litresPerHour: lph,
            engineHoursDelta: delta,
            reliability: bothFull ? .reliable : .estimate,
            warnings: warnings
        )
    }
}
