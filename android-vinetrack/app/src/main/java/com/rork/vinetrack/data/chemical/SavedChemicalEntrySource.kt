package com.rork.vinetrack.data.chemical

/** Evidence provenance for Saved Chemicals, independent of the search UI version. */
object SavedChemicalEntrySource {
    fun reviewed(isManual: Boolean, isMaster: Boolean, intelligence: ChemicalIntelligence): String = when {
        isManual -> "customer_entered"
        isMaster -> "master_catalogue"
        intelligence.hasEvidencedRegistration -> "register_lookup"
        else -> "label_lookup"
    }

    /** Repairs only obsolete V2 values; preserves other historical values as-is. */
    fun repaired(source: String?, intelligence: ChemicalIntelligence?): String? = when (source) {
        "manual_v2" -> "customer_entered"
        "master_catalogue_v2" -> "master_catalogue"
        "label_lookup_v2" -> if (intelligence?.hasEvidencedRegistration == true) "register_lookup" else "label_lookup"
        else -> source
    }
}
