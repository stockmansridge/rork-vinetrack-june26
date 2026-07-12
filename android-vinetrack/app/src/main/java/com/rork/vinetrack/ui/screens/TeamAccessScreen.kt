package com.rork.vinetrack.ui.screens

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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PersonAddAlt
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material.icons.filled.WorkspacePremium
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.model.OperatorCategory
import com.rork.vinetrack.data.model.TeamRole
import com.rork.vinetrack.data.model.VineyardMember
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/**
 * Team & Access management, mirroring the iOS `BackendTeamAccessView`. Lists
 * members and pending invitations; owners/managers can invite, change roles &
 * operator categories, remove members, and (owners only) transfer ownership.
 * All writes are enforced server-side via RLS / SECURITY DEFINER RPCs.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TeamAccessScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
    onOpenTool: (com.rork.vinetrack.ui.main.ToolRoute) -> Unit,
) {
    val vine = LocalVineColors.current
    val role = TeamRole.from(state.currentRole)
    val canManage = role.canManageTeam
    val isOwner = role == TeamRole.Owner

    LaunchedEffect(state.selectedVineyardId) { vm.loadPendingInvitations() }

    var showInvite by remember { mutableStateOf(false) }
    var editMember by remember { mutableStateOf<VineyardMember?>(null) }
    var showTransfer by remember { mutableStateOf(false) }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Team & Access") },
                navigationIcon = { BackNavIcon(onBack) },
                actions = {
                    if (canManage) {
                        IconButton(onClick = { showInvite = true }) {
                            Icon(Icons.Filled.PersonAddAlt, contentDescription = "Invite member", tint = VineColors.Primary)
                        }
                    }
                },
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
            // Members
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Members", onLight = true)
                if (state.members.isEmpty()) {
                    Text("No members yet.", fontSize = 13.sp, color = vine.textSecondary)
                } else {
                    VineyardCard {
                        state.members.forEachIndexed { index, member ->
                            MemberRow(
                                member = member,
                                isCurrentUser = member.userId == state.currentUserId,
                                canManage = canManage,
                                onClick = {
                                    if (canManage && TeamRole.from(member.role) != TeamRole.Owner) {
                                        editMember = member
                                    }
                                },
                            )
                            if (index < state.members.lastIndex) {
                                Box(modifier = Modifier.fillMaxWidth().size(0.5.dp).background(vine.cardBorder))
                            }
                        }
                    }
                }
            }

            // Pending invitations
            if (state.pendingInvitations.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Pending Invitations", onLight = true)
                    VineyardCard {
                        state.pendingInvitations.forEachIndexed { index, inv ->
                            Row(
                                modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(inv.email, fontWeight = FontWeight.Medium, color = vine.textPrimary)
                                    Text(inv.status.replaceFirstChar { it.uppercase() }, fontSize = 12.sp, color = vine.textSecondary)
                                }
                                RoleChip(TeamRole.from(inv.role))
                            }
                            if (index < state.pendingInvitations.lastIndex) {
                                Box(modifier = Modifier.fillMaxWidth().size(0.5.dp).background(vine.cardBorder))
                            }
                        }
                    }
                }
            }

            // Ownership transfer (owner only)
            if (isOwner) {
                val eligible = state.members.any { it.userId != state.currentUserId && TeamRole.from(it.role) != TeamRole.Owner }
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    VineyardCard {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .let { if (eligible) it.clickable { showTransfer = true } else it }
                                .padding(vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                "Transfer Ownership",
                                color = if (eligible) vine.textPrimary else vine.textSecondary,
                                fontWeight = FontWeight.Medium,
                                modifier = Modifier.weight(1f),
                            )
                            if (eligible) {
                                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
                            }
                        }
                    }
                    Text(
                        if (eligible) "Make another member the owner of this vineyard. You will become Manager."
                        else "Add another active member before you can transfer ownership.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                }
            }

            // Roles & permissions info
            VineyardCard {
                Row(
                    modifier = Modifier.fillMaxWidth().clickable { onOpenTool(com.rork.vinetrack.ui.main.ToolRoute.RolesPermissions) }.padding(vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("Roles & Permissions", color = vine.textPrimary, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
                }
            }

            state.teamError?.let { Text(it, fontSize = 12.sp, color = VineColors.Destructive) }
        }
    }

    if (showInvite) {
        InviteMemberDialog(
            busy = state.teamBusy,
            vineyardName = state.selectedVineyard?.name?.takeIf { it.isNotBlank() } ?: "this vineyard",
            categories = state.operatorCategories.filter { it.deletedAt == null }
                .sortedBy { it.displayName.lowercase() },
            onDismiss = { showInvite = false },
            onInvite = { email, r, categoryId ->
                vm.inviteMember(email, r.raw, categoryId) { ok -> if (ok) showInvite = false }
            },
        )
    }

    editMember?.let { member ->
        EditMemberDialog(
            member = member,
            busy = state.teamBusy,
            vineyardName = state.selectedVineyard?.name?.takeIf { it.isNotBlank() } ?: "this vineyard",
            onDismiss = { editMember = null },
            onSave = { r ->
                vm.updateMember(member.userId, r.raw, member.operatorCategoryId) { ok -> if (ok) editMember = null }
            },
            onRemove = {
                vm.removeMember(member.userId) { ok -> if (ok) editMember = null }
            },
        )
    }

    if (showTransfer) {
        TransferOwnershipDialog(
            members = state.members.filter { it.userId != state.currentUserId && TeamRole.from(it.role) != TeamRole.Owner },
            busy = state.teamBusy,
            vineyardName = state.selectedVineyard?.name?.takeIf { it.isNotBlank() } ?: "this vineyard",
            onDismiss = { showTransfer = false },
            onTransfer = { userId, removeSelf ->
                vm.transferOwnership(userId, removeSelf) { ok -> if (ok) showTransfer = false }
            },
        )
    }

}

@Composable
private fun MemberRow(
    member: VineyardMember,
    isCurrentUser: Boolean,
    canManage: Boolean,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    val role = TeamRole.from(member.role)
    val tappable = canManage && role != TeamRole.Owner
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .let { if (tappable) it.clickable { onClick() } else it }
            .padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier.size(36.dp).clip(CircleShape).background(roleColor(role).copy(alpha = 0.18f)),
            contentAlignment = Alignment.Center,
        ) {
            Text(member.name.take(1).uppercase(), color = roleColor(role), fontWeight = FontWeight.Bold)
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(member.name, fontWeight = FontWeight.Medium, color = vine.textPrimary, maxLines = 1)
            member.email?.takeIf { it.isNotBlank() && it != member.name }?.let {
                Text(it, fontSize = 12.sp, color = vine.textSecondary, maxLines = 1)
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                RoleChip(role)
                member.operatorCategoryName?.takeIf { it.isNotBlank() }?.let {
                    Text(it, fontSize = 11.sp, color = vine.textSecondary)
                }
            }
        }
        if (isCurrentUser) {
            Text("You", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = VineColors.LeafGreen)
        }
        if (tappable) {
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
        }
    }
}

@Composable
private fun RoleChip(role: TeamRole) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(roleColor(role).copy(alpha = 0.14f))
            .padding(horizontal = 7.dp, vertical = 2.dp),
    ) {
        Text(role.displayName, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = roleColor(role))
    }
}

private fun roleColor(role: TeamRole): Color = when (role) {
    TeamRole.Owner -> VineColors.Orange
    TeamRole.Manager -> VineColors.Info
    TeamRole.Supervisor -> VineColors.Indigo
    TeamRole.Operator -> VineColors.LeafGreen
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun InviteMemberDialog(
    busy: Boolean,
    vineyardName: String,
    categories: List<OperatorCategory>,
    onDismiss: () -> Unit,
    onInvite: (String, TeamRole, String?) -> Unit,
) {
    val vine = LocalVineColors.current
    var email by remember { mutableStateOf("") }
    var role by remember { mutableStateOf(TeamRole.Operator) }
    var categoryId by remember { mutableStateOf<String?>(null) }
    val emailValid = email.contains("@") && email.contains(".")
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Invite Member") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                OutlinedTextField(
                    value = email,
                    onValueChange = { email = it },
                    label = { Text("Email address") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    "No email is sent yet. The invited person will see the invite for $vineyardName when they sign in with this email address.",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )
                Text("Role", fontWeight = FontWeight.SemiBold)
                RolePicker(selected = role, onSelect = { role = it })
                Text("Some features and values are hidden based on the assigned role.", fontSize = 11.sp, color = vine.textSecondary)

                Text("Default Worker Type", fontWeight = FontWeight.SemiBold)
                OperatorCategoryPicker(
                    categories = categories,
                    selected = categoryId,
                    onSelect = { categoryId = it },
                )
                Text(
                    if (categories.isEmpty()) {
                        "Create worker types in Spray Management \u2192 Worker Types to assign a default hourly rate at invite time."
                    } else {
                        "Optional. Applied to the new member's profile on accept and used as a fallback for trip cost calculations."
                    },
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onInvite(email.trim(), role, categoryId) }, enabled = emailValid && !busy) {
                Text("Send")
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun OperatorCategoryPicker(
    categories: List<OperatorCategory>,
    selected: String?,
    onSelect: (String?) -> Unit,
) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        OperatorCategoryRow(label = "None", isSelected = selected == null, onClick = { onSelect(null) })
        categories.forEach { cat ->
            OperatorCategoryRow(
                label = cat.displayName,
                isSelected = selected == cat.id,
                onClick = { onSelect(cat.id) },
            )
        }
    }
}

@Composable
private fun OperatorCategoryRow(label: String, isSelected: Boolean, onClick: () -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .clickable { onClick() }
            .padding(vertical = 8.dp, horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(label, color = vine.textPrimary, modifier = Modifier.weight(1f))
        if (isSelected) {
            Box(modifier = Modifier.size(10.dp).clip(CircleShape).background(VineColors.Primary))
        }
    }
}

@Composable
private fun EditMemberDialog(
    member: VineyardMember,
    busy: Boolean,
    vineyardName: String,
    onDismiss: () -> Unit,
    onSave: (TeamRole) -> Unit,
    onRemove: () -> Unit,
) {
    val vine = LocalVineColors.current
    var role by remember { mutableStateOf(TeamRole.from(member.role)) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Edit Member") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("MEMBER", fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    EditMemberInfoRow("Name", member.name)
                    member.email?.takeIf { it.isNotBlank() && it != member.name }?.let {
                        EditMemberInfoRow("Email", it)
                    }
                    EditMemberInfoRow("Current Role", TeamRole.from(member.role).displayName)
                }
                Text("CHANGE ROLE", fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
                RolePicker(selected = role, onSelect = { role = it })
                TextButton(onClick = onRemove, enabled = !busy) {
                    Text("Remove from Vineyard", color = VineColors.Destructive)
                }
            }
        },
        confirmButton = { TextButton(onClick = { onSave(role) }, enabled = !busy) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun EditMemberInfoRow(label: String, value: String) {
    val vine = LocalVineColors.current
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(label, fontSize = 13.sp, color = vine.textSecondary, modifier = Modifier.weight(1f))
        Text(value, fontSize = 13.sp, color = vine.textPrimary, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun RolePicker(selected: TeamRole, onSelect: (TeamRole) -> Unit) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        TeamRole.assignable.forEach { option ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(8.dp))
                    .clickable { onSelect(option) }
                    .padding(vertical = 8.dp, horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(option.displayName, color = vine.textPrimary)
                    Text(option.permissionSummary, fontSize = 11.sp, color = vine.textSecondary)
                }
                if (selected == option) {
                    Box(modifier = Modifier.size(10.dp).clip(CircleShape).background(roleColor(option)))
                }
            }
        }
    }
}

@Composable
private fun TransferOwnershipDialog(
    members: List<VineyardMember>,
    busy: Boolean,
    vineyardName: String,
    onDismiss: () -> Unit,
    onTransfer: (String, Boolean) -> Unit,
) {
    val vine = LocalVineColors.current
    var selected by remember { mutableStateOf<String?>(null) }
    var removeSelf by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Transfer Ownership") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Transferring ownership of $vineyardName is permanent. The new owner gains full control of the vineyard, including team management and deletion.", fontSize = 13.sp, color = vine.textSecondary)
                Text("NEW OWNER", fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
                members.forEach { m ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .clickable { selected = m.userId }
                            .padding(vertical = 8.dp, horizontal = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(m.name, color = vine.textPrimary, modifier = Modifier.weight(1f))
                        if (selected == m.userId) {
                            Box(modifier = Modifier.size(10.dp).clip(CircleShape).background(VineColors.Primary))
                        }
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    androidx.compose.material3.Checkbox(checked = removeSelf, onCheckedChange = { removeSelf = it })
                    Text("Also remove me from this vineyard", fontSize = 13.sp, color = vine.textPrimary)
                }
                Text(
                    if (removeSelf) "You will lose access to this vineyard after the transfer."
                    else "You will become Manager of this vineyard after the transfer.",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = { selected?.let { onTransfer(it, removeSelf) } },
                enabled = selected != null && !busy,
            ) { Text("Transfer", color = VineColors.Destructive) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
