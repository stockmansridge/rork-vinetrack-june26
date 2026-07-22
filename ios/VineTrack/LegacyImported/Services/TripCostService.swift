import Foundation

/// Pure calculator that estimates labour, fuel and chemical/input cost for a
/// single trip from existing models. No persistence, no UI \u{2014} the caller is
/// responsible for gating display via `canViewCosting` (owner/manager only).
///
/// Inputs intentionally avoid SwiftUI/Observable types so this can be unit
/// tested and reused from reports/exports without dragging in @MainActor.
nonisolated enum TripCostService {

    // MARK: - Output

    nonisolated enum CostingCompleteness: String, Sendable {
        case complete
        case partial
        case unavailable
    }

    nonisolated struct LabourBreakdown: Sendable {
        let categoryName: String?
        let costPerHour: Double?
        let hours: Double
        let cost: Double
        let warning: String?
    }

    /// How fuel litres were derived for a trip.
    nonisolated enum FuelBasis: String, Sendable {
        /// Engine-hour delta (end - start) × tractor L/hr. Preferred when valid.
        case engineHours
        /// Active trip duration (excluding pauses) × tractor L/hr. Fallback.
        case duration

        var label: String {
            switch self {
            case .engineHours: return "Engine hours"
            case .duration: return "Trip duration"
            }
        }
    }

    nonisolated struct FuelBreakdown: Sendable {
        /// Display name of the powered unit used for fuel (vineyard machine when
        /// linked, otherwise the legacy tractor).
        let machineName: String?
        let fuelUsageLPerHour: Double?
        let costPerLitre: Double?
        let litres: Double
        let cost: Double
        let warning: String?
        /// Which basis produced `litres` (engine hours vs trip duration).
        let basis: FuelBasis
        /// Hours used for the litres calculation (engine-hour delta or active hours).
        let fuelHours: Double
        /// Engine-hour delta when start/end readings are valid (end > start), else nil.
        let engineHourDelta: Double?
    }

    nonisolated struct ChemicalBreakdown: Sendable {
        let cost: Double
        let warning: String?
    }

    nonisolated struct SeedingBreakdown: Sendable {
        /// Estimated seed/input cost across all mix lines that resolved a
        /// cost-per-unit (snapshot, savedInputId, or name match).
        let cost: Double
        /// Number of mix lines with usage but no resolvable cost-per-unit.
        let missingCount: Int
        /// Human-friendly summary suitable for display under the cost row.
        let warning: String?
    }

    nonisolated struct Result: Sendable {
        let activeHours: Double
        let labour: LabourBreakdown
        let fuel: FuelBreakdown
        let chemical: ChemicalBreakdown?
        let seeding: SeedingBreakdown?
        let totalCost: Double
        let completeness: CostingCompleteness
        let warnings: [String]

        // Phase 4D — cost per ha / cost per tonne.
        /// Sum of `Paddock.areaHectares` across every paddock this trip was
        /// linked to. nil when no paddock area could be resolved.
        let treatedAreaHa: Double?
        /// totalCost / treatedAreaHa when both are usable, else nil.
        let costPerHa: Double?
        /// Yield tonnes for the linked paddock(s) sourced from
        /// HistoricalYieldRecord.blockResults. nil when no reliable match
        /// exists — we never guess.
        let yieldTonnes: Double?
        /// totalCost / yieldTonnes when both are usable, else nil.
        let costPerTonne: Double?
        /// Why treated area is missing or partial. nil when complete.
        let areaWarning: String?
        /// Why yield tonnes are missing or uncertain. nil when complete.
        let yieldWarning: String?
    }

    // MARK: - Entry point

    /// Estimate the cost of `trip` using already-resolved supporting data.
    ///
    /// - Parameters:
    ///   - trip: The trip being costed.
    ///   - operatorCategory: Operator category to use for labour cost.
    ///     Resolved by the caller in priority order:
    ///       1. `trip.operatorCategoryId`
    ///       2. `vineyard_members.operator_category_id` for `trip.operatorUserId`
    ///   - machine: Vineyard machine referenced by `trip.machineId`, if known.
    ///     Preferred fuel source when it has an approved (> 0) L/hr rate.
    ///   - tractor: Tractor referenced by `trip.tractorId`, if known. Legacy
    ///     fuel-rate fallback used when no machine rate is available.
    ///   - fuelPurchases: All fuel purchases for the vineyard. Used to derive
    ///     a weighted average cost per litre.
    ///   - sprayRecord: Linked spray record (`spray_records.trip_id == trip.id`)
    ///     when one exists. Drives chemical cost.
    static func estimate(
        trip: Trip,
        operatorCategory: OperatorCategory?,
        machine: VineyardMachine? = nil,
        tractor: Tractor?,
        fuelPurchases: [FuelPurchase],
        sprayRecord: SprayRecord?,
        savedChemicals: [SavedChemical] = [],
        savedInputs: [SavedInput] = [],
        paddockHectares: Double? = nil,
        paddockAreasById: [UUID: Double] = [:],
        historicalYieldRecords: [HistoricalYieldRecord] = []
    ) -> Result {
        let hours = max(0, trip.activeDuration / 3600.0)

        // ---- Labour ---------------------------------------------------------
        let labour: LabourBreakdown
        if let cat = operatorCategory, cat.costPerHour > 0, hours > 0 {
            labour = LabourBreakdown(
                categoryName: cat.name,
                costPerHour: cat.costPerHour,
                hours: hours,
                cost: cat.costPerHour * hours,
                warning: nil
            )
        } else if let cat = operatorCategory, cat.costPerHour <= 0 {
            labour = LabourBreakdown(
                categoryName: cat.name,
                costPerHour: 0,
                hours: hours,
                cost: 0,
                warning: "Worker type has no hourly rate."
            )
        } else if trip.operatorUserId == nil && trip.operatorCategoryId == nil {
            labour = LabourBreakdown(
                categoryName: nil,
                costPerHour: nil,
                hours: hours,
                cost: 0,
                warning: "No operator assigned to this trip."
            )
        } else {
            labour = LabourBreakdown(
                categoryName: nil,
                costPerHour: nil,
                hours: hours,
                cost: 0,
                warning: "Operator has no worker type assigned. Set one in Team & Access."
            )
        }

        // ---- Fuel -----------------------------------------------------------
        // Prefer engine-hour delta (end - start) when both readings are present
        // and end > start; otherwise fall back to active trip duration.
        let engineHourDelta: Double? = {
            guard let s = trip.startEngineHours, let e = trip.endEngineHours, e > s else { return nil }
            return e - s
        }()
        let fuelBasis: FuelBasis = engineHourDelta != nil ? .engineHours : .duration
        let fuelHours = engineHourDelta ?? hours
        let weightedCostPerLitre = weightedFuelCostPerLitre(fuelPurchases)

        // Resolve the effective fuel source. Prefer the linked vineyard machine
        // when it has an approved (> 0) rate; otherwise fall back to the legacy
        // tractor rate. A rate of 0 is treated as "not set" and never used.
        let machineRate = machine?.fuelUsageLPerHour ?? 0
        let tractorRate = tractor?.fuelUsageLPerHour ?? 0
        let hasMachineLink = machine != nil || trip.machineId != nil
        let hasTractorLink = tractor != nil || trip.tractorId != nil
        let hasAnyLink = hasMachineLink || hasTractorLink
        // Name prefers the machine identity when a machine is linked, otherwise
        // the legacy tractor name.
        let fuelSourceName = machine?.displayName ?? tractor?.displayName
        let effectiveRate: Double = machineRate > 0 ? machineRate : tractorRate

        let fuel: FuelBreakdown
        if effectiveRate > 0, fuelHours > 0, let perL = weightedCostPerLitre {
            let litres = effectiveRate * fuelHours
            fuel = FuelBreakdown(
                machineName: fuelSourceName,
                fuelUsageLPerHour: effectiveRate,
                costPerLitre: perL,
                litres: litres,
                cost: litres * perL,
                warning: nil,
                basis: fuelBasis,
                fuelHours: fuelHours,
                engineHourDelta: engineHourDelta
            )
        } else if !hasAnyLink {
            fuel = FuelBreakdown(
                machineName: nil,
                fuelUsageLPerHour: nil,
                costPerLitre: weightedCostPerLitre,
                litres: 0,
                cost: 0,
                warning: "No machine linked to this trip.",
                basis: fuelBasis,
                fuelHours: fuelHours,
                engineHourDelta: engineHourDelta
            )
        } else if effectiveRate <= 0 {
            // Linked but no approved fuel rate. Point the user at the right place
            // to set it depending on whether a machine or a legacy tractor is
            // the source.
            let warning = hasMachineLink
                ? "Fuel rate missing \u{2014} set the machine's fuel usage (L/hr) in Vineyard Machines."
                : "Fuel rate missing \u{2014} set the tractor's fuel usage (L/hr) in Equipment."
            fuel = FuelBreakdown(
                machineName: fuelSourceName,
                fuelUsageLPerHour: 0,
                costPerLitre: weightedCostPerLitre,
                litres: 0,
                cost: 0,
                warning: warning,
                basis: fuelBasis,
                fuelHours: fuelHours,
                engineHourDelta: engineHourDelta
            )
        } else if weightedCostPerLitre == nil {
            fuel = FuelBreakdown(
                machineName: fuelSourceName,
                fuelUsageLPerHour: effectiveRate,
                costPerLitre: nil,
                litres: effectiveRate * fuelHours,
                cost: 0,
                warning: "No fuel purchases recorded \u{2014} add one in Equipment to enable fuel cost.",
                basis: fuelBasis,
                fuelHours: fuelHours,
                engineHourDelta: engineHourDelta
            )
        } else {
            fuel = FuelBreakdown(
                machineName: fuelSourceName,
                fuelUsageLPerHour: effectiveRate,
                costPerLitre: weightedCostPerLitre,
                litres: 0,
                cost: 0,
                warning: "Fuel cost unavailable.",
                basis: fuelBasis,
                fuelHours: fuelHours,
                engineHourDelta: engineHourDelta
            )
        }

        // ---- Chemical -------------------------------------------------------
        // Resolve cost per unit in priority order:
        //   1. SprayChemical.costPerUnit snapshot stored on the record.
        //   2. SavedChemical.purchase.costPerBaseUnit via savedChemicalId.
        //   3. SavedChemical.purchase.costPerBaseUnit via case-insensitive name match.
        // Step 1 is the canonical path going forward; steps 2/3 keep older
        // records (created before snapshotting) costable.
        let chemical: ChemicalBreakdown? = sprayRecord.map { record in
            var total: Double = 0
            var anyMissing = false
            var anyPriced = false
            for tank in record.tanks {
                for chem in tank.chemicals {
                    let resolvedCostPerUnit = resolveCostPerUnit(chem, savedChemicals: savedChemicals)
                    if let cpu = resolvedCostPerUnit, cpu > 0 {
                        total += cpu * chem.volumePerTank
                        anyPriced = true
                    } else if chem.volumePerTank > 0 {
                        anyMissing = true
                    }
                }
            }
            let warning: String?
            if !anyPriced && anyMissing {
                warning = "Chemical cost unavailable \u{2014} costs per unit not set on saved chemicals."
            } else if anyMissing {
                warning = "Some chemicals are missing a cost per unit."
            } else {
                warning = nil
            }
            return ChemicalBreakdown(cost: total, warning: warning)
        }

        // ---- Seeding / input -----------------------------------------------
        let isInputTrip = trip.tripFunction == TripFunction.seeding.rawValue
            || trip.tripFunction == TripFunction.spreading.rawValue
            || trip.tripFunction == TripFunction.fertilising.rawValue
        let seeding: SeedingBreakdown?
        if isInputTrip {
            seeding = estimateSeedingCost(
                trip: trip,
                savedInputs: savedInputs,
                paddockHectares: paddockHectares
            )
        } else {
            seeding = nil
        }

        // ---- Total & completeness ------------------------------------------
        let total = labour.cost + fuel.cost + (chemical?.cost ?? 0) + (seeding?.cost ?? 0)

        var warnings: [String] = []
        if let w = labour.warning { warnings.append(w) }
        if let w = fuel.warning { warnings.append(w) }
        if let w = chemical?.warning { warnings.append(w) }
        if let s = seeding?.warning { warnings.append(s) }

        let labourOK = labour.warning == nil
        let fuelOK = fuel.warning == nil
        // Chemical is optional: only counts against completeness if a spray
        // record exists at all.
        let chemicalOK = chemical?.warning == nil
        let seedingOK = (seeding?.warning == nil)
        let completeness: CostingCompleteness
        if labourOK && fuelOK && chemicalOK && seedingOK {
            completeness = .complete
        } else if total > 0 || labourOK || fuelOK || chemicalOK || (seeding?.cost ?? 0) > 0 {
            completeness = .partial
        } else {
            completeness = .unavailable
        }

        // ---- Treated area & cost per ha ------------------------------------
        let tripPaddockIds: [UUID] = {
            if !trip.paddockIds.isEmpty { return trip.paddockIds }
            if let single = trip.paddockId { return [single] }
            return []
        }()
        let area: Double?
        let areaWarning: String?
        if !paddockAreasById.isEmpty, !tripPaddockIds.isEmpty {
            var sum: Double = 0
            var missing = 0
            for id in tripPaddockIds {
                if let a = paddockAreasById[id], a > 0 { sum += a } else { missing += 1 }
            }
            if sum > 0 && missing == 0 {
                area = sum
                areaWarning = nil
            } else if sum > 0 {
                area = sum
                areaWarning = "Some blocks are missing an area — cost per ha may be understated."
            } else {
                area = nil
                areaWarning = "Cost per ha unavailable — treated area missing."
            }
        } else if let ha = paddockHectares, ha > 0 {
            area = ha
            areaWarning = nil
        } else {
            area = nil
            areaWarning = "Cost per ha unavailable — treated area missing."
        }
        let costPerHa: Double? = {
            guard let a = area, a > 0, total > 0 else { return nil }
            return total / a
        }()

        // ---- Yield tonnes & cost per tonne ---------------------------------
        // Only `actualYieldTonnes` is used — never an estimate. If ANY linked
        // paddock cannot be matched the result is reported unavailable, per
        // requirement that uncertain matching must surface as unavailable
        // rather than a misleading figure.
        let yieldResolution = resolveYieldTonnes(
            vineyardId: trip.vineyardId,
            tripStart: trip.startTime,
            paddockIds: tripPaddockIds,
            historicalYieldRecords: historicalYieldRecords
        )
        let yieldTonnes = yieldResolution.tonnes
        let yieldWarning = yieldResolution.warning
        let costPerTonne: Double? = {
            guard let y = yieldTonnes, y > 0, total > 0 else { return nil }
            return total / y
        }()

        return Result(
            activeHours: hours,
            labour: labour,
            fuel: fuel,
            chemical: chemical,
            seeding: seeding,
            totalCost: total,
            completeness: completeness,
            warnings: warnings,
            treatedAreaHa: area,
            costPerHa: costPerHa,
            yieldTonnes: yieldTonnes,
            costPerTonne: costPerTonne,
            areaWarning: areaWarning,
            yieldWarning: yieldWarning
        )
    }

    // MARK: - Yield resolution

    nonisolated struct YieldResolution: Sendable {
        let tonnes: Double?
        let warning: String?
    }

    /// Resolve total yield tonnes across all linked paddocks for a trip.
    ///
    /// Rules:
    ///  * Only `actualYieldTonnes` is used — never an estimate.
    ///  * For each paddock, prefer the historical record whose `year` matches
    ///    the trip year; otherwise the most recent record <= trip year;
    ///    otherwise the most recent record overall.
    ///  * If ANY linked paddock cannot be matched, the whole result is
    ///    reported unavailable (no partial / misleading totals).
    static func resolveYieldTonnes(
        vineyardId: UUID,
        tripStart: Date,
        paddockIds: [UUID],
        historicalYieldRecords: [HistoricalYieldRecord]
    ) -> YieldResolution {
        let unavailable = YieldResolution(tonnes: nil, warning: "Cost per tonne unavailable — yield data missing.")
        guard !paddockIds.isEmpty else { return unavailable }
        let records = historicalYieldRecords.filter { $0.vineyardId == vineyardId }
        guard !records.isEmpty else { return unavailable }
        let tripYear = Calendar.current.component(.year, from: tripStart)

        var total: Double = 0
        for pid in paddockIds {
            let candidates: [(record: HistoricalYieldRecord, block: HistoricalBlockResult)] = records.flatMap { rec in
                rec.blockResults
                    .filter { $0.paddockId == pid && $0.actualYieldTonnes != nil }
                    .map { (rec, $0) }
            }
            guard !candidates.isEmpty else { return unavailable }
            let exact = candidates.first { $0.record.year == tripYear }
            let prior = candidates
                .filter { $0.record.year <= tripYear }
                .max { $0.record.year < $1.record.year }
            let mostRecent = candidates.max { $0.record.year < $1.record.year }
            let picked = exact ?? prior ?? mostRecent
            guard let tonnes = picked?.block.actualYieldTonnes, tonnes > 0 else { return unavailable }
            total += tonnes
        }
        return total > 0
            ? YieldResolution(tonnes: total, warning: nil)
            : unavailable
    }

    // MARK: - Seeding / input cost

    /// Estimate seed/input cost for a seeding / spreading / fertilising trip.
    ///
    /// Cost-per-unit resolution priority for each mix line:
    ///   1. `SeedingMixLine.costPerUnit` snapshot on the trip.
    ///   2. `savedInputs.first { $0.id == savedInputId }.costPerUnit`.
    ///   3. Case-insensitive name match against `savedInputs`.
    /// Missing costs are reported via `missingCount` / `warning` and never
    /// silently treated as $0.
    static func estimateSeedingCost(
        trip: Trip,
        savedInputs: [SavedInput],
        paddockHectares: Double?
    ) -> SeedingBreakdown {
        let lines = trip.seedingDetails?.mixLines ?? []
        guard !lines.isEmpty else {
            return SeedingBreakdown(
                cost: 0,
                missingCount: 0,
                warning: "Seed/input cost unavailable \u{2014} cost per kg not configured."
            )
        }
        var total: Double = 0
        var anyPriced = false
        var missing = 0
        for line in lines {
            let amount = resolveLineAmount(line, paddockHectares: paddockHectares)
            guard amount > 0 else { continue }
            if let cpu = resolveSeedingCostPerUnit(line, savedInputs: savedInputs), cpu > 0 {
                total += cpu * amount
                anyPriced = true
            } else {
                missing += 1
            }
        }
        let warning: String?
        if !anyPriced && missing > 0 {
            warning = "Seed/input cost unavailable \u{2014} cost per unit not configured."
        } else if missing > 0 {
            warning = "Some seed/input lines are missing a cost per unit."
        } else if !anyPriced {
            // No usage entered yet — keep parity with the legacy message.
            warning = "Seed/input cost unavailable \u{2014} cost per kg not configured."
        } else {
            warning = nil
        }
        return SeedingBreakdown(cost: total, missingCount: missing, warning: warning)
    }

    /// Resolve the amount used on this mix line. Prefers the explicit
    /// `amountUsed` snapshot; falls back to `kgPerHa \u{00d7} paddockHectares`
    /// where both are known. Returns 0 when nothing usable is available.
    private static func resolveLineAmount(_ line: SeedingMixLine, paddockHectares: Double?) -> Double {
        if let a = line.amountUsed, a > 0 { return a }
        if let kg = line.kgPerHa, kg > 0, let ha = paddockHectares, ha > 0 {
            return kg * ha
        }
        return 0
    }

    /// Resolve `costPerUnit` for a seeding/spreading mix line. Snapshot on
    /// the line wins, then catalog by id, then catalog by name.
    static func resolveSeedingCostPerUnit(_ line: SeedingMixLine, savedInputs: [SavedInput]) -> Double? {
        if let cpu = line.costPerUnit, cpu > 0 { return cpu }
        if let sid = line.savedInputId,
           let match = savedInputs.first(where: { $0.id == sid }),
           let cpu = match.costPerUnit, cpu > 0 {
            return cpu
        }
        let key = (line.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !key.isEmpty,
           let match = savedInputs.first(where: {
               $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
           }),
           let cpu = match.costPerUnit, cpu > 0 {
            return cpu
        }
        return nil
    }

    // MARK: - Helpers

    /// Resolve `costPerUnit` for a spray chemical line. Prefers the snapshot
    /// stored on the line, falls back to `SavedChemical.purchase` resolved by
    /// `savedChemicalId` then by case-insensitive name. Returns `nil` when no
    /// usable cost is available.
    static func resolveCostPerUnit(_ chem: SprayChemical, savedChemicals: [SavedChemical]) -> Double? {
        if chem.costPerUnit > 0 { return chem.costPerUnit }
        if let sid = chem.savedChemicalId,
           let saved = savedChemicals.first(where: { $0.id == sid }),
           let purchase = saved.purchase, purchase.costPerBaseUnit > 0 {
            return purchase.costPerBaseUnit
        }
        let key = chem.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !key.isEmpty,
           let saved = savedChemicals.first(where: {
               $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
           }),
           let purchase = saved.purchase, purchase.costPerBaseUnit > 0 {
            return purchase.costPerBaseUnit
        }
        return nil
    }

    /// Weighted average fuel cost per litre across all fuel purchases for a
    /// vineyard: `sum(total_cost) / sum(volume_litres)`. Returns nil when no
    /// purchases with a positive volume exist.
    static func weightedFuelCostPerLitre(_ purchases: [FuelPurchase]) -> Double? {
        let totalCost = purchases.reduce(0) { $0 + $1.totalCost }
        let totalVolume = purchases.reduce(0) { $0 + $1.volumeLitres }
        guard totalVolume > 0 else { return nil }
        return totalCost / totalVolume
    }
}
