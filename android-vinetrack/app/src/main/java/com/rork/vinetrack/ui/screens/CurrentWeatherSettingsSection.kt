package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.CurrentObservationRepository
import com.rork.vinetrack.data.MAITSupplementarySensors
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.ui.components.SectionHeader
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** The selected server-normalized observation, never a forecast or a provider fallback. */
@Composable
internal fun CurrentWeatherSettingsSection(vineyardId: String?, session: SessionStore, repository: CurrentObservationRepository) {
    val scope = rememberCoroutineScope()
    val access = remember { session.accountAccess() }
    fun isCurrent() = access != null && session.isAccountAccessCurrent(access) && session.selectedVineyardId == vineyardId
    var current by remember { mutableStateOf<CurrentObservationRepository.CachedRow?>(null) }
    var extra by remember { mutableStateOf<MAITSupplementarySensors?>(null) }
    var feedback by remember { mutableStateOf<String?>(null) }
    var extraFeedback by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    suspend fun reload(force: Boolean) {
        val id = vineyardId ?: return
        if (!isCurrent() || busy) return
        busy = true
        try {
        try {
            val cached = repository.current(id)
            if (!isCurrent()) return
            current = CurrentObservationRepository.retainingLastKnown(cached, current)
            if (force) {
                val result = repository.refresh(id, force = true)
                if (!isCurrent()) return
                val fresh = repository.current(id)
                if (!isCurrent()) return
                current = CurrentObservationRepository.retainingLastKnown(fresh, current)
                feedback = when {
                    result == "no_newer" -> "MAIT iNTELLiWeb returned no newer reading — the station has not reported since the last update."
                    result == "not_configured" -> "No active local observation station is configured."
                    fresh == null || fresh.status != "ok" -> "No new observation returned. Last available readings are retained."
                    else -> "Selected observations refreshed."
                }
            }
        } catch (cancelled: CancellationException) { throw cancelled }
          catch (_: Exception) { if (isCurrent()) feedback = current?.refreshFailureMessage ?: "Live observations not refreshed — selected source" }
        if (!isCurrent()) return
        if (current?.source == CurrentObservationRepository.MAIT) {
            try {
                val fresh = repository.supplementary(id)
                if (!isCurrent()) return
                extra = fresh
                extraFeedback = fresh.warning
            } catch (cancelled: CancellationException) { throw cancelled }
              catch (_: Exception) { if (isCurrent()) extraFeedback = MAITSupplementarySensors.WARNING }
        } else { extra = null; extraFeedback = null }
        } finally { busy = false }
    }
    LaunchedEffect(vineyardId) { reload(false) }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeader("Current Weather", onLight = true)
        CurrentConditionsCard(current, feedback, title = "Station observations", emptyMessage = "No current station observation available. Missing metrics are not filled from another provider.")
        extra?.let { SupplementarySensorsCard(it, extraFeedback) }
        if (extra == null) extraFeedback?.let { Text(it) }
        if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        TextButton(enabled = !busy && vineyardId != null && isCurrent(), onClick = { scope.launch { reload(true) } }) {
            Text(if (busy) "Refreshing…" else "Refresh current weather")
        }
    }
}
