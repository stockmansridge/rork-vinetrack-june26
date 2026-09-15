package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.mapalignment.MapAlignmentAccess
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/**
 * System Admin preview of the unfinished Android Map Alignment feature.
 *
 * Renders nothing but an explanation — there is no alignment to configure yet,
 * nothing is persisted and no map is touched.
 *
 * ## Navigation-layer guard
 *
 * The Settings entry is hidden for non-admins, but hiding is never the boundary.
 * This screen re-resolves [MapAlignmentAccess] itself so a stale saved
 * navigation state, a process-death restore or any other internal route cannot
 * surface it to a non-System-Admin. This mirrors `AdminDashboardScreen`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MapAlignmentPreviewScreen(
    state: AppUiState,
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
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            VineyardCard {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Text(
                        "Android Map Alignment",
                        fontSize = 18.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textPrimary,
                    )
                    Text(
                        "System Admin Preview",
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium,
                        color = VineColors.Orange,
                    )
                    Text(
                        "This tool will allow an Android satellite map to be aligned with " +
                            "VineTrack's canonical vineyard coordinates without changing the " +
                            "underlying GPS data.",
                        fontSize = 14.sp,
                        color = vine.textSecondary,
                    )
                    Text(
                        "Map alignment is not yet active.",
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium,
                        color = vine.textPrimary,
                    )
                }
            }
        }
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
