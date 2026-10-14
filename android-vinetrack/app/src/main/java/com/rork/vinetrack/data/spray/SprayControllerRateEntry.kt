package com.rork.vinetrack.data.spray

/** Boundary conversion only; chemical engines and physical dilute references remain unchanged. */
object SprayControllerRateEntry {
    fun parse(text: String): Double? = com.rork.vinetrack.data.RegionalInput.seed(null) { it }.resolve(text) { it }

    fun canonical(value: Double?, basis: SprayCarrierBasis, configuration: SprayPassConfiguration?, spacing: Double?): Double? {
        if (value == null || !value.isFinite() || value <= 0) return null
        if (basis == SprayCarrierBasis.LITRES_PER_HECTARE) return value
        if (basis != SprayCarrierBasis.LITRES_PER_100_METRES || spacing == null || !spacing.isFinite() || spacing <= 0) return null
        return value * 100 / (spacing * (configuration?.rowEquivalents ?: 1.0))
    }

    fun displayed(canonical: Double?, basis: SprayCarrierBasis, configuration: SprayPassConfiguration?, spacing: Double?): Double? {
        if (canonical == null || !canonical.isFinite() || canonical <= 0) return null
        if (basis == SprayCarrierBasis.LITRES_PER_HECTARE) return canonical
        if (basis != SprayCarrierBasis.LITRES_PER_100_METRES || spacing == null || !spacing.isFinite() || spacing <= 0) return null
        return canonical * spacing * (configuration?.rowEquivalents ?: 1.0) / 100
    }
}
