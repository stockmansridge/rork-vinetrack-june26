package com.rork.vinetrack.data

/** Cost-only normalization; never changes dosage, persisted quantities or tank actuals. */
internal object ChemicalSprayDefaultUnit {
    fun isLarge(unit: String): Boolean = unit.trim().lowercase() in setOf("l", "litres", "liters", "kg", "kilograms")
}
