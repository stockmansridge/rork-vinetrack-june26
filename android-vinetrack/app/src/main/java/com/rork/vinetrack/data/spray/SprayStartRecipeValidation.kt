package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.model.SprayTank

/** New operational admission only; historical sync and recorded actuals are unchanged. */
object SprayStartRecipeValidation {
    fun blocker(tanks: List<SprayTank>): String? {
        if (tanks.isEmpty()) return "A validated tank mix is required before starting a spray."
        for (tank in tanks) {
            if (!tank.waterVolume.isFinite() || tank.waterVolume <= 0 || tank.chemicals.isEmpty())
                return "Confirm positive water and at least one product in every planned tank."
            for (chemical in tank.chemicals) {
                val basis = SprayProductRateBasis.legacy(chemical.rateBasis)
                val rate = if (basis == SprayProductRateBasis.PER_100_LITRES ||
                    (chemical.rateBasis == null && chemical.ratePerHa <= 0 && chemical.ratePer100L > 0)) chemical.ratePer100L else chemical.ratePerHa
                if ((!chemical.rateBasis.isNullOrBlank() && basis == null) || !rate.isFinite() || rate <= 0 ||
                    !chemical.volumePerTank.isFinite() || chemical.volumePerTank <= 0)
                    return "Confirm a valid positive chemical rate and quantity for ${chemical.name} before starting."
            }
        }
        return SprayPlanningOperationalGate.blocker(null, tanks)
    }
}
