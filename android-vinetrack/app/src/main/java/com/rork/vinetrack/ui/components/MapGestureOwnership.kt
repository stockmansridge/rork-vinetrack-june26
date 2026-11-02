package com.rork.vinetrack.ui.components

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.composed
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput

/** Observe (never consume) map pointers before the scrolling form. Release on UP, CANCEL or disposal. */
fun Modifier.mapGestureOwnership(onGesture: (Boolean) -> Unit): Modifier = composed {
    val report by rememberUpdatedState(onGesture)
    pointerInput(Unit) {
    try {
        awaitEachGesture {
            awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
            report(true)
            try {
                do { val event = awaitPointerEvent(PointerEventPass.Initial) } while (event.changes.any { it.pressed })
            } finally { report(false) }
        }
    } finally { report(false) }
    }
}
