package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.main.ToolGroup
import com.rork.vinetrack.ui.main.ToolRoute
import com.rork.vinetrack.ui.theme.LocalVineColors

/** Tools hub. Surfaces every secondary surface, grouped by purpose. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MoreScreen(
    state: AppUiState,
    modifier: Modifier = Modifier,
    onOpenTool: (ToolRoute) -> Unit,
) {
    val vine = LocalVineColors.current
    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("More") },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            val canViewCosting = state.currentRole == "owner" || state.currentRole == "manager"
            ToolGroup.entries.forEach { group ->
                val tools = ToolRoute.entries.filter { tool ->
                    tool.group == group &&
                        tool != ToolRoute.RolesPermissions &&
                        tool != ToolRoute.SprayManagement &&
                        (tool != ToolRoute.CostReports || canViewCosting)
                }
                if (tools.isNotEmpty()) {
                    item(key = "header-${group.name}") {
                        SectionHeader(group.label, onLight = true)
                    }
                    item(key = "card-${group.name}") {
                        VineyardCard {
                            tools.forEachIndexed { index, tool ->
                                ToolRow(tool, onClick = { onOpenTool(tool) })
                                if (index < tools.lastIndex) {
                                    Box(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .size(0.5.dp)
                                            .background(vine.cardBorder),
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ToolRow(tool: ToolRoute, onClick: () -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().clickable { onClick() }.padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(RoundedCornerShape(11.dp))
                .background(tool.tint.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(tool.icon, contentDescription = null, tint = tool.tint, modifier = Modifier.size(20.dp))
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(tool.title, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, fontSize = 16.sp)
            Text(tool.subtitle, fontSize = 12.sp, color = vine.textSecondary)
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = vine.textSecondary,
        )
    }
}
