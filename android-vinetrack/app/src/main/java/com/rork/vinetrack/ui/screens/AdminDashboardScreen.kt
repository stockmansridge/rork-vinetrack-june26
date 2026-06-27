package com.rork.vinetrack.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Agriculture
import androidx.compose.material.icons.filled.AllInclusive
import androidx.compose.material.icons.filled.Assignment
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.Grass
import androidx.compose.material.icons.filled.Group
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.MailOutline
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.ShieldMoon
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.rork.vinetrack.data.AdminRepository
import com.rork.vinetrack.data.BillingGrantsRepository
import com.rork.vinetrack.data.SystemAdminRepository
import com.rork.vinetrack.data.model.AdminEngagementSummary
import com.rork.vinetrack.data.model.AdminInvitationRow
import com.rork.vinetrack.data.model.AdminPinRow
import com.rork.vinetrack.data.model.AdminPlatformScale
import com.rork.vinetrack.data.model.AdminSprayRow
import com.rork.vinetrack.data.model.AdminUserRow
import com.rork.vinetrack.data.model.AdminVineyardRow
import com.rork.vinetrack.data.model.AdminWorkTaskRow
import com.rork.vinetrack.data.model.ManualUnlimitedGrant
import com.rork.vinetrack.data.model.SystemAdminUserRow
import com.rork.vinetrack.data.model.SystemFeatureFlagRow
import com.rork.vinetrack.data.model.UserLoginActivityRow
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch
import java.util.Locale
import kotlin.math.roundToInt

/** Internal navigation targets reachable from the Admin dashboard. */
private sealed interface AdminDestination {
    data object AllUsers : AdminDestination
    data class UsersFiltered(val title: String, val filter: (AdminUserRow) -> Boolean) : AdminDestination
    data object Vineyards : AdminDestination
    data object Invitations : AdminDestination
    data object Pins : AdminDestination
    data object SprayRecords : AdminDestination
    data object WorkTasks : AdminDestination
    data class UserDetail(val user: AdminUserRow) : AdminDestination
    data class VineyardDetail(val vineyard: AdminVineyardRow) : AdminDestination
    data object FeatureFlags : AdminDestination
    data object SystemAdmins : AdminDestination
    data object LoginActivity : AdminDestination
    data object BillingGrants : AdminDestination
}

