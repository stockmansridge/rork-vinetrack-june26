package com.rork.vinetrack.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import com.rork.vinetrack.data.model.Vineyard
import com.rork.vinetrack.ui.main.ToolRoute
import com.rork.vinetrack.ui.screens.HeaderRow
import com.rork.vinetrack.ui.screens.SyncStatusRefreshAction
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class HomeSyncChipAndroidTest {
    @get:Rule val compose = createComposeRule()

    @Test fun everyChipStateOpensExistingDetailsIncludingWhileSyncingAndOffline() {
        val status = mutableStateOf(HomeSyncStatus("Synced", HomeSyncTone.Synced))
        val routes = mutableListOf<ToolRoute>()
        compose.setContent { MaterialTheme {
            Box(Modifier.fillMaxSize().safeDrawingPadding().background(Color(0xFF184332))) {
                HeaderRow(Vineyard("A", "Stockmans Ridge"), null, listOf(Vineyard("A", "Stockmans Ridge")),
                    status.value, { routes.add(it) }, {})
            }
        } }
        val states = listOf(HomeSyncStatus("Synced", HomeSyncTone.Synced),
            HomeSyncStatus("Syncing", HomeSyncTone.Syncing), HomeSyncStatus("Offline", HomeSyncTone.Offline),
            HomeSyncStatus("3 waiting", HomeSyncTone.Waiting), HomeSyncStatus("2 held", HomeSyncTone.Waiting),
            HomeSyncStatus("Sync error", HomeSyncTone.Attention), HomeSyncStatus("Needs attention", HomeSyncTone.Attention))
        states.forEach { next ->
            compose.runOnIdle { status.value = next }
            compose.onNodeWithContentDescription("Sync Status: ${next.label}").assertIsDisplayed().assertHasClickAction().performClick()
            compose.onNodeWithText("Refresh").assertDoesNotExist()
            compose.onNodeWithText("Stockmans Ridge").assertIsDisplayed()
        }
        compose.runOnIdle {
            assertEquals(states.size, routes.size)
            assertTrue(routes.all { it == ToolRoute.SyncStatus })
        }
    }

    @Test fun globalRefreshRemainsExplicitInsideDetailsAndUnavailableOfflineOrWhileLoading() {
        val online = mutableStateOf(true)
        val loading = mutableStateOf(false)
        var refreshes = 0
        compose.setContent { MaterialTheme {
            SyncStatusRefreshAction(online.value, loading.value) { refreshes++ }
        } }
        compose.onNodeWithText("Refresh all").assertIsEnabled().performClick()
        compose.runOnIdle { assertEquals(1, refreshes); loading.value = true }
        compose.onNodeWithText("Refreshing…").assertIsNotEnabled()
        compose.runOnIdle { loading.value = false; online.value = false }
        compose.onNodeWithText("Refresh all").assertIsNotEnabled()
        compose.runOnIdle { assertEquals(1, refreshes) }
    }

    @Test fun vineyardSwitcherAndChipRemainSeparateDuringAtoBtoA() {
        val vineyards = listOf(Vineyard("A", "Stockmans Ridge"), Vineyard("B", "JH Testing"))
        val selected = mutableStateOf("A")
        val status = mutableStateOf(HomeSyncStatus("3 waiting", HomeSyncTone.Waiting))
        var opens = 0
        compose.setContent { MaterialTheme {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) {
                HeaderRow(vineyards.first { it.id == selected.value }, null, vineyards, status.value,
                    { assertEquals(ToolRoute.SyncStatus, it); opens++ }, { id ->
                        selected.value = id
                        status.value = if (id == "A") HomeSyncStatus("3 waiting", HomeSyncTone.Waiting)
                            else HomeSyncStatus("Synced", HomeSyncTone.Synced)
                    })
            }
        } }
        for ((name, label) in listOf("JH Testing" to "Synced", "Stockmans Ridge" to "3 waiting")) {
            compose.onNodeWithContentDescription("Switch vineyard").performClick()
            compose.onAllNodesWithText(name).onLast().performClick()
            compose.onNodeWithText(name).assertIsDisplayed()
            compose.onNodeWithContentDescription("Sync Status: $label").performClick()
        }
        compose.runOnIdle { assertEquals("A", selected.value); assertEquals(2, opens) }
    }
}
