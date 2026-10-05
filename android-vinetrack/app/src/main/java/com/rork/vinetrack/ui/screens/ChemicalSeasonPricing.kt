package com.rork.vinetrack.ui.screens

import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.data.VintageResolver
import com.rork.vinetrack.data.chemical.CatalogueRepository
import com.rork.vinetrack.data.chemical.ChemicalSeasonPriceBatch
import com.rork.vinetrack.data.model.Trip
import kotlinx.coroutines.CancellationException

/** In-memory, role/vineyard-scoped financial batch; no persistence into sprays. */
@Composable
internal fun rememberTripChemicalPrices(state: AppUiState, trip: Trip?): ChemicalSeasonPriceBatch? {
    val context = LocalContext.current
    var batch by remember(trip?.id, state.selectedVineyardId, state.currentRole) { mutableStateOf<ChemicalSeasonPriceBatch?>(null) }
    LaunchedEffect(trip?.id, state.selectedVineyardId, state.currentRole, state.seasonStartMonth, state.seasonStartDay) {
        batch = null
        if (trip != null && trip.vineyardId == state.selectedVineyardId && state.currentRole in listOf("owner", "manager")) {
            val start = trip.startEpochMs
            if (start != null) {
                val vintage = VintageResolver.vintageYearForEpochMs(start, state.seasonStartMonth, state.seasonStartDay, state.seasonZone)
                try { batch = CatalogueRepository(context).chemicalSeasonPrices(trip.vineyardId, vintage) }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { batch = null }
            }
        }
    }
    return batch
}