/**
 * Platform System Admin dashboard, mirroring the iOS `AdminDashboardView` +
 * system-admin tooling. Read-only browsers over the `admin_*` RPCs plus the
 * editable System Admin tools (feature flags, admin registry). Access is gated
 * upstream by [com.rork.vinetrack.ui.AppUiState.isSystemAdmin]; the RPCs also
 * enforce it server-side.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AdminDashboardScreen(
    vm: AppViewModel,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
) {
    val adminRepo = vm.adminRepository
    val systemRepo = vm.systemAdminRepository
    val billingRepo = vm.billingGrantsRepository
    val state by vm.ui.collectAsStateWithLifecycle()

    // Defence-in-depth: the Settings entry is already hidden for non-admins and
    // every RPC is server-enforced, but guard the whole surface in-screen too so
    // it can never render admin data if reached by any other path.
    if (!state.isSystemAdmin) {
        AdminAccessDenied(modifier = modifier, onBack = onBack)
        return
    }

    var destination by remember { mutableStateOf<AdminDestination?>(null) }

    when (val dest = destination) {
        null -> AdminRoot(
            adminRepo = adminRepo,
            modifier = modifier,
            onBack = onBack,
            onOpen = { destination = it },
        )
        else -> {
            BackHandler { destination = null }
            AdminDestinationHost(
                destination = dest,
                adminRepo = adminRepo,
                systemRepo = systemRepo,
                billingRepo = billingRepo,
                modifier = modifier,
                onBack = { destination = null },
                onOpen = { destination = it },
            )
        }
    }
}

// MARK: - Access gate

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AdminAccessDenied(modifier: Modifier, onBack: (() -> Unit)?) {
    val vine = LocalVineColors.current
    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Admin") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding).padding(24.dp), contentAlignment = Alignment.Center) {
            EmptyState(
                Icons.Filled.ShieldMoon,
                "Restricted area",
                "You are not a VineTrack platform administrator. This area is reserved for system admins.",
            )
        }
    }
}

// MARK: - Root dashboard

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AdminRoot(
    adminRepo: AdminRepository,
    modifier: Modifier,
    onBack: (() -> Unit)?,
    onOpen: (AdminDestination) -> Unit,
) {
    val vine = LocalVineColors.current
    var summary by remember { mutableStateOf<AdminEngagementSummary?>(null) }
    var scale by remember { mutableStateOf<AdminPlatformScale?>(null) }
    var blocks by remember { mutableStateOf<Int?>(null) }
    var users by remember { mutableStateOf<List<AdminUserRow>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        isLoading = true
        error = null
        runCatching {
            summary = adminRepo.fetchEngagementSummary()
            scale = runCatching { adminRepo.fetchPlatformScale() }.getOrNull()
            blocks = runCatching { adminRepo.fetchBlocksCount() }.getOrNull()
            users = adminRepo.fetchAllUsers()
        }.onFailure { error = it.message ?: "Couldn't load admin data." }
        isLoading = false
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Admin") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        if (isLoading && summary == null) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = VineColors.Primary)
            }
            return@Scaffold
        }
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            error?.let {
                VineyardCard {
                    Text(it, color = VineColors.Warning, fontSize = 13.sp)
                }
            }

            scale?.let { s ->
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Platform Scale", onLight = true)
                    VineyardCard {
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            StatLine("Hectares under management", formatHa(s.totalHectaresUnderManagement))
                            DividerLine(vine.cardBorder)
                            StatLine("Vineyards", s.totalVineyards.toString())
                            DividerLine(vine.cardBorder)
                            StatLine("Active blocks", s.totalActivePaddocks.toString())
                            DividerLine(vine.cardBorder)
                            StatLine("Blocks with area", s.totalPaddocksWithArea.toString())
                            DividerLine(vine.cardBorder)
                            StatLine("Avg ha / vineyard", formatHa(s.averageHectaresPerVineyard))
                        }
                    }
                }
            }

            summary?.let { s ->
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Engagement", onLight = true)
                    VineyardCard {
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            AdminRow(Icons.Filled.Person, VineColors.Primary, "Total users", s.totalUsers.toString()) {
                                onOpen(AdminDestination.AllUsers)
                            }
                            DividerLine(vine.cardBorder)
                            AdminRow(Icons.Filled.Person, VineColors.LeafGreen, "Active last 7 days", s.signedInLast7Days.toString()) {
                                onOpen(AdminDestination.UsersFiltered("Active last 7 days") { recentDays(it.lastSignInAt) <= 7 })
                            }
                            DividerLine(vine.cardBorder)
                            AdminRow(Icons.Filled.Person, VineColors.Cyan, "Active last 30 days", s.signedInLast30Days.toString()) {
                                onOpen(AdminDestination.UsersFiltered("Active last 30 days") { recentDays(it.lastSignInAt) <= 30 })
                            }
                            DividerLine(vine.cardBorder)
                            AdminRow(Icons.Filled.Person, VineColors.Indigo, "New (30 days)", s.newUsersLast30Days.toString()) {
                                onOpen(AdminDestination.UsersFiltered("New last 30 days") { recentDays(it.createdAt) <= 30 })
                            }
                            DividerLine(vine.cardBorder)
                            AdminRow(Icons.Filled.Agriculture, VineColors.EarthBrown, "Vineyards", s.totalVineyards.toString()) {
                                onOpen(AdminDestination.Vineyards)
                            }
                            DividerLine(vine.cardBorder)
                            AdminRow(Icons.Filled.Grass, VineColors.LeafGreen, "Blocks", (blocks ?: s.totalVineyards).toString()) {
                                onOpen(AdminDestination.Vineyards)
                            }
                            DividerLine(vine.cardBorder)
                            AdminRow(Icons.Filled.MailOutline, VineColors.Orange, "Pending invitations", s.pendingInvitations.toString()) {
                                onOpen(AdminDestination.Invitations)
                            }
                            DividerLine(vine.cardBorder)
                            AdminRow(Icons.Filled.LocationOn, VineColors.Orange, "Pins", s.totalPins.toString()) {
                                onOpen(AdminDestination.Pins)
                            }
                            DividerLine(vine.cardBorder)
                            AdminRow(Icons.Filled.WaterDrop, VineColors.Info, "Spray records", s.totalSprayRecords.toString()) {
                                onOpen(AdminDestination.SprayRecords)
                            }
                            DividerLine(vine.cardBorder)
                            AdminRow(Icons.Filled.Assignment, VineColors.Indigo, "Work tasks", s.totalWorkTasks.toString()) {
                                onOpen(AdminDestination.WorkTasks)
                            }
                        }
                    }
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Users", onLight = true)
                VineyardCard {
                    AdminRow(Icons.Filled.Group, VineColors.Primary, "All users", users.size.toString()) {
                        onOpen(AdminDestination.AllUsers)
                    }
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("System Admin Tools", onLight = true)
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        AdminRow(Icons.Filled.Flag, VineColors.Indigo, "Feature flags", null) {
                            onOpen(AdminDestination.FeatureFlags)
                        }
                        DividerLine(vine.cardBorder)
                        AdminRow(Icons.Filled.ShieldMoon, VineColors.Destructive, "System admins", null) {
                            onOpen(AdminDestination.SystemAdmins)
                        }
                        DividerLine(vine.cardBorder)
                        AdminRow(Icons.Filled.AllInclusive, VineColors.LeafGreen, "Billing grants / internal access", null) {
                            onOpen(AdminDestination.BillingGrants)
                        }
                        DividerLine(vine.cardBorder)
                        AdminRow(Icons.Filled.History, VineColors.Cyan, "User login activity", null) {
                            onOpen(AdminDestination.LoginActivity)
                        }
                    }
                }
            }
            Spacer(Modifier.height(8.dp))
        }
    }
}

// MARK: - Destination host

@Composable
private fun AdminDestinationHost(
    destination: AdminDestination,
    adminRepo: AdminRepository,
    systemRepo: SystemAdminRepository,
    billingRepo: BillingGrantsRepository,
    modifier: Modifier,
    onBack: () -> Unit,
    onOpen: (AdminDestination) -> Unit,
) {
    when (destination) {
        is AdminDestination.AllUsers -> UsersBrowser("All Users", null, adminRepo, modifier, onBack, onOpen)
        is AdminDestination.UsersFiltered -> UsersBrowser(destination.title, destination.filter, adminRepo, modifier, onBack, onOpen)
        is AdminDestination.Vineyards -> VineyardsBrowser(adminRepo, modifier, onBack, onOpen)
        is AdminDestination.Invitations -> InvitationsBrowser(adminRepo, modifier, onBack)
        is AdminDestination.Pins -> PinsBrowser(adminRepo, modifier, onBack)
        is AdminDestination.SprayRecords -> SprayBrowser(adminRepo, modifier, onBack)
        is AdminDestination.WorkTasks -> WorkTasksBrowser(adminRepo, modifier, onBack)
        is AdminDestination.UserDetail -> UserDetail(destination.user, adminRepo, modifier, onBack, onOpen)
        is AdminDestination.VineyardDetail -> VineyardDetail(destination.vineyard, modifier, onBack)
        is AdminDestination.FeatureFlags -> FeatureFlagsScreen(systemRepo, modifier, onBack)
        is AdminDestination.SystemAdmins -> SystemAdminsScreen(systemRepo, modifier, onBack)
        is AdminDestination.LoginActivity -> LoginActivityScreen(systemRepo, modifier, onBack)
        is AdminDestination.BillingGrants -> BillingGrantsScreen(billingRepo, adminRepo, modifier, onBack)
    }
}

// MARK: - Generic list browser scaffold

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun <T> ListBrowser(
    title: String,
    modifier: Modifier,
    onBack: () -> Unit,
    load: suspend () -> List<T>,
    emptyMessage: String,
    key: (T) -> Any,
    row: @Composable (T) -> Unit,
) {
    val vine = LocalVineColors.current
    var items by remember { mutableStateOf<List<T>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(title) {
        isLoading = true
        error = null
        runCatching { load() }
            .onSuccess { items = it }
            .onFailure { error = it.message ?: "Couldn't load data." }
        isLoading = false
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text(title) },
                navigationIcon = { BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        when {
            isLoading -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = VineColors.Primary)
            }
            error != null -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                Text(error!!, color = VineColors.Warning, modifier = Modifier.padding(24.dp))
            }
            items.isEmpty() -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                EmptyState(Icons.Filled.Group, "Nothing here", emptyMessage)
            }
            else -> LazyColumn(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(items, key = { key(it) }) { row(it) }
            }
        }
    }
}

@Composable
private fun UsersBrowser(
    title: String,
    filter: ((AdminUserRow) -> Boolean)?,
    adminRepo: AdminRepository,
    modifier: Modifier,
    onBack: () -> Unit,
    onOpen: (AdminDestination) -> Unit,
) {
    ListBrowser(
        title = title,
        modifier = modifier,
        onBack = onBack,
        load = { adminRepo.fetchAllUsers().let { if (filter != null) it.filter(filter) else it } },
        emptyMessage = "No users match this filter.",
        key = { it.id },
    ) { user ->
        EntityCard(
            title = user.displayName,
            subtitle = user.email,
            badge = "${user.vineyardCount} vineyard" + if (user.vineyardCount == 1) "" else "s",
            footer = "Owns ${user.ownedCount} \u00b7 ${user.blockCount ?: 0} blocks \u00b7 last seen ${shortDate(user.lastSignInAt)}",
            onClick = { onOpen(AdminDestination.UserDetail(user)) },
        )
    }
}

@Composable
private fun VineyardsBrowser(
    adminRepo: AdminRepository,
    modifier: Modifier,
    onBack: () -> Unit,
    onOpen: (AdminDestination) -> Unit,
) {
    ListBrowser(
        title = "Vineyards",
        modifier = modifier,
        onBack = onBack,
        load = { adminRepo.fetchAllVineyards() },
        emptyMessage = "No vineyards found.",
        key = { it.id },
    ) { v ->
        EntityCard(
            title = v.name.ifBlank { "Untitled vineyard" },
            subtitle = "Owner: ${v.ownerDisplay}",
            badge = if (v.deletedAt != null) "Deleted" else "${v.memberCount} member" + if (v.memberCount == 1) "" else "s",
            footer = listOfNotNull(
                v.country?.takeIf { it.isNotBlank() },
                if (v.pendingInvites > 0) "${v.pendingInvites} pending invites" else null,
                "created ${shortDate(v.createdAt)}",
            ).joinToString(" \u00b7 "),
            badgeTint = if (v.deletedAt != null) VineColors.Destructive else VineColors.LeafGreen,
            onClick = { onOpen(AdminDestination.VineyardDetail(v)) },
        )
    }
}

@Composable
private fun InvitationsBrowser(adminRepo: AdminRepository, modifier: Modifier, onBack: () -> Unit) {
    ListBrowser(
        title = "Pending Invitations",
        modifier = modifier,
        onBack = onBack,
        load = { adminRepo.fetchInvitations() },
        emptyMessage = "No invitations.",
        key = { it.id },
    ) { inv: AdminInvitationRow ->
        EntityCard(
            title = inv.email,
            subtitle = "${inv.role.replaceFirstChar { it.uppercase() }} \u00b7 ${inv.vineyardName ?: "\u2014"}",
            badge = inv.status.replaceFirstChar { it.uppercase() },
            footer = listOfNotNull(
                inv.invitedByEmail?.let { "by $it" },
                "expires ${shortDate(inv.expiresAt)}",
            ).joinToString(" \u00b7 "),
            badgeTint = VineColors.Orange,
        )
    }
}

@Composable
private fun PinsBrowser(adminRepo: AdminRepository, modifier: Modifier, onBack: () -> Unit) {
    ListBrowser(
        title = "Pins",
        modifier = modifier,
        onBack = onBack,
        load = { adminRepo.fetchPins() },
        emptyMessage = "No pins.",
        key = { it.id },
    ) { pin: AdminPinRow ->
        EntityCard(
            title = pin.title.ifBlank { "Untitled pin" },
            subtitle = pin.vineyardName ?: "\u2014",
            badge = if (pin.isCompleted) "Done" else (pin.status ?: pin.category ?: "Open"),
            footer = "created ${shortDate(pin.createdAt)}",
            badgeTint = if (pin.isCompleted) VineColors.LeafGreen else VineColors.Orange,
        )
    }
}

@Composable
private fun SprayBrowser(adminRepo: AdminRepository, modifier: Modifier, onBack: () -> Unit) {
    ListBrowser(
        title = "Spray Records",
        modifier = modifier,
        onBack = onBack,
        load = { adminRepo.fetchSprayRecords() },
        emptyMessage = "No spray records.",
        key = { it.id },
    ) { s: AdminSprayRow ->
        EntityCard(
            title = s.sprayReference?.takeIf { it.isNotBlank() } ?: (s.operationType ?: "Spray"),
            subtitle = s.vineyardName ?: "\u2014",
            badge = s.operationType,
            footer = "date ${shortDate(s.date ?: s.createdAt)}",
            badgeTint = VineColors.Info,
        )
    }
}

@Composable
private fun WorkTasksBrowser(adminRepo: AdminRepository, modifier: Modifier, onBack: () -> Unit) {
    ListBrowser(
        title = "Work Tasks",
        modifier = modifier,
        onBack = onBack,
        load = { adminRepo.fetchWorkTasks() },
        emptyMessage = "No work tasks.",
        key = { it.id },
    ) { t: AdminWorkTaskRow ->
        EntityCard(
            title = t.taskType?.takeIf { it.isNotBlank() } ?: "Task",
            subtitle = t.vineyardName ?: "\u2014",
            badge = t.durationHours?.let { String.format(Locale.US, "%.1f h", it) },
            footer = listOfNotNull(
                t.paddockName?.takeIf { it.isNotBlank() },
                "date ${shortDate(t.date ?: t.createdAt)}",
            ).joinToString(" \u00b7 "),
            badgeTint = VineColors.Indigo,
        )
    }
}

// MARK: - User / vineyard detail

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun UserDetail(
    user: AdminUserRow,
    adminRepo: AdminRepository,
    modifier: Modifier,
    onBack: () -> Unit,
    onOpen: (AdminDestination) -> Unit,
) {
    val vine = LocalVineColors.current
    var vineyards by remember { mutableStateOf<List<com.rork.vinetrack.data.model.AdminUserVineyardRow>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }

    LaunchedEffect(user.id) {
        isLoading = true
        vineyards = runCatching { adminRepo.fetchUserVineyards(user.id) }.getOrDefault(emptyList())
        isLoading = false
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text(user.displayName, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = { BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    StatLine("Email", user.email)
                    DividerLine(vine.cardBorder)
                    StatLine("Vineyards", user.vineyardCount.toString())
                    DividerLine(vine.cardBorder)
                    StatLine("Owned", user.ownedCount.toString())
                    DividerLine(vine.cardBorder)
                    StatLine("Blocks", (user.blockCount ?: 0).toString())
                    DividerLine(vine.cardBorder)
                    StatLine("Joined", shortDate(user.createdAt))
                    DividerLine(vine.cardBorder)
                    StatLine("Last sign-in", shortDate(user.lastSignInAt))
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Vineyards", onLight = true)
                if (isLoading) {
                    CircularProgressIndicator(color = VineColors.Primary, modifier = Modifier.size(28.dp))
                } else if (vineyards.isEmpty()) {
                    Text("No vineyards for this user.", color = vine.textSecondary, fontSize = 13.sp)
                } else {
                    vineyards.forEach { v ->
                        EntityCard(
                            title = v.name.ifBlank { "Untitled" },
                            subtitle = (if (v.isOwner) "Owner" else v.role?.replaceFirstChar { it.uppercase() }) ?: "Member",
                            badge = "${v.memberCount} member" + if (v.memberCount == 1) "" else "s",
                            footer = listOfNotNull(v.country?.takeIf { it.isNotBlank() }, "created ${shortDate(v.createdAt)}").joinToString(" \u00b7 "),
                            badgeTint = if (v.deletedAt != null) VineColors.Destructive else VineColors.LeafGreen,
                        )
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun VineyardDetail(vineyard: AdminVineyardRow, modifier: Modifier, onBack: () -> Unit) {
    val vine = LocalVineColors.current
    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text(vineyard.name.ifBlank { "Vineyard" }, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = { BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    StatLine("Owner", vineyard.ownerDisplay)
                    vineyard.ownerEmail?.let { DividerLine(vine.cardBorder); StatLine("Owner email", it) }
                    DividerLine(vine.cardBorder)
                    StatLine("Members", vineyard.memberCount.toString())
                    DividerLine(vine.cardBorder)
                    StatLine("Pending invites", vineyard.pendingInvites.toString())
                    DividerLine(vine.cardBorder)
                    StatLine("Country", vineyard.country?.takeIf { it.isNotBlank() } ?: "\u2014")
                    DividerLine(vine.cardBorder)
                    StatLine("Created", shortDate(vineyard.createdAt))
                    if (vineyard.deletedAt != null) {
                        DividerLine(vine.cardBorder)
                        StatLine("Deleted", shortDate(vineyard.deletedAt))
                    }
                }
            }
        }
    }
}

// MARK: - System admin tools

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FeatureFlagsScreen(systemRepo: SystemAdminRepository, modifier: Modifier, onBack: () -> Unit) {
    val vine = LocalVineColors.current
    val scope = rememberCoroutineScope()
    var flags by remember { mutableStateOf<List<SystemFeatureFlagRow>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }

    suspend fun reload() {
        flags = runCatching { systemRepo.fetchFlags() }
            .onFailure { error = it.message }
            .getOrDefault(emptyList())
            .sortedBy { (it.category ?: "zzz") + it.displayLabel.lowercase() }
    }

    LaunchedEffect(Unit) { isLoading = true; reload(); isLoading = false }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Feature Flags") },
                navigationIcon = { BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        if (isLoading) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = VineColors.Primary)
            }
            return@Scaffold
        }
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            error?.let { Text(it, color = VineColors.Warning, fontSize = 13.sp) }
            if (flags.isEmpty()) {
                Text("No feature flags defined.", color = vine.textSecondary, fontSize = 13.sp)
            }
            flags.forEach { flag ->
                VineyardCard {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Column(Modifier.weight(1f)) {
                            Text(flag.displayLabel, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                            val sub = flag.description?.takeIf { it.isNotBlank() } ?: flag.key
                            Text(sub, fontSize = 12.sp, color = vine.textSecondary)
                        }
                        Switch(
                            checked = flag.isEnabled,
                            onCheckedChange = { newValue ->
                                // Optimistic toggle, revert on failure.
                                flags = flags.map { if (it.key == flag.key) it.copy(isEnabled = newValue) else it }
                                scope.launch {
                                    val ok = runCatching { systemRepo.setFlag(flag.key, newValue) }.isSuccess
                                    if (!ok) {
                                        flags = flags.map { if (it.key == flag.key) it.copy(isEnabled = !newValue) else it }
                                        error = "Couldn't update ${flag.displayLabel}."
                                    } else {
                                        error = null
                                    }
                                }
                            },
                        )
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SystemAdminsScreen(systemRepo: SystemAdminRepository, modifier: Modifier, onBack: () -> Unit) {
    val vine = LocalVineColors.current
    val scope = rememberCoroutineScope()
    var admins by remember { mutableStateOf<List<SystemAdminUserRow>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var showAdd by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }

    suspend fun reload() {
        admins = runCatching { systemRepo.listSystemAdmins() }
            .onFailure { error = it.message }
            .getOrDefault(emptyList())
            .sortedWith(compareByDescending<SystemAdminUserRow> { it.isActive }.thenBy { it.displayEmail.lowercase() })
    }

    LaunchedEffect(Unit) { isLoading = true; reload(); isLoading = false }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("System Admins") },
                navigationIcon = { BackNavIcon(onBack) },
                actions = {
                    TextButton(onClick = { showAdd = true }) { Text("Add") }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        if (isLoading) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = VineColors.Primary)
            }
            return@Scaffold
        }
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            error?.let { Text(it, color = VineColors.Warning, fontSize = 13.sp) }
            Text(
                "Only active admins can read admin surfaces or edit feature flags. Vineyard owner/manager roles do not grant access.",
                fontSize = 12.sp,
                color = vine.textSecondary,
            )
            admins.forEach { admin ->
                VineyardCard {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Column(Modifier.weight(1f)) {
                            Text(admin.displayEmail, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                            Text(if (admin.isActive) "Active" else "Disabled", fontSize = 12.sp, color = if (admin.isActive) VineColors.LeafGreen else vine.textSecondary)
                        }
                        Switch(
                            checked = admin.isActive,
                            enabled = !busy,
                            onCheckedChange = { newValue ->
                                busy = true
                                admins = admins.map { if (it.userId == admin.userId) it.copy(isActive = newValue) else it }
                                scope.launch {
                                    val ok = runCatching { systemRepo.setSystemAdminActive(admin.userId, newValue) }.isSuccess
                                    if (!ok) {
                                        admins = admins.map { if (it.userId == admin.userId) it.copy(isActive = !newValue) else it }
                                        error = "Couldn't update ${admin.displayEmail}."
                                    } else error = null
                                    busy = false
                                }
                            },
                        )
                    }
                }
            }
        }
    }

    if (showAdd) {
        var email by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { showAdd = false },
            title = { Text("Add System Admin") },
            text = {
                OutlinedTextField(
                    value = email,
                    onValueChange = { email = it },
                    singleLine = true,
                    label = { Text("Email address") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                )
            },
            confirmButton = {
                TextButton(
                    enabled = email.contains("@") && !busy,
                    onClick = {
                        val target = email.trim()
                        showAdd = false
                        busy = true
                        scope.launch {
                            val ok = runCatching { systemRepo.addSystemAdmin(target) }.isSuccess
                            if (ok) reload() else error = "Couldn't add $target. Is the email a registered user?"
                            busy = false
                        }
                    },
                ) { Text("Add") }
            },
            dismissButton = { TextButton(onClick = { showAdd = false }) { Text("Cancel") } },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LoginActivityScreen(systemRepo: SystemAdminRepository, modifier: Modifier, onBack: () -> Unit) {
    ListBrowser(
        title = "Login Activity",
        modifier = modifier,
        onBack = onBack,
        load = { systemRepo.listUserLoginActivity() },
        emptyMessage = "No login activity.",
        key = { it.userId },
    ) { row: UserLoginActivityRow ->
        val tint = when (row.activityStatus) {
            com.rork.vinetrack.data.model.UserActivityStatus.ActiveRecent -> VineColors.LeafGreen
            com.rork.vinetrack.data.model.UserActivityStatus.Active30d -> VineColors.Cyan
            com.rork.vinetrack.data.model.UserActivityStatus.Inactive30d -> VineColors.Orange
            com.rork.vinetrack.data.model.UserActivityStatus.Inactive90d -> VineColors.Destructive
            com.rork.vinetrack.data.model.UserActivityStatus.Never -> VineColors.Stone
        }
        EntityCard(
            title = row.bestName,
            subtitle = row.email ?: "\u2014",
            badge = row.activityStatus.label,
            footer = listOfNotNull(
                "last ${shortDate(row.lastSignInAt)}",
                row.displayDevice,
                row.displayAppVersion?.let { "v$it" },
            ).joinToString(" \u00b7 "),
            badgeTint = tint,
        )
    }
}

// MARK: - Billing grants / internal access

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BillingGrantsScreen(
    billingRepo: BillingGrantsRepository,
    adminRepo: AdminRepository,
    modifier: Modifier,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current
    val scope = rememberCoroutineScope()
    var grants by remember { mutableStateOf<List<ManualUnlimitedGrant>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var showGrant by remember { mutableStateOf(false) }
    var confirmRevoke by remember { mutableStateOf<ManualUnlimitedGrant?>(null) }
    var pendingId by remember { mutableStateOf<String?>(null) }

    val activeGrants by remember { derivedStateOf { grants.filter { it.isActive } } }
    val inactiveGrants by remember { derivedStateOf { grants.filter { !it.isActive } } }

    suspend fun reload() {
        runCatching { billingRepo.listGrants() }
            .onSuccess { grants = it; error = null }
            .onFailure { error = friendlyGrantError(it) }
    }

    LaunchedEffect(Unit) { isLoading = true; reload(); isLoading = false }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Billing Grants") },
                navigationIcon = { BackNavIcon(onBack) },
                actions = { TextButton(onClick = { showGrant = true }) { Text("Grant") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        if (isLoading && grants.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = VineColors.Primary)
            }
            return@Scaffold
        }
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            error?.let { Text(it, color = VineColors.Warning, fontSize = 13.sp) }

            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    StatLine("Active grants", activeGrants.size.toString())
                    DividerLine(vine.cardBorder)
                    StatLine("Total grants", grants.size.toString())
                }
            }
            Text(
                "Manually granted unlimited licences for internal accounts and power testers. Not customer billing — no Stripe, Apple, or RevenueCat.",
                fontSize = 12.sp,
                color = vine.textSecondary,
            )

            if (activeGrants.isNotEmpty()) {
                SectionHeader("Active", onLight = true)
                activeGrants.forEach { grant ->
                    GrantCard(
                        grant = grant,
                        isPending = pendingId == grant.subscriptionId,
                        onRevoke = { confirmRevoke = grant },
                    )
                }
            } else if (!isLoading) {
                EmptyState(Icons.Filled.AllInclusive, "No active grants", "No active unlimited grants right now.")
            }

            if (inactiveGrants.isNotEmpty()) {
                SectionHeader("Revoked / expired", onLight = true)
                inactiveGrants.forEach { grant ->
                    GrantCard(grant = grant, isPending = false, onRevoke = null)
                }
            }
            Spacer(Modifier.height(8.dp))
        }
    }

    if (showGrant) {
        GrantUnlimitedSheet(
            adminRepo = adminRepo,
            onDismiss = { showGrant = false },
            onSubmit = { ownerId, vineyardId, reason, expiresAt ->
                runCatching { billingRepo.grantUnlimited(ownerId, vineyardId, reason, expiresAt) }
                    .fold(
                        onSuccess = { showGrant = false; reload(); null },
                        onFailure = { friendlyGrantError(it) },
                    )
            },
        )
    }

    confirmRevoke?.let { grant ->
        AlertDialog(
            onDismissRequest = { confirmRevoke = null },
            title = { Text("Revoke unlimited access?") },
            text = { Text("${grant.ownerDisplay} will lose unlimited access immediately and their licences will be revoked.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmRevoke = null
                    pendingId = grant.subscriptionId
                    scope.launch {
                        runCatching { billingRepo.revokeUnlimited(grant.subscriptionId) }
                            .onSuccess { reload() }
                            .onFailure { error = friendlyGrantError(it) }
                        pendingId = null
                    }
                }) { Text("Revoke", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { confirmRevoke = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun GrantCard(grant: ManualUnlimitedGrant, isPending: Boolean, onRevoke: (() -> Unit)?) {
    val vine = LocalVineColors.current
    val tint = if (grant.isActive) VineColors.LeafGreen else VineColors.Stone
    VineyardCard {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(
                modifier = Modifier.size(38.dp).clip(RoundedCornerShape(10.dp)).background(tint.copy(alpha = 0.18f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    if (grant.isActive) Icons.Filled.AllInclusive else Icons.Filled.Block,
                    contentDescription = null,
                    tint = tint,
                    modifier = Modifier.size(20.dp),
                )
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(grant.ownerDisplay, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                val status = if (grant.isActive) "Unlimited" else (grant.manualGrantRevokedAt?.let { "Revoked" } ?: "Expired")
                val line = listOfNotNull(
                    status,
                    grant.vineyardName?.takeIf { it.isNotBlank() },
                    if (grant.activeLicences > 0) "${grant.activeLicences} licence" + (if (grant.activeLicences == 1) "" else "s") else null,
                ).joinToString(" · ")
                Text(line, fontSize = 12.sp, color = if (grant.isActive) VineColors.LeafGreen else vine.textSecondary)
                grant.manualGrantReason?.takeIf { it.isNotBlank() }?.let {
                    Text(it, fontSize = 11.sp, color = vine.textSecondary, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
                grant.manualGrantExpiresAt?.let {
                    Text("Expires ${shortDate(it)}", fontSize = 11.sp, color = vine.textSecondary)
                }
            }
            when {
                isPending -> CircularProgressIndicator(color = VineColors.Primary, modifier = Modifier.size(22.dp))
                onRevoke != null -> TextButton(onClick = onRevoke) {
                    Text("Revoke", color = VineColors.Destructive, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun GrantUnlimitedSheet(
    adminRepo: AdminRepository,
    onDismiss: () -> Unit,
    onSubmit: suspend (ownerId: String, vineyardId: String?, reason: String?, expiresAt: String?) -> String?,
) {
    val vine = LocalVineColors.current
    val scope = rememberCoroutineScope()
    var users by remember { mutableStateOf<List<AdminUserRow>>(emptyList()) }
    var query by remember { mutableStateOf("") }
    var selectedUser by remember { mutableStateOf<AdminUserRow?>(null) }
    var vineyards by remember { mutableStateOf<List<com.rork.vinetrack.data.model.AdminUserVineyardRow>>(emptyList()) }
    var selectedVineyardId by remember { mutableStateOf<String?>(null) }
    var reason by remember { mutableStateOf("") }
    var isLoadingUsers by remember { mutableStateOf(true) }
    var isLoadingVineyards by remember { mutableStateOf(false) }
    var isSubmitting by remember { mutableStateOf(false) }
    var formError by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        isLoadingUsers = true
        users = runCatching { adminRepo.fetchAllUsers() }.getOrDefault(emptyList())
        isLoadingUsers = false
    }

    LaunchedEffect(selectedUser?.id) {
        val id = selectedUser?.id ?: return@LaunchedEffect
        selectedVineyardId = null
        isLoadingVineyards = true
        val rows = runCatching { adminRepo.fetchUserVineyards(id) }.getOrDefault(emptyList())
        vineyards = rows.filter { it.deletedAt == null }.sortedBy { it.name.lowercase() }
        if (vineyards.size == 1) selectedVineyardId = vineyards.first().id
        isLoadingVineyards = false
    }

    val filteredUsers by remember(query, users) {
        derivedStateOf {
            val q = query.trim().lowercase()
            if (q.isEmpty()) users.take(25)
            else users.filter {
                it.email.lowercase().contains(q) || (it.fullName?.lowercase()?.contains(q) ?: false)
            }.take(25)
        }
    }
    val canSubmit = selectedUser != null && selectedVineyardId != null && !isSubmitting

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = vine.cardBackground) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text("Grant Unlimited", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)

            SectionHeader("Owner", onLight = true)
            val picked = selectedUser
            if (picked != null) {
                VineyardCard {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Column(Modifier.weight(1f)) {
                            Text(picked.displayName, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                            if (picked.email.isNotEmpty()) Text(picked.email, fontSize = 12.sp, color = vine.textSecondary)
                        }
                        TextButton(onClick = { selectedUser = null }) { Text("Change") }
                    }
                }
            } else {
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    singleLine = true,
                    label = { Text("Search by name or email") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                    modifier = Modifier.fillMaxWidth(),
                )
                if (isLoadingUsers) {
                    CircularProgressIndicator(color = VineColors.Primary, modifier = Modifier.size(24.dp))
                } else {
                    filteredUsers.forEach { user ->
                        Box(
                            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
                                .clickable { selectedUser = user; query = "" }.padding(vertical = 8.dp, horizontal = 4.dp),
                        ) {
                            Column {
                                Text(user.displayName, color = vine.textPrimary, fontSize = 14.sp)
                                if (user.email.isNotEmpty()) Text(user.email, color = vine.textSecondary, fontSize = 12.sp)
                            }
                        }
                    }
                }
            }

            if (picked != null) {
                SectionHeader("Primary vineyard", onLight = true)
                when {
                    isLoadingVineyards -> CircularProgressIndicator(color = VineColors.Primary, modifier = Modifier.size(24.dp))
                    vineyards.isEmpty() -> Text("This user is not linked to any vineyard yet.", fontSize = 13.sp, color = vine.textSecondary)
                    else -> vineyards.forEach { v ->
                        val selected = selectedVineyardId == v.id
                        Box(
                            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
                                .background(if (selected) VineColors.Primary.copy(alpha = 0.12f) else Color.Transparent)
                                .clickable { selectedVineyardId = v.id }.padding(12.dp),
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                Text(
                                    if (v.isOwner) "${v.name} (owner)" else v.name,
                                    color = vine.textPrimary,
                                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                                    modifier = Modifier.weight(1f),
                                )
                                if (selected) Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = VineColors.Primary, modifier = Modifier.size(18.dp))
                            }
                        }
                    }
                }
            }

            SectionHeader("Reason", onLight = true)
            OutlinedTextField(
                value = reason,
                onValueChange = { reason = it },
                label = { Text("Internal note (optional)") },
                minLines = 2,
                modifier = Modifier.fillMaxWidth(),
            )

            formError?.let { Text(it, color = VineColors.Warning, fontSize = 13.sp) }

            Button(
                onClick = {
                    val owner = selectedUser ?: return@Button
                    isSubmitting = true
                    formError = null
                    scope.launch {
                        val err = onSubmit(owner.id, selectedVineyardId, reason.trim().ifEmpty { null }, null)
                        isSubmitting = false
                        if (err != null) formError = err
                    }
                },
                enabled = canSubmit,
                modifier = Modifier.fillMaxWidth(),
            ) {
                if (isSubmitting) CircularProgressIndicator(color = Color.White, modifier = Modifier.size(20.dp))
                else Text("Grant unlimited access")
            }
        }
    }
}

/** Maps server errors from the billing-grant RPCs to friendly admin-facing copy. */
private fun friendlyGrantError(error: Throwable): String {
    val raw = (error.message ?: "").lowercase()
    return when {
        raw.contains("user_not_found") -> "No VineTrack account exists for that user."
        raw.contains("internal_unlimited_plan_missing") -> "The Internal Unlimited plan is missing. Apply migration sql/096 first."
        raw.contains("owner_required") -> "Please select an owner."
        raw.contains("subscription_not_found") -> "That grant no longer exists. Refresh and try again."
        raw.contains("system admin") || raw.contains("42501") -> "System admin required."
        raw.contains("could not find the function") || raw.contains("pgrst202") -> "Backend RPCs not found. Apply migration sql/096 to Supabase."
        else -> error.message ?: "Something went wrong. Please try again."
    }
}

