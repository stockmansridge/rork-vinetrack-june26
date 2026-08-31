package com.rork.vinetrack.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.delay

/** Seconds the "Add a photo?" question waits before answering itself. */
const val AUTO_PHOTO_PROMPT_SECONDS: Int = 3

/**
 * The shared "Add a photo?" prompt shown straight after a pin is created.
 *
 * There is exactly ONE of these in the app. It was private to the quick-pin
 * launcher; the Unified Pin Composer now shows the same sheet rather than
 * growing a second countdown that could drift out of step with this one.
 *
 * It counts down from [AUTO_PHOTO_PROMPT_SECONDS] and answers [onSkip] on
 * zero. Skip, a swipe-dismiss and the timeout are deliberately the same
 * answer — the pin is already saved by the time this appears, so none of
 * them can lose it. `responded` makes every route single-shot, so a race
 * between the timer and a tap cannot fire two callbacks.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AutoPhotoPromptSheet(
    onSkip: () -> Unit,
    onTakePhoto: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    var remaining by remember { mutableIntStateOf(AUTO_PHOTO_PROMPT_SECONDS) }
    var responded by remember { mutableStateOf(false) }

    // 3 → 0 countdown; auto-skips when it reaches zero unless already answered.
    LaunchedEffect(Unit) {
        for (value in (AUTO_PHOTO_PROMPT_SECONDS - 1) downTo 0) {
            delay(1000)
            remaining = value
        }
        delay(1000)
        if (!responded) {
            responded = true
            onSkip()
        }
    }

    ModalBottomSheet(
        onDismissRequest = { if (!responded) { responded = true; onSkip() } },
        sheetState = sheetState,
        containerColor = vine.cardBackground,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(56.dp)
                    .clip(CircleShape)
                    .background(VineColors.Primary.copy(alpha = 0.14f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Filled.PhotoCamera,
                    contentDescription = null,
                    tint = VineColors.Primary,
                    modifier = Modifier.size(28.dp),
                )
            }
            Text("Add a photo?", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
            Text(
                "Auto-skipping in ${remaining}s",
                fontSize = 14.sp,
                color = vine.textSecondary,
            )
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                OutlinedButton(
                    onClick = { if (!responded) { responded = true; onSkip() } },
                    modifier = Modifier.weight(1f),
                ) { Text("Skip") }
                Button(
                    onClick = { if (!responded) { responded = true; onTakePhoto() } },
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
                ) {
                    Icon(Icons.Filled.PhotoCamera, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(6.dp))
                    Text("Take Photo")
                }
            }
        }
    }
}
