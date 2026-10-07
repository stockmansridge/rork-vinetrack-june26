package com.rork.vinetrack.data

/** Immutable editor seed: untouched text returns the exact canonical value, not its rounded display. */
data class RegionalInput(val canonical: Double?, val text: String) {
    fun resolve(editedText: String, inverse: (Double) -> Double): Double? {
        if (editedText == text) return canonical
        return editedText.trim().replace(',', '.').toDoubleOrNull()
            ?.takeIf { it.isFinite() }?.let(inverse)?.takeIf { it.isFinite() }
    }

    companion object {
        fun seed(canonical: Double?, forward: (Double) -> Double): RegionalInput =
            RegionalInput(canonical, canonical?.let { forward(it).toString() } ?: "")
    }
}
