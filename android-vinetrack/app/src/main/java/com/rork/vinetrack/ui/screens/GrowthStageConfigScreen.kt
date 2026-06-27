package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.OperationPrefsStore
import com.rork.vinetrack.data.model.GrowthStage
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/**
 * Enable/disable which E-L growth stages are active for recording and reporting.
 * Mirrors the iOS `GrowthStageConfigSheet`: searchable checklist, select/deselect
 * all, and a live "N of M enabled" header. Persisted on this device via
 * [OperationPrefsStore]; the recording picker and growth report read the same set.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GrowthStageConfigScreen(
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val store = remember { OperationPrefsStore(context) }

    var enabled by remember { mutableStateOf(store.load().enabledGrowthStageCodes.toSet()) }
    var searchText by remember { mutableStateOf("") }

    fun persist(next: Set<String>) {
        enabled = next
        val prefs = store.load()
        // Preserve catalog order so storage is deterministic.
        store.save(prefs.copy(enabledGrowthStageCodes = GrowthStage.allStages.map { it.code }.filter { next.contains(it) }))
    }

    val filtered = remember(searchText) {
        val q = searchText.trim()
        if (q.isBlank()) GrowthStage.allStages
        else GrowthStage.allStages.filter {
            it.code.contains(q, ignoreCase = true) || it.description.contains(q, ignoreCase = true)
        }
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("E-L Growth Stages") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            Column(
                modifier = Modifier.padding(horizontal = 16.dp).padding(top = 8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedTextField(
                    value = searchText,
                    onValueChange = { searchText = it },
                    label = { Text("Search stages") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = { persist(GrowthStage.allStages.map { it.code }.toSet()) }) {
                        Text("Select All", fontWeight = FontWeight.Medium, color = VineColors.LeafGreen)
                    }
                    TextButton(onClick = { persist(emptySet()) }) {
                        Text("Deselect All", fontWeight = FontWeight.Medium, color = VineColors.Destructive)
                    }
                    Box(modifier = Modifier.weight(1f))
                    Text(
                        "${enabled.size} of ${GrowthStage.allStages.size} enabled",
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                }
            }

            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(filtered, key = { it.code }) { stage ->
                    val on = enabled.contains(stage.code)
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(vine.cardBackground)
                            .clickable {
                                persist(if (on) enabled - stage.code else enabled + stage.code)
                            }
                            .padding(14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Icon(
                            imageVector = if (on) Icons.Filled.CheckCircle else Icons.Outlined.Circle,
                            contentDescription = if (on) "Enabled" else "Disabled",
                            tint = if (on) VineColors.LeafGreen else vine.textSecondary,
                            modifier = Modifier.size(24.dp),
                        )
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(6.dp))
                                .background(VineColors.LeafGreen)
                                .padding(horizontal = 8.dp, vertical = 3.dp),
                        ) {
                            Text(stage.code, color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Bold)
                        }
                        Text(
                            stage.description,
                            color = vine.textPrimary,
                            fontSize = 13.sp,
                            maxLines = 2,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
        }
    }
}
