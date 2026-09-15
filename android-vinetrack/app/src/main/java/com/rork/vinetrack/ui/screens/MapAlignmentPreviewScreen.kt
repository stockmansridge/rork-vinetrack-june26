package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ShieldMoon
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.PinLocationResult
import com.rork.vinetrack.data.mapalignment.MapAlignmentAccess
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.theme.LocalVineColors

/**
 * System Admin host for the Android Map Alignment onsite calibration wizard.
 *
 * Hosts [MapAlignmentWizard], which lets a System Admin record reference points
 * onsite, derive a candidate translation and inspect it in a PRIVATE
 * before/after preview.
 *
 * ## What this phase deliberately does not do
 *
 * * No production vineyard or block map is aligned — the candidate affects only
 *   the preview inside the wizard.
 * * Nothing is persisted: no SQL, Supabase table, RPC, RLS, API endpoint, sync
 *   entity, SharedPreferences or local database write. The draft is session
 *   memory and is discarded when the wizard closes.
 * * No canonical coordinate is altered. Capture only creates new reference
 *   points; vineyard coordinates, block boundaries, rows, pins, routes and raw
 *   GPS fixes are read-only here.
 *
 * ## Navigation-layer guard
 *
 * The Settings entry is hidden for non-admins, but hiding is never the boundary.
 * This screen re-resolves [MapAlignmentAccess] itself so a stale saved
 * navigation state, a process-death restore or any other internal route cannot
 * surface it to a non-System-Admin. This mirrors `AdminDashboardScreen`.
 *
 * @param onRequestFix one-shot GPS request served by the EXISTING location
 *   pipeline (`AppViewModel.fetchCurrentFix` -> `LocationTracker` ->
 *   `PinLocationFixValidator`). Injected rather than created here so the wizard
 *   cannot start a competing location manager.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MapAlignmentPreviewScreen(
    state: AppUiState,
    onRequestFix: (onResult: (PinLocationResult) -> Unit) -> Unit,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
) {
    val access = MapAlignmentAccess.resolve(
        sessionPhase = state.sessionPhase,
        isSystemAdmin = state.isSystemAdmin,
    )
    if (!access.isAllowed) {
        MapAlignmentAccessDenied(modifier = modifier, onBack = onBack)
        return
    }

    val vine = LocalVineColors.current
    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Android Map Alignment") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        MapAlignmentWizard(
            state = state,
            onRequestFix = onRequestFix,
            modifier = Modifier.fillMaxSize().padding(padding),
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MapAlignmentAccessDenied(modifier: Modifier, onBack: (() -> Unit)?) {
    val vine = LocalVineColors.current
    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Android Map Alignment") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Box(
            modifier = Modifier.fillMaxSize().padding(padding).padding(24.dp),
            contentAlignment = Alignment.Center,
        ) {
            EmptyState(
                Icons.Filled.ShieldMoon,
                "Restricted area",
                "You are not a VineTrack platform administrator. This area is reserved for system admins.",
            )
        }
    }
}
