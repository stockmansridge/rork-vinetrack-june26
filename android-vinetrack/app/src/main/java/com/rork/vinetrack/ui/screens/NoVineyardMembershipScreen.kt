package com.rork.vinetrack.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Logout
import androidx.compose.material.icons.filled.MailOutline
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.model.Invitation
import com.rork.vinetrack.ui.theme.VineColors

/**
 * First-login onboarding shown when a signed-in user has no vineyard
 * memberships yet. Parity with the iOS `BackendVineyardListView.emptyState` +
 * `WaitingForInviteView`: create a vineyard in-app, check for invites (with
 * inline accept/decline), or sign out — never a dead end.
 */
@Composable
fun NoVineyardMembershipScreen(
    onCreateVineyard: (name: String, country: String?, onResult: (Boolean, String?) -> Unit) -> Unit,
    onCheckForAccess: (onResult: (foundVineyards: Boolean, pendingInvitations: List<Invitation>, errorMessage: String?) -> Unit) -> Unit,
    onAcceptInvitation: (Invitation, onResult: (Boolean, String?) -> Unit) -> Unit,
    onDeclineInvitation: (Invitation, onResult: (Boolean) -> Unit) -> Unit,
    onSignOut: () -> Unit,
) {
    var isWaitingMode by remember { mutableStateOf(false) }
    var showCreateDialog by remember { mutableStateOf(false) }
    var showSignOutConfirm by remember { mutableStateOf(false) }
    var isChecking by remember { mutableStateOf(false) }
    var statusMessage by remember { mutableStateOf<String?>(null) }
    var invitations by remember { mutableStateOf<List<Invitation>>(emptyList()) }
    var processingInvitationId by remember { mutableStateOf<String?>(null) }

    // Silent initial check so an invite sent before login shows up without a tap.
    LaunchedEffect(Unit) {
        onCheckForAccess { _, invites, _ -> invitations = invites }
    }

    // Back from the waiting sub-screen returns to the welcome layout (parity
    // with the iOS navigation push/pop).
    BackHandler(enabled = isWaitingMode) { isWaitingMode = false }

    fun runCheck() {
        if (isChecking) return
        isChecking = true
        statusMessage = null
        onCheckForAccess { found, invites, error ->
            isChecking = false
            if (found) return@onCheckForAccess // loadVineyards routes into Main.
            invitations = invites
            statusMessage = when {
                error != null -> error
                invites.isNotEmpty() ->
                    "${invites.size} pending invitation${if (invites.size == 1) "" else "s"} found. Accept below to join."
                else -> "No vineyard access found yet. Ask your manager to send or confirm your invite."
            }
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(VineColors.AppBackgroundLight)
            .systemBarsPadding(),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Spacer(Modifier.height(24.dp))

            // Icon badge
            Box(
                modifier = Modifier
                    .size(96.dp)
                    .background(VineColors.LeafGreen.copy(alpha = 0.12f), CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = if (isWaitingMode) Icons.Filled.MailOutline else Icons.Filled.Spa,
                    contentDescription = null,
                    tint = VineColors.LeafGreen,
                    modifier = Modifier.size(44.dp),
                )
            }

            Text(
                text = if (isWaitingMode) "Waiting for Vineyard Invite" else "Welcome to VineTrack",
                fontSize = 22.sp,
                fontWeight = FontWeight.SemiBold,
                color = VineColors.TextPrimaryLight,
                textAlign = TextAlign.Center,
            )
            Text(
                text = if (isWaitingMode) {
                    "You don\u2019t currently have access to any vineyards. If your manager has invited you, your vineyard will appear here after the invite is accepted and the app syncs."
                } else {
                    "You don\u2019t currently have access to any vineyards. You can create a vineyard if you are an owner or manager, or wait for an invite if you are joining an existing team."
                },
                fontSize = 15.sp,
                color = VineColors.TextSecondaryLight,
                textAlign = TextAlign.Center,
                lineHeight = 21.sp,
                modifier = Modifier.padding(horizontal = 4.dp),
            )

            // Pending invitations — Android shows accept/decline inline (the
            // equivalent of the iOS vineyard-list invitation rows).
            if (invitations.isNotEmpty()) {
                Spacer(Modifier.height(4.dp))
                invitations.forEach { invitation ->
                    InvitationCard(
                        invitation = invitation,
                        isProcessing = processingInvitationId == invitation.id,
                        onAccept = {
                            processingInvitationId = invitation.id
                            statusMessage = null
                            onAcceptInvitation(invitation) { ok, error ->
                                processingInvitationId = null
                                if (!ok && error != null) statusMessage = error
                            }
                        },
                        onDecline = {
                            processingInvitationId = invitation.id
                            onDeclineInvitation(invitation) { ok ->
                                processingInvitationId = null
                                if (ok) invitations = invitations.filterNot { it.id == invitation.id }
                            }
                        },
                    )
                }
            }

            Spacer(Modifier.height(8.dp))

            if (isWaitingMode) {
                Button(
                    onClick = { runCheck() },
                    enabled = !isChecking,
                    modifier = Modifier.fillMaxWidth().height(50.dp),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen),
                ) {
                    if (isChecking) {
                        CircularProgressIndicator(
                            color = Color.White,
                            strokeWidth = 2.dp,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.size(8.dp))
                        Text("Checking\u2026", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                    } else {
                        Icon(Icons.Filled.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.size(8.dp))
                        Text("Check for Invites", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
                OutlinedButton(
                    onClick = { showCreateDialog = true },
                    modifier = Modifier.fillMaxWidth().height(50.dp),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = VineColors.LeafGreen),
                ) {
                    Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(8.dp))
                    Text("Create a Vineyard", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                }
            } else {
                Button(
                    onClick = { showCreateDialog = true },
                    modifier = Modifier.fillMaxWidth().height(50.dp),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen),
                ) {
                    Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(8.dp))
                    Text("Create a Vineyard", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                }
                OutlinedButton(
                    onClick = {
                        isWaitingMode = true
                        statusMessage = null
                        runCheck()
                    },
                    modifier = Modifier.fillMaxWidth().height(50.dp),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = VineColors.LeafGreen),
                ) {
                    Icon(Icons.Filled.MailOutline, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(8.dp))
                    Text("I\u2019m waiting for an invite", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                }
            }

            statusMessage?.let { message ->
                Text(
                    text = message,
                    fontSize = 13.sp,
                    color = VineColors.TextSecondaryLight,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                )
            }

            Spacer(Modifier.weight(1f))

            TextButton(onClick = { showSignOutConfirm = true }) {
                Icon(
                    Icons.Filled.Logout,
                    contentDescription = null,
                    tint = VineColors.TextSecondaryLight,
                    modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.size(6.dp))
                Text("Sign out", color = VineColors.TextSecondaryLight)
            }
        }
    }

    if (showCreateDialog) {
        CreateVineyardDialog(
            onDismiss = { showCreateDialog = false },
            onCreate = onCreateVineyard,
        )
    }

    if (showSignOutConfirm) {
        AlertDialog(
            onDismissRequest = { showSignOutConfirm = false },
            title = { Text("Sign out of VineTrack?") },
            text = { Text("You can sign back in any time with the correct account.") },
            confirmButton = {
                TextButton(onClick = {
                    showSignOutConfirm = false
                    onSignOut()
                }) { Text("Sign Out", color = VineColors.Destructive) }
            },
            dismissButton = {
                TextButton(onClick = { showSignOutConfirm = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun InvitationCard(
    invitation: Invitation,
    isProcessing: Boolean,
    onAccept: () -> Unit,
    onDecline: () -> Unit,
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(containerColor = VineColors.CardBackgroundLight),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(
                    modifier = Modifier
                        .size(36.dp)
                        .background(VineColors.LeafGreen, CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Filled.MailOutline,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(18.dp),
                    )
                }
                Column(Modifier.weight(1f)) {
                    Text(
                        invitation.vineyardName ?: "Vineyard invitation",
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 15.sp,
                        color = VineColors.TextPrimaryLight,
                        maxLines = 1,
                    )
                    Text(
                        "Invited as ${invitation.email}",
                        fontSize = 12.sp,
                        color = VineColors.TextSecondaryLight,
                        maxLines = 1,
                    )
                }
                Text(
                    invitation.role.replaceFirstChar { it.uppercase() },
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = VineColors.LeafGreen,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                    onClick = onAccept,
                    enabled = !isProcessing,
                    modifier = Modifier.weight(1f).height(40.dp),
                    shape = RoundedCornerShape(20.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen),
                ) {
                    if (isProcessing) {
                        CircularProgressIndicator(
                            color = Color.White,
                            strokeWidth = 2.dp,
                            modifier = Modifier.size(14.dp),
                        )
                    } else {
                        Icon(Icons.Filled.CheckCircle, contentDescription = null, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.size(6.dp))
                        Text("Accept", fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
                OutlinedButton(
                    onClick = onDecline,
                    enabled = !isProcessing,
                    modifier = Modifier.weight(1f).height(40.dp),
                    shape = RoundedCornerShape(20.dp),
                ) {
                    Text(
                        "Decline",
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = VineColors.TextPrimaryLight,
                    )
                }
            }
        }
    }
}

/**
 * Create-vineyard form — mirrors the iOS `EditVineyardSheet` (name + optional
 * country picker, backed by the same `create_vineyard_with_owner` RPC).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CreateVineyardDialog(
    onDismiss: () -> Unit,
    onCreate: (name: String, country: String?, onResult: (Boolean, String?) -> Unit) -> Unit,
) {
    var name by remember { mutableStateOf("") }
    var country by remember { mutableStateOf("") }
    var countryExpanded by remember { mutableStateOf(false) }
    var isSaving by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    // Same wine-country list as the iOS EditVineyardSheet.
    val wineCountries = remember {
        listOf(
            "Australia", "Argentina", "Austria", "Brazil", "Canada", "Chile", "China",
            "France", "Germany", "Greece", "Hungary", "India", "Israel", "Italy",
            "Japan", "Mexico", "New Zealand", "Portugal", "Romania", "South Africa",
            "Spain", "Switzerland", "United Kingdom", "United States", "Uruguay",
        )
    }

    AlertDialog(
        onDismissRequest = { if (!isSaving) onDismiss() },
        title = { Text("New Vineyard") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Vineyard Name") },
                    placeholder = { Text("e.g. Barossa Valley Estate") },
                    singleLine = true,
                    enabled = !isSaving,
                    modifier = Modifier.fillMaxWidth(),
                )
                ExposedDropdownMenuBox(
                    expanded = countryExpanded,
                    onExpandedChange = { if (!isSaving) countryExpanded = it },
                ) {
                    OutlinedTextField(
                        value = country.ifEmpty { "Not Set" },
                        onValueChange = {},
                        readOnly = true,
                        label = { Text("Country") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = countryExpanded) },
                        enabled = !isSaving,
                        modifier = Modifier
                            .fillMaxWidth()
                            .menuAnchor(MenuAnchorType.PrimaryNotEditable, enabled = !isSaving),
                    )
                    ExposedDropdownMenu(
                        expanded = countryExpanded,
                        onDismissRequest = { countryExpanded = false },
                    ) {
                        DropdownMenuItem(
                            text = { Text("Not Set") },
                            onClick = {
                                country = ""
                                countryExpanded = false
                            },
                        )
                        wineCountries.forEach { c ->
                            DropdownMenuItem(
                                text = { Text(c) },
                                onClick = {
                                    country = c
                                    countryExpanded = false
                                },
                            )
                        }
                    }
                }
                errorMessage?.let {
                    Text(it, color = VineColors.Destructive, fontSize = 12.sp)
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    val trimmed = name.trim()
                    if (trimmed.isEmpty()) return@TextButton
                    isSaving = true
                    errorMessage = null
                    onCreate(trimmed, country.ifBlank { null }) { ok, error ->
                        isSaving = false
                        if (ok) onDismiss() else errorMessage =
                            error ?: "Couldn't create the vineyard. Please try again."
                    }
                },
                enabled = !isSaving && name.trim().isNotEmpty(),
            ) {
                if (isSaving) {
                    CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
                } else {
                    Text("Create", color = VineColors.LeafGreen, fontWeight = FontWeight.SemiBold)
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = !isSaving) { Text("Cancel") }
        },
    )
}
