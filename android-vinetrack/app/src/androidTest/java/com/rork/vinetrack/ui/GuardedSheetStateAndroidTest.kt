package com.rork.vinetrack.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Normal synchronized sheet actions; no clock/idling override. */
@RunWith(AndroidJUnit4::class)
@OptIn(ExperimentalMaterial3Api::class)
class GuardedSheetStateAndroidTest {
    @get:Rule val compose = createComposeRule()

    private val observations = java.util.concurrent.CopyOnWriteArrayList<String>()
    @org.junit.After fun clearObserver() { com.rork.vinetrack.data.auth.CleanExitDiagnostics.observer = null }

    private fun showSheet() {
        com.rork.vinetrack.data.auth.CleanExitDiagnostics.observer = observations::add
        compose.setContent {
            MaterialTheme {
                var visible by remember { mutableStateOf(true) }
                if (visible) {
                    ModalBottomSheet(onDismissRequest = { visible = false }, sheetState = rememberGuardedSheetState()) {
                        Box(Modifier.fillMaxWidth().height(480.dp).testTag("sheet-body")) {
                            TextButton(onClick = { visible = false }) { Text("Cancel editor") }
                        }
                    }
                } else Text("Editor closed")
            }
        }
        compose.onNodeWithText("Cancel editor").assertIsDisplayed()
        // Await the unchanged resting-offset stability window, not Compose frames forever.
        compose.mainClock.advanceTimeBy(250)
        compose.waitForIdle()
    }

    @Test fun restingSheetIdlesAndExplicitCancelWorks() {
        showSheet()
        compose.onNodeWithText("Cancel editor").performClick()
        compose.onNodeWithText("Editor closed").assertIsDisplayed()
    }

    @Test fun smallDragStaysOpenAndLargeDeliberateDragDismisses() {
        showSheet()
        compose.onNodeWithTag("sheet-body").performTouchInput {
            swipe(Offset(centerX, 20f), Offset(centerX, height * 0.2f), 400)
        }
        try {
            compose.onNodeWithText("Cancel editor").assertIsDisplayed()
        } catch (failure: AssertionError) {
            throw AssertionError("$observations\n${compose.onAllNodes(isRoot()).onLast().printToString()}", failure)
        }
        compose.mainClock.advanceTimeBy(250)
        compose.waitForIdle()
        compose.onNodeWithTag("sheet-body").performTouchInput {
            swipe(Offset(centerX, 10f), Offset(centerX, height * 0.98f), 700)
        }
        compose.onNodeWithText("Editor closed").assertIsDisplayed()
    }
}
