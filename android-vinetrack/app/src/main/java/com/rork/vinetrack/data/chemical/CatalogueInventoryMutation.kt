package com.rork.vinetrack.data.chemical

object CatalogueInventoryMutation {
    val operations = setOf("chemical_inventory_record_purchase", "chemical_inventory_record_stocktake", "chemical_inventory_mark_finished", "chemical_inventory_set_settings")
    suspend fun perform(systemAdmin: Boolean, operation: String, chemicalId: String,
        mutate: suspend () -> Unit, refresh: suspend (String) -> Unit) {
        check(systemAdmin && operation in operations)
        mutate()
        refresh(chemicalId)
    }
}
