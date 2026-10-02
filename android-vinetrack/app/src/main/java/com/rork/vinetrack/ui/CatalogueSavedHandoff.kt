package com.rork.vinetrack.ui

import com.rork.vinetrack.data.model.SavedChemical

/** Identity-only collection merge. All open Spray/Trip/calculator state stays untouched. */
object CatalogueSavedHandoff {
    fun applying(state: AppUiState, saved: SavedChemical): AppUiState =
        state.copy(savedChemicals = state.savedChemicals.filterNot { it.id == saved.id } + saved)
}
