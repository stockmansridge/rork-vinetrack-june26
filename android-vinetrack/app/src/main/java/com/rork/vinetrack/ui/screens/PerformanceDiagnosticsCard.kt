package com.rork.vinetrack.ui.screens

import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.Button
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.VineyardCard

/** Admin-only controls. Each preference change and export performs a fresh server check. */
@Composable
internal fun PerformanceDiagnosticsCard(vm: AppViewModel, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    var enabled by remember { mutableStateOf(vm.isPerformanceCaptureRequested()) }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    Column(modifier = modifier) {
        VineyardCard {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Performance Diagnostics")
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Capture performance timings", modifier = Modifier.weight(1f))
                    Switch(checked = enabled, enabled = !busy, onCheckedChange = { requested ->
                        busy = true
                        message = null
                        vm.setPerformanceCaptureEnabled(requested) { saved ->
                            enabled = vm.isPerformanceCaptureRequested()
                            busy = false
                            if (!saved) message = "Capture setting could not be confirmed. Check your connection and admin access."
                        }
                    })
                }
                Text("Leave enabled for early-launch timing. Then reopen the app, visit Home, Trip and Program, and share here. Export requires fresh admin verification.")
                Text("Bounded, memory-only elapsed timings; lost on termination. Network waiting is included. No CPU attribution, peak memory, IDs, coordinates, tokens or raw errors. Never uploaded automatically.")
                Button(enabled = !busy, onClick = {
                    busy = true
                    message = null
                    vm.exportPerformanceTimings { report ->
                        busy = false
                        if (report == null) {
                            enabled = vm.isPerformanceCaptureRequested()
                            message = "Report access could not be verified. Check your connection and retry."
                        } else {
                            runCatching {
                                context.startActivity(Intent.createChooser(
                                    Intent(Intent.ACTION_SEND).setType("text/plain")
                                        .putExtra(Intent.EXTRA_TEXT, report), "Share timing report"))
                            }.onFailure { message = "No sharing app is available on this device." }
                        }
                    }
                }) { Text(if (busy) "Verifying…" else "Share timing report") }
                message?.let { Text(it) }
            }
        }
    }
}
