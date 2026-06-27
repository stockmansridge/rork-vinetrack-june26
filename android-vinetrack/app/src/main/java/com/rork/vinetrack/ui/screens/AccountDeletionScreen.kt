package com.rork.vinetrack.ui.screens

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Grass
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PersonRemove
import androidx.compose.material.icons.filled.Report
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.AccountDeletionPreflight
import com.rork.vinetrack.data.OwnedVineyard
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch

private const val SUPPORT_EMAIL = "jonathan@stockmansridge.com.au"

/**
 * Account-deletion flow, mirroring the iOS `AccountDeletionRequestView`. Runs a
 * preflight that checks for shared vineyards the user owns; if any require
 * ownership transfer the user is directed to email support, otherwise they can
 * submit a deletion request for manual review.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountDeletionScreen(
    vm: AppViewModel,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var preflight by remember { mutableStateOf<AccountDeletionPreflight?>(null) }
    var isLoading by remember { mutableStateOf(false) }
    var isSubmitting by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var submissionMessage by remember { mutableStateOf<String?>(null) }
    var showConfirm by remember { mutableStateOf(false) }

    fun runPreflight() {
        isLoading = true
        errorMessage = null
        scope.launch {
            runCatching { vm.accountDeletionPreflight() }
                .onSuccess { preflight = it }
                .onFailure { errorMessage = it.message }
            isLoading = false
        }
    }

    LaunchedEffect(Unit) { runPreflight() }

    val blocking = preflight?.ownedVineyards?.filter { it.transferRequired }.orEmpty()
    val solo = preflight?.ownedVineyards?.filter { !it.transferRequired }.orEmpty()

    if (showConfirm) {
        AlertDialog(
            onDismissRequest = { showConfirm = false },
            title = { Text("Delete account?") },
            text = {
                Text(
                    "This submits a deletion request to support. Your account will be removed after manual review. This cannot be undone.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    showConfirm = false
                    isSubmitting = true
                    scope.launch {
                        runCatching { vm.submitAccountDeletionRequest() }
                            .onSuccess { res ->
                                if (res.submitted) {
                                    submissionMessage = "Deletion request submitted. Support will follow up via email."
                                } else {
                                    errorMessage = res.message ?: "Could not submit request."
                                    runPreflight()
                                }
                            }
                            .onFailure { errorMessage = it.message }
                        isSubmitting = false
                    }
                }) { Text("Submit Request", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { showConfirm = false }) { Text("Cancel") } },
        )
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Delete Account") },
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
            // Header
            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Icon(Icons.Filled.PersonRemove, contentDescription = null, tint = VineColors.Destructive)
                        Text("Delete Account", fontWeight = FontWeight.SemiBold, fontSize = 17.sp, color = vine.textPrimary)
                    }
                    Text(
                        "Account deletion is irreversible. Before deleting, transfer ownership of any shared vineyards so other members keep their access.",
                        fontSize = 14.sp,
                        color = vine.textSecondary,
                    )
                }
            }

            if (isLoading) {
                VineyardCard {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                        Text("Checking shared vineyards…", fontSize = 14.sp, color = vine.textSecondary)
                    }
                }
            }

            errorMessage?.let { msg ->
                VineyardCard {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Icon(Icons.Filled.WarningAmber, contentDescription = null, tint = VineColors.Destructive)
                        Text(msg, fontSize = 13.sp, color = VineColors.Destructive)
                    }
                }
            }

            // Transfer-required blocker
            if (blocking.isNotEmpty()) {
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Icon(Icons.Filled.Report, contentDescription = null, tint = VineColors.Destructive)
                            Text("Transfer Ownership Required", fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                        }
                        Text(
                            "You own vineyards that other people use. Transfer ownership before deleting your account.",
                            fontSize = 14.sp,
                            color = vine.textSecondary,
                        )
                        blocking.forEach { v -> BlockingVineyardRow(v) }
                        Text(
                            "Open Settings → Vineyard → Team & Access on each vineyard to transfer ownership.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
            }

            // Solo vineyards
            if (solo.isNotEmpty()) {
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Icon(Icons.Filled.Info, contentDescription = null, tint = VineColors.Info)
                            Text("Solo Vineyards", fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                        }
                        Text(
                            "These vineyards have no other members. They will be archived along with your account:",
                            fontSize = 14.sp,
                            color = vine.textSecondary,
                        )
                        solo.forEach { v ->
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                Icon(Icons.Filled.Grass, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(18.dp))
                                Text(v.vineyardName, fontSize = 14.sp, color = vine.textPrimary)
                            }
                        }
                    }
                }
            }

            // Account info
            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("Your account", fontWeight = FontWeight.SemiBold, fontSize = 13.sp, color = vine.textSecondary)
                    AccountInfoRow(Icons.Filled.Person, VineColors.Stone, "Name", vm.userName ?: "—")
                    AccountInfoRow(Icons.Filled.Email, VineColors.Info, "Email", vm.userEmail ?: "—")
                }
            }

            submissionMessage?.let { msg ->
                VineyardCard {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = VineColors.Success)
                        Text(msg, fontSize = 13.sp, color = VineColors.Success)
                    }
                }
            }

            // Action button
            val current = preflight
            if (blocking.isNotEmpty()) {
                ActionButton("Email Support", VineColors.Info, Icons.Filled.Email, enabled = !isSubmitting) {
                    val intent = Intent(Intent.ACTION_SENDTO).apply {
                        data = Uri.parse("mailto:$SUPPORT_EMAIL")
                        putExtra(Intent.EXTRA_SUBJECT, "VineTrack account deletion request")
                        putExtra(
                            Intent.EXTRA_TEXT,
                            "Please delete my VineTrack account.\n\nName: ${vm.userName ?: "—"}\nEmail: ${vm.userEmail ?: "—"}",
                        )
                    }
                    runCatching { context.startActivity(intent) }
                }
            } else if (current?.safeToDelete == true) {
                ActionButton("Request Account Deletion", VineColors.Destructive, Icons.Filled.PersonRemove, enabled = !isSubmitting, loading = isSubmitting) {
                    showConfirm = true
                }
            }

            Text(
                "Support: $SUPPORT_EMAIL",
                fontSize = 12.sp,
                color = vine.textSecondary,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun BlockingVineyardRow(v: OwnedVineyard) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(vine.appBackground)
            .padding(10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(Icons.Filled.Grass, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(18.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(v.vineyardName, fontWeight = FontWeight.Medium, fontSize = 14.sp, color = vine.textPrimary)
            val n = v.otherActiveMembers
            Text("$n other member${if (n == 1) "" else "s"}", fontSize = 12.sp, color = vine.textSecondary)
        }
    }
}

@Composable
private fun AccountInfoRow(icon: ImageVector, tint: Color, label: String, value: String) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
        Text(label, fontSize = 14.sp, color = vine.textSecondary, modifier = Modifier.weight(1f))
        Text(value, fontSize = 14.sp, color = vine.textPrimary, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun ActionButton(
    label: String,
    color: Color,
    icon: ImageVector,
    enabled: Boolean,
    loading: Boolean = false,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(if (enabled) color else VineColors.Stone)
            .let { m -> if (enabled) m.clickable { onClick() } else m },
        contentAlignment = Alignment.Center,
    ) {
        if (loading) {
            CircularProgressIndicator(modifier = Modifier.padding(14.dp).size(22.dp), color = Color.White, strokeWidth = 2.dp)
        } else {
            Row(
                modifier = Modifier.padding(vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
                Text(label, color = Color.White, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}
