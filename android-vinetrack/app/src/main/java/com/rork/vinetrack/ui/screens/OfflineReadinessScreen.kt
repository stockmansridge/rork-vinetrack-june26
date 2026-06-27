package com.rork.vinetrack.ui.screens

import android.text.format.DateUtils
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.GppGood
import androidx.compose.material.icons.filled.GppMaybe
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/** Severity of a single readiness line. */
private enum class Readiness(val color: Color, val icon: ImageVector) {
    Good(VineColors.Success, Icons.Filled.CheckCircle),
    Warn(VineColors.Warning, Icons.Filled.Warning),
    Bad(VineColors.Destructive, Icons.Filled.Error),
}

/**
 * Read-only field-readiness checklist (parity with iOS `OfflineReadinessView`).
 * Surfaces whether this device has everything cached to keep working in a
 * vineyard with no mobile network: signed-in session, the selected vineyard,
 * its blocks, the saved chemicals/equipment catalogues, GPS permission, and the
 * current sync backlog. Purely diagnostic — it never changes access or sync
 * behaviour. The only action is a manual refresh while signal is available.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OfflineReadinessScreen(
    state: AppUiState,
    userEmail: String?,
    hasLocationPermission: Boolean,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onRefresh: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val online = state.isOnline

    val signedIn = userEmail != null
    val vineyard = state.selectedVineyard
    val paddockCount = state.paddocks.count { it.vineyardId == state.selectedVineyardId }
    val chemicalCount = state.savedChemicals.size
    val equipmentCount = if (state.selectedVineyardId != null) {
        state.equipmentItems.count { it.vineyardId == state.selectedVineyardId }
    } else {
        state.equipmentItems.size
    }
    val pending = state.pendingSyncCount
    val gps = if (hasLocationPermission) Readiness.Good else Readiness.Warn

    val fieldReady = signedIn && vineyard != null && paddockCount > 0 && hasLocationPermission

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Offline Readiness") },
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
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            // Overall banner.
            VineyardCard {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Icon(
                        if (fieldReady) Icons.Filled.GppGood else Icons.Filled.GppMaybe,
                        contentDescription = null,
                        tint = if (fieldReady) VineColors.Success else VineColors.Warning,
                        modifier = Modifier.size(38.dp),
                    )
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            if (fieldReady) "Ready for the field" else "Not fully ready",
                            fontWeight = FontWeight.Bold,
                            color = vine.textPrimary,
                            fontSize = 17.sp,
                        )
                        Text(
                            if (fieldReady) {
                                "This device has everything cached to keep working without mobile network."
                            } else {
                                "Some items below need attention while you still have signal."
                            },
                            fontSize = 13.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
            }

            // Essentials.
            SectionHeader("Essentials", onLight = true)
            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    ReadinessRow(
                        title = "Signed in",
                        detail = userEmail ?: "Not signed in",
                        state = if (signedIn) Readiness.Good else Readiness.Bad,
                    )
                    ReadinessRow(
                        title = "Vineyard downloaded",
                        detail = vineyard?.name ?: "None selected",
                        state = if (vineyard != null) Readiness.Good else Readiness.Bad,
                    )
                }
            }
            CaptionText("Your session and the selected vineyard are stored on this device, so the app opens and runs even when Supabase is unreachable.")

            // Downloaded data.
            SectionHeader("Downloaded for offline use", onLight = true)
            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    ReadinessRow(
                        title = "Blocks & rows",
                        detail = "$paddockCount block${if (paddockCount == 1) "" else "s"}",
                        state = if (paddockCount > 0) Readiness.Good else Readiness.Warn,
                    )
                    ReadinessRow(
                        title = "Saved chemicals",
                        detail = "$chemicalCount saved",
                        state = if (chemicalCount > 0) Readiness.Good else Readiness.Warn,
                    )
                    ReadinessRow(
                        title = "Equipment",
                        detail = "$equipmentCount item${if (equipmentCount == 1) "" else "s"}",
                        state = if (equipmentCount > 0) Readiness.Good else Readiness.Warn,
                    )
                }
            }
            CaptionText("These come from your last sync and are cached on disk. A warning here just means none are set up yet — it won't stop you working offline.")

            // GPS.
            SectionHeader("Location", onLight = true)
            VineyardCard {
                ReadinessRow(
                    title = "GPS permission",
                    detail = if (hasLocationPermission) "Granted" else "Not granted — enable in Settings",
                    state = gps,
                )
            }
            CaptionText("Trip tracking and pin placement work fully offline — GPS does not require a network connection. \"Always\" allows tracking to continue when the screen locks.")

            // Sync status.
            SectionHeader("Sync status", onLight = true)
            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    ReadinessRow(
                        title = if (online) "Online" else "Offline",
                        detail = if (online) "Connected — changes save to the server." else "No connection — changes are saved locally.",
                        state = if (online) Readiness.Good else Readiness.Warn,
                    )
                    ReadinessRow(
                        title = "Pending uploads",
                        detail = if (pending == 0) "All changes uploaded" else "$pending waiting to sync",
                        state = if (pending == 0) Readiness.Good else Readiness.Warn,
                    )
                    state.cacheStatus.selectedSyncedAt?.let { ts ->
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                        ) {
                            Text("Field data last saved", fontSize = 13.sp, color = vine.textSecondary)
                            Text(
                                relativeTime(ts),
                                fontSize = 13.sp,
                                color = vine.textPrimary,
                                fontWeight = FontWeight.Medium,
                            )
                        }
                    }
                }
            }
            CaptionText("Anything you create offline is saved locally and queued. It uploads automatically the next time the device has signal — nothing is lost if you stay out of range. Records awaiting retry stay saved and editable, and retry on reconnect.")

            // Refresh.
            if (onRefresh != null) {
                Button(
                    onClick = onRefresh,
                    enabled = online && signedIn && state.selectedVineyardId != null,
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.Success),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(Icons.Filled.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
                    Text(
                        "Refresh & sync now",
                        modifier = Modifier.padding(start = 8.dp),
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 14.sp,
                    )
                }
                CaptionText("Run this while you still have signal to push pending changes and pull the latest blocks, chemicals and equipment before heading out.")
            }

            CaptionText("This screen is read-only and never changes app access. Use it as a pre-trip checklist before working in no-service areas.")
        }
    }
}

@Composable
private fun ReadinessRow(title: String, detail: String, state: Readiness) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier.size(36.dp).clip(CircleShape).background(state.color.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(state.icon, contentDescription = null, tint = state.color, modifier = Modifier.size(20.dp))
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(title, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = vine.textPrimary)
            Text(detail, fontSize = 13.sp, color = vine.textSecondary)
        }
    }
}

@Composable
private fun CaptionText(text: String) {
    val vine = LocalVineColors.current
    Text(text, fontSize = 12.sp, color = vine.textSecondary)
}

/** Human-friendly relative time (e.g. "5 minutes ago") for a cache timestamp. */
private fun relativeTime(epochMillis: Long): String =
    DateUtils.getRelativeTimeSpanString(
        epochMillis,
        System.currentTimeMillis(),
        DateUtils.MINUTE_IN_MILLIS,
    ).toString()
