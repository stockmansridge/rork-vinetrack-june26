package com.rork.vinetrack.ui

import android.content.Intent
import android.os.Build
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.rork.vinetrack.data.AppReleasePolicy
import com.rork.vinetrack.data.AppReleasePolicyRepository
import com.rork.vinetrack.data.ReleaseDecision
import com.rork.vinetrack.data.ReleaseReminderStore

/** Detached from startup/auth: no server response is needed to enter the app. */
@Composable
fun ReleasePolicyPrompt(route: AppRoute) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val repository = remember { AppReleasePolicyRepository() }
    val reminders = remember(context) { ReleaseReminderStore(context) }
    var foregroundCount by remember { mutableIntStateOf(0) }
    var lastAttempt by remember { mutableLongStateOf(0L) }
    var policy by remember { mutableStateOf<AppReleasePolicy?>(null) }
    var decision by remember { mutableStateOf(ReleaseDecision.NONE) }

    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_START) foregroundCount++
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    LaunchedEffect(foregroundCount) {
        if (foregroundCount == 0) return@LaunchedEffect
        val now = System.currentTimeMillis()
        if (decision != ReleaseDecision.REQUIRED && lastAttempt != 0L && now - lastAttempt < 60L * 60 * 1000) return@LaunchedEffect
        lastAttempt = now
        val result = repository.fetch()
        val packageInfo = runCatching { context.packageManager.getPackageInfo(context.packageName, 0) }.getOrNull()
        val installedBuild = packageInfo?.let {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) it.longVersionCode else {
                @Suppress("DEPRECATION")
                it.versionCode.toLong()
            }
        } ?: return@LaunchedEffect
        val outcome = result?.takeIf { it.officialStoreUri != null }?.decision(installedBuild)
            ?: ReleaseDecision.NONE
        val isSnoozed = outcome == ReleaseDecision.OPTIONAL &&
            result != null && reminders.isSnoozed(result.latestBuild, System.currentTimeMillis())
        decision = if (isSnoozed) ReleaseDecision.NONE else outcome
        policy = if (decision == ReleaseDecision.NONE) null else result
    }

    val visiblePolicy = policy?.takeIf { route != AppRoute.Restoring && route != AppRoute.BiometricLock }
        ?: return
    AlertDialog(
        onDismissRequest = {
            if (decision == ReleaseDecision.OPTIONAL) {
                reminders.later(visiblePolicy.latestBuild, System.currentTimeMillis())
                policy = null
            }
        },
        title = { Text(if (decision == ReleaseDecision.REQUIRED) "VineTrack update required" else visiblePolicy.displayTitle) },
        text = {
            Text(
                run {
                    val installedVersion = runCatching {
                        context.packageManager.getPackageInfo(context.packageName, 0).versionName
                    }.getOrNull() ?: "Unknown"
                    val explanation = if (decision == ReleaseDecision.REQUIRED) {
                        "\n\nYour version of VineTrack is no longer supported. Update to continue."
                    } else ""
                    "${visiblePolicy.displayMessage}$explanation\n\nInstalled: $installedVersion\nLatest: ${visiblePolicy.latestVersion}"
                },
            )
        },
        confirmButton = {
            TextButton(onClick = {
                visiblePolicy.officialStoreUri?.let { uri ->
                    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, uri)) }
                        .onSuccess { if (decision == ReleaseDecision.OPTIONAL) policy = null }
                }
            }) { Text("Update VineTrack") }
        },
        dismissButton = {
            if (decision == ReleaseDecision.OPTIONAL) {
                TextButton(onClick = {
                    reminders.later(visiblePolicy.latestBuild, System.currentTimeMillis())
                    policy = null
                }) { Text("Later") }
            }
        },
    )
}
