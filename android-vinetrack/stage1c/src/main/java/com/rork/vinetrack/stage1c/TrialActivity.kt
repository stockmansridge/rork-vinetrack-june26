package com.rork.vinetrack.stage1c

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.isolation.Stage1CCopyHarness
import java.util.concurrent.Executors

/** Explicit ADB entry, no launcher icon, production Application or automatic trial action. */
class TrialActivity : ComponentActivity() {
    private val executor = Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            var status: String by remember { mutableStateOf("NO-GO until intended device and independent preflight evidence are pinned.") }
            var isWorking: Boolean by remember { mutableStateOf(false) }
            var activeHarness: Stage1CCopyHarness? by remember { mutableStateOf(null) }
            MaterialTheme {
                Scaffold { insets ->
                    Column(Modifier.fillMaxSize().padding(insets).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                        Text("Stage 1C • preparation only", style = MaterialTheme.typography.headlineSmall)
                        Text("Persisted synthetic offline work is retained. Active or ambiguous work refuses admission.")
                        Text(status)
                        Button(enabled = !isWorking, onClick = {
                            isWorking = true
                            val harness = Stage1CCopyHarness(applicationContext)
                            activeHarness = harness
                            executor.execute {
                                val report = harness.preflight()
                                runOnUiThread {
                                    status = "${report.status}\n${report.reason}\n${report.model} / Android ${report.androidRelease}\nAvailable: ${report.availableBytes} bytes\nRequired: ${report.requiredFreeBytes} bytes"
                                    isWorking = false
                                }
                            }
                        }) { Text(if (isWorking) "Checking preflight…" else "Check preflight only") }
                        Button(enabled = isWorking, onClick = { activeHarness?.requestStop() }) { Text("Stop at next file boundary") }
                        Text("Copy and restart execution are unavailable in this APK. No sign-out, adoption, repair, routing or replay.")
                    }
                }
            }
        }
    }

    override fun onDestroy() {
        executor.shutdown()
        super.onDestroy()
    }
}
