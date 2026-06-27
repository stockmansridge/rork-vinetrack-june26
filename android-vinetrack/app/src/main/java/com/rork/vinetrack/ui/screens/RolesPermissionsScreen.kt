package com.rork.vinetrack.ui.screens

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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material.icons.filled.WorkspacePremium
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
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/**
 * Full-screen Roles & Permissions reference, mirroring the iOS
 * `RolesPermissionsInfoView` (which is pushed as a navigation destination
 * rather than presented as a dialog).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RolesPermissionsScreen(
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current
    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Roles & Permissions") },
                navigationIcon = { BackNavIcon(onBack) },
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
            Text(
                "Each team member has an assigned role. The role controls what they can see and do in the app. Some features, buttons and values are hidden automatically based on role.",
                fontSize = 13.sp,
                color = vine.textSecondary,
            )

            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Roles", onLight = true)
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        RoleInfoRow(
                            title = "Operator",
                            color = VineColors.LeafGreen,
                            icon = Icons.Filled.Person,
                            summary = "Field staff. Records daily work and runs Yield Estimation collections, but cannot delete records or see financial data.",
                        )
                        RoleInfoRow(
                            title = "Supervisor",
                            color = VineColors.Indigo,
                            icon = Icons.Filled.Groups,
                            summary = "Day-to-day operations lead. Can manage and delete records but cannot see financial data.",
                        )
                        RoleInfoRow(
                            title = "Manager",
                            color = VineColors.Info,
                            icon = Icons.Filled.VerifiedUser,
                            summary = "Full access including financials, setup, team management and exports.",
                        )
                        RoleInfoRow(
                            title = "Owner",
                            color = VineColors.Orange,
                            icon = Icons.Filled.WorkspacePremium,
                            summary = "The vineyard creator. Same access as Manager and cannot be removed or changed.",
                        )
                    }
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("What changes between roles", onLight = true)
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        RoleBulletRow("Financial data (costs, rates, totals) is only visible to Managers and Owners.")
                        RoleBulletRow("Deleting records is limited to Supervisors and above.")
                        RoleBulletRow("Vineyard setup and team management are Manager-only.")
                        RoleBulletRow("Finalising and archiving records is limited to Managers and Owners.")
                    }
                }
            }

            Text(
                "If a button or section is missing, it has been hidden for your role. Ask a Manager if you need access.",
                fontSize = 12.sp,
                color = vine.textSecondary,
            )
        }
    }
}

@Composable
private fun RoleInfoRow(
    title: String,
    color: Color,
    icon: ImageVector,
    summary: String,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier.size(32.dp).clip(RoundedCornerShape(8.dp)).background(color),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
        }
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Text(summary, fontSize = 12.sp, color = vine.textSecondary)
        }
    }
}

@Composable
private fun RoleBulletRow(text: String) {
    val vine = LocalVineColors.current
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(
            Icons.Filled.CheckCircle,
            contentDescription = null,
            tint = VineColors.LeafGreen,
            modifier = Modifier.size(16.dp).padding(top = 2.dp),
        )
        Text(text, fontSize = 13.sp, color = vine.textPrimary)
    }
}
