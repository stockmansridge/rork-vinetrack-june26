import Foundation

enum SprayCalculator {
    static func calculate(
        selectedPaddocks: [Paddock],
        waterRateLitresPerHectare: Double,
        tankCapacity: Double,
        chemicalLines: [ChemicalLine],
        chemicals: [SavedChemical],
        concentrationFactor: Double = 1.0,
        operationType: OperationType = .foliarSpray,
        tractor: Tractor? = nil,
        jobDurationHours: Double = 0,
        fuelCostPerLitre: Double = 0
    ) -> SprayCalculationResult {
        let totalArea = selectedPaddocks.reduce(0) { $0 + $1.areaHectares }
        let totalWaterLitres = totalArea * waterRateLitresPerHectare

        let numberOfTanks = totalWaterLitres > 0 ? Int(ceil(totalWaterLitres / tankCapacity)) : 0
        let fullTankCount = totalWaterLitres > tankCapacity ? numberOfTanks - 1 : 0
        let lastTankLitres: Double
        if totalWaterLitres <= 0 {
            lastTankLitres = 0
        } else if totalWaterLitres <= tankCapacity {
            lastTankLitres = totalWaterLitres
        } else {
            lastTankLitres = totalWaterLitres - (Double(fullTankCount) * tankCapacity)
        }

        let chemicalResults: [ChemicalCalculationResult] = chemicalLines.compactMap { line in
            guard let chemical = chemicals.first(where: { $0.id == line.chemicalId }),
                  let rate = chemical.rates.first(where: { $0.id == line.selectedRateId }) else {
                return nil
            }

            // Respect a manual override (entered in the chemical's display
            // unit). Convert to the base unit used by all downstream calcs.
            let selectedRate: Double = {
                if let override = line.overrideRate, override > 0 {
                    return chemical.unit.toBase(override)
                }
                return rate.value
            }()
            let totalAmountRequired: Double
            switch operationType {
            case .foliarSpray:
                switch line.basis {
                case .perHectare:
                    totalAmountRequired = selectedRate * totalArea
                case .per100Litres:
                    let numberOf100LUnits = totalWaterLitres / 100.0
                    totalAmountRequired = numberOf100LUnits * selectedRate * concentrationFactor
                }
            case .bandedSpray, .spreader:
                totalAmountRequired = selectedRate * totalArea
            }

            let amountPerFullTank: Double
            if numberOfTanks > 0 {
                amountPerFullTank = totalAmountRequired * (tankCapacity / totalWaterLitres)
            } else {
                amountPerFullTank = 0
            }

            let amountInLastTank: Double
            if lastTankLitres > 0, totalWaterLitres > 0 {
                amountInLastTank = totalAmountRequired * (lastTankLitres / totalWaterLitres)
            } else if numberOfTanks == 1 {
                amountInLastTank = totalAmountRequired
            } else {
                amountInLastTank = 0
            }

            let paddockBreakdown = selectedPaddocks.map { paddock in
                let share = totalArea > 0 ? paddock.areaHectares / totalArea : 0
                return PaddockChemicalBreakdown(
                    paddockName: paddock.name,
                    areaHectares: paddock.areaHectares,
                    amountRequired: totalAmountRequired * share
                )
            }

            let purchaseCostPerBaseUnit: Double? = {
                guard let purchase = chemical.purchase, purchase.costPerBaseUnit > 0 else { return nil }
                return purchase.costPerBaseUnit
            }()

            return ChemicalCalculationResult(
                chemicalName: chemical.name,
                unit: chemical.unit,
                selectedRate: selectedRate,
                basis: line.basis,
                totalAmountRequired: totalAmountRequired,
                amountPerFullTank: amountPerFullTank,
                amountInLastTank: amountInLastTank,
                paddockBreakdown: paddockBreakdown,
                savedChemicalId: chemical.id,
                costPerBaseUnit: purchaseCostPerBaseUnit
            )
        }

        let chemicalCosts: [ChemicalCostResult] = chemicalResults.compactMap { result in
            guard let chemical = chemicals.first(where: { $0.name == result.chemicalName }),
                  let purchase = chemical.purchase,
                  purchase.costPerBaseUnit > 0 else { return nil }

            let totalCost = result.totalAmountRequired * purchase.costPerBaseUnit
            let costPerHa = totalArea > 0 ? totalCost / totalArea : 0

            return ChemicalCostResult(
                chemicalName: result.chemicalName,
                totalAmountBase: result.totalAmountRequired,
                costPerBaseUnit: purchase.costPerBaseUnit,
                totalCost: totalCost,
                costPerHectare: costPerHa,
                unit: result.unit
            )
        }

        let fuelCostResult: FuelCostResult?
        if let tractor, jobDurationHours > 0, fuelCostPerLitre > 0 {
            let totalFuelLitres = tractor.fuelUsageLPerHour * jobDurationHours
            let totalFuelCost = totalFuelLitres * fuelCostPerLitre
            fuelCostResult = FuelCostResult(
                tractorName: tractor.displayName,
                fuelUsageLPerHour: tractor.fuelUsageLPerHour,
                jobDurationHours: jobDurationHours,
                fuelCostPerLitre: fuelCostPerLitre,
                totalFuelLitres: totalFuelLitres,
                totalFuelCost: totalFuelCost,
                fuelCostPerHectare: totalArea > 0 ? totalFuelCost / totalArea : 0
            )
        } else {
            fuelCostResult = nil
        }

        let costingSummary: SprayCostingSummary?
        let totalChemCost = chemicalCosts.reduce(0) { $0 + $1.totalCost }
        let totalFuelCostValue = fuelCostResult?.totalFuelCost ?? 0
        if !chemicalCosts.isEmpty || fuelCostResult != nil {
            let grand = totalChemCost + totalFuelCostValue
            costingSummary = SprayCostingSummary(
                chemicalCosts: chemicalCosts,
                totalChemicalCost: totalChemCost,
                totalCostPerHectare: totalArea > 0 ? totalChemCost / totalArea : 0,
                totalAreaHectares: totalArea,
                fuelCost: fuelCostResult,
                grandTotal: grand,
                grandTotalPerHectare: totalArea > 0 ? grand / totalArea : 0
            )
        } else {
            costingSummary = nil
        }

        return SprayCalculationResult(
            totalAreaHectares: totalArea,
            totalWaterLitres: totalWaterLitres,
            tankCapacityLitres: tankCapacity,
            fullTankCount: fullTankCount,
            lastTankLitres: lastTankLitres,
            chemicalResults: chemicalResults,
            concentrationFactor: concentrationFactor,
            costingSummary: costingSummary
        )
    }
}
