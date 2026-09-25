package com.rork.vinetrack.data.chemical

/** One policy for every Add New Chemical entry point. Missing/unloaded flag defaults to V2;
 * explicit OFF is the emergency rollback to the retained V1 creator. */
object ChemicalCreationRouting {
    fun usesV2(flags: Map<String, Boolean>): Boolean = flags["chemical_search_v2"] != false
}
