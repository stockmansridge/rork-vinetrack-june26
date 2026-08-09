package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.rork.vinetrack.data.OperationalToolLayoutResolver
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.main.OperationalToolCatalog
import com.rork.vinetrack.ui.main.OperationalToolDefinition
import com.rork.vinetrack.ui.theme.LocalVineColors
import kotlin.math.roundToInt

private val ROW_HEIGHT = 64.dp
private val ROW_SPACING = 8.dp

/**
 * Customise Operational Tools — reorder, hide and restore the Home grid tiles.
 *
 * Changes save automatically (locally first, then Supabase), so an edit can
 * never be lost by leaving the screen. Only tools the caller is entitled to see
 * appear here: hiding is a display choice and never changes permissions,
 * records, notifications, reports or another user's layout.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CustomiseToolsScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current
    val haptics = LocalHapticFeedback.current
    val density = LocalDensity.current
    val layout by vm.operationalToolLayout.collectAsStateWithLifecycle()

    val canViewCosting = state.currentRole == "owner" || state.currentRole == "manager"
    val authorised = remember(canViewCosting) { OperationalToolCatalog.authorised(canViewCosting) }
    val authorisedIds = remember(authorised) { authorised.map { it.id } }

    var localVisible by remember { mutableStateOf(emptyList<String>()) }
    var localHidden by remember { mutableStateOf(emptyList<String>()) }
    var draggingId by remember { mutableStateOf<String?>(null) }
    var dragOffset by remember { mutableFloatStateOf(0f) }
    var showResetConfirm by remember { mutableStateOf(false) }
    var showMinimumWarning by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { vm.refreshOperationalToolLayout() }

    // Adopt the store's layout whenever it changes, except mid-drag.
    LaunchedEffect(layout, authorisedIds, draggingId) {
        if (draggingId == null) {
            localVisible = OperationalToolLayoutResolver.visibleToolIds(layout, authorisedIds)
            localHidden = OperationalToolLayoutResolver.hiddenToolIds(layout, authorisedIds)
        }
    }

    fun commit(visible: List<String>, hidden: List<String>) {
        localVisible = visible
        localHidden = hidden
        vm.saveOperationalToolLayout(visible, hidden, authorisedIds)
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Customise Tools") },
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
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            if (layout.hasPendingSync && layout.syncMessage != null) {
                VineyardCard {
                    Text(
                        layout.syncMessage ?: OperationalToolLayoutResolver.OFFLINE_SAVE_MESSAGE,
                        color = vine.textSecondary,
                        fontSize = 13.sp,
                    )
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SectionHeader("Visible Tools", onLight = true)
                Text(
                    "Drag the handle to reorder. At least one tool must remain visible.",
                    color = vine.textSecondary,
                    fontSize = 12.sp,
                )
                Column(verticalArrangement = Arrangement.spacedBy(ROW_SPACING)) {
                    localVisible.forEach { toolId ->
                        val tool = OperationalToolCatalog.tool(toolId) ?: return@forEach
                        // key(toolId) keeps each row's composable identity stable
                        // across reorders — without it Compose re-associates rows by
                        // position and the in-flight drag gesture is cancelled after
                        // every single swap.
                        key(toolId) {
                        val isDragging = draggingId == toolId
                        val rowStepPx = with(density) { (ROW_HEIGHT + ROW_SPACING).toPx() }
                        ToolRowCard(
                            tool = tool,
                            dimmed = false,
                            modifier = Modifier
                                .zIndex(if (isDragging) 1f else 0f)
                                .graphicsLayer { translationY = if (isDragging) dragOffset else 0f },
                            trailing = {
                                IconButton(
                                    onClick = {
                                        if (localVisible.size <= 1) {
                                            showMinimumWarning = true
                                        } else {
                                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                            commit(
                                                localVisible.filterNot { it == toolId },
                                                localHidden + toolId,
                                            )
                                        }
                                    },
                                    modifier = Modifier.semantics {
                                        contentDescription = "Hide tool, ${tool.title}"
                                    },
                                ) {
                                    Icon(
                                        Icons.Filled.VisibilityOff,
                                        contentDescription = null,
                                        tint = vine.textSecondary,
                                    )
                                }
                                Icon(
                                    Icons.Filled.DragHandle,
                                    contentDescription = null,
                                    tint = vine.textSecondary,
                                    modifier = Modifier
                                        .size(28.dp)
                                        .semantics {
                                            contentDescription = "Move tool, ${tool.title}"
                                        }
                                        // Keyed by the stable toolId only — keying on the
                                        // list restarts (cancels) the gesture after each
                                        // swap, limiting a drag to one row at a time.
                                        .pointerInput(toolId) {
                                            detectDragGestures(
                                                onDragStart = {
                                                    draggingId = toolId
                                                    dragOffset = 0f
                                                    haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                                },
                                                onDragEnd = {
                                                    draggingId = null
                                                    dragOffset = 0f
                                                    commit(localVisible, localHidden)
                                                },
                                                onDragCancel = {
                                                    draggingId = null
                                                    dragOffset = 0f
                                                },
                                                onDrag = { change, delta ->
                                                    change.consume()
                                                    dragOffset += delta.y
                                                    val index = localVisible.indexOf(toolId)
                                                    if (index < 0) return@detectDragGestures
                                                    // Round so rows swap at the midpoint for
                                                    // a smooth continuous reorder feel.
                                                    val steps = (dragOffset / rowStepPx).roundToInt()
                                                    if (steps == 0) return@detectDragGestures
                                                    val target = (index + steps)
                                                        .coerceIn(0, localVisible.lastIndex)
                                                    if (target == index) return@detectDragGestures
                                                    localVisible = localVisible.toMutableList().also {
                                                        it.add(target, it.removeAt(index))
                                                    }
                                                    dragOffset -= (target - index) * rowStepPx
                                                    haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                                },
                                            )
                                        },
                                )
                            },
                        )
                        }
                    }
                }
            }

            if (localHidden.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionHeader("Hidden Tools", onLight = true)
                    Text(
                        "Restored tools are added to the end of Visible Tools — drag them where you want them.",
                        color = vine.textSecondary,
                        fontSize = 12.sp,
                    )
                    Column(verticalArrangement = Arrangement.spacedBy(ROW_SPACING)) {
                        localHidden.forEach { toolId ->
                            val tool = OperationalToolCatalog.tool(toolId) ?: return@forEach
                            ToolRowCard(
                                tool = tool,
                                dimmed = true,
                                trailing = {
                                    OutlinedButton(
                                        onClick = {
                                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                            commit(
                                                localVisible + toolId,
                                                localHidden.filterNot { it == toolId },
                                            )
                                        },
                                        modifier = Modifier.semantics {
                                            contentDescription = "Show tool, ${tool.title}"
                                        },
                                    ) {
                                        Icon(
                                            Icons.Filled.Visibility,
                                            contentDescription = null,
                                            modifier = Modifier.size(18.dp),
                                        )
                                        Spacer(Modifier.size(6.dp))
                                        Text("Show", fontSize = 13.sp)
                                    }
                                },
                            )
                        }
                    }
                }
            }

            OutlinedButton(
                onClick = { showResetConfirm = true },
                modifier = Modifier
                    .fillMaxWidth()
                    .semantics { contentDescription = "Reset layout" },
            ) {
                Icon(Icons.Filled.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.size(8.dp))
                Text("Reset to default layout")
            }

            Text(
                "Hiding a tool only removes its tile from the Operational Tools grid. Records, " +
                    "notifications, reports and permissions are unaffected, and no other user's " +
                    "layout changes.",
                color = vine.textSecondary,
                fontSize = 12.sp,
            )
            Spacer(Modifier.height(24.dp))
        }
    }

    if (showMinimumWarning) {
        AlertDialog(
            onDismissRequest = { showMinimumWarning = false },
            title = { Text("Can't hide this tool") },
            text = { Text(OperationalToolLayoutResolver.MINIMUM_VISIBLE_MESSAGE) },
            confirmButton = {
                TextButton(onClick = { showMinimumWarning = false }) { Text("OK") }
            },
        )
    }

    if (showResetConfirm) {
        AlertDialog(
            onDismissRequest = { showResetConfirm = false },
            title = { Text("Reset Operational Tools?") },
            text = {
                Text("This will show all available tools and return them to the default VineTrack order.")
            },
            confirmButton = {
                TextButton(onClick = {
                    showResetConfirm = false
                    vm.resetOperationalToolLayout()
                }) { Text("Reset") }
            },
            dismissButton = {
                TextButton(onClick = { showResetConfirm = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun ToolRowCard(
    tool: OperationalToolDefinition,
    dimmed: Boolean,
    modifier: Modifier = Modifier,
    trailing: @Composable () -> Unit,
) {
    val vine = LocalVineColors.current
    val alpha = if (dimmed) 0.6f else 1f
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(ROW_HEIGHT)
            .clip(RoundedCornerShape(12.dp))
            .background(vine.cardBackground)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(tool.tint.copy(alpha = 0.15f * alpha)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                tool.icon,
                contentDescription = null,
                tint = tool.tint.copy(alpha = alpha),
                modifier = Modifier.size(20.dp),
            )
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(
                tool.title,
                color = vine.textPrimary.copy(alpha = alpha),
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 2,
            )
            Text(
                tool.subtitle,
                color = vine.textSecondary.copy(alpha = alpha),
                fontSize = 11.sp,
                maxLines = 1,
            )
        }
        trailing()
    }
}