// MARK: - Reusable rows

@Composable
private fun AdminRow(icon: ImageVector, tint: Color, title: String, value: String?, onClick: () -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().clickable { onClick() }.padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier.size(36.dp).clip(RoundedCornerShape(10.dp)).background(tint.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
        }
        Text(title, fontWeight = FontWeight.Medium, color = vine.textPrimary, modifier = Modifier.weight(1f))
        if (value != null) {
            Text(value, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
    }
}

@Composable
private fun StatLine(label: String, value: String) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = vine.textSecondary, fontSize = 13.sp, modifier = Modifier.weight(1f))
        Text(value, color = vine.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun EntityCard(
    title: String,
    subtitle: String,
    badge: String? = null,
    footer: String? = null,
    badgeTint: Color = VineColors.Info,
    onClick: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    VineyardCard(modifier = if (onClick != null) Modifier.clickable { onClick() } else Modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(title, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (badge != null) {
                    Box(
                        modifier = Modifier.clip(RoundedCornerShape(8.dp)).background(badgeTint.copy(alpha = 0.15f)).padding(horizontal = 8.dp, vertical = 3.dp),
                    ) {
                        Text(badge, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = badgeTint)
                    }
                }
            }
            Text(subtitle, fontSize = 13.sp, color = vine.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (!footer.isNullOrBlank()) {
                Text(footer, fontSize = 11.sp, color = vine.textSecondary)
            }
        }
    }
}

@Composable
private fun DividerLine(color: Color) {
    Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(color))
}

// MARK: - Formatting helpers

private fun formatHa(value: Double): String =
    if (value <= 0) "0 ha" else String.format(Locale.US, "%,.1f ha", value)

/** Display the date part of an ISO-8601 timestamp; "\u2014" when absent. */
private fun shortDate(iso: String?): String {
    val s = iso?.takeIf { it.isNotBlank() } ?: return "\u2014"
    return s.take(10)
}

/** Whole days since the given ISO timestamp; large value when absent/unparseable. */
private fun recentDays(iso: String?): Long {
    val s = iso?.takeIf { it.isNotBlank() } ?: return Long.MAX_VALUE
    return runCatching {
        val instant = java.time.OffsetDateTime.parse(
            if (s.length == 10) "${s}T00:00:00Z" else s
        ).toInstant()
        val millis = System.currentTimeMillis() - instant.toEpochMilli()
        (millis.toDouble() / 86_400_000.0).roundToInt().toLong()
    }.getOrDefault(Long.MAX_VALUE)
}
