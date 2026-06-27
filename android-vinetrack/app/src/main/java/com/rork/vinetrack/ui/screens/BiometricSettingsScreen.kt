package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Fingerprint
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.fragment.app.FragmentActivity
import com.rork.vinetrack.data.auth.BiometricAuth
import com.rork.vinetrack.data.auth.BiometricResult
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch

/**
 * Biometric sign-in preference, the Android counterpart of iOS
 * BiometricSettingsView. Enabling runs a confirming device prompt before the
 * preference is persisted; the unlock gate then appears on every cold launch.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BiometricSettingsScreen(
    vm: AppViewModel,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val activity = context as? FragmentActivity
    val scope = rememberCoroutineScope()

    val capability = remember { BiometricAuth.capability(context) }
    val canEnable = capability.canUseAnyAuth

    var enabled by remember { mutableStateOf(vm.biometricEnabled) }
    var isWorking by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    fun toggle(newValue: Boolean) {
        if (isWorking) return
        error = null
        if (!newValue) {
            vm.setBiometricEnabled(false)
            enabled = false
            return
        }
        val act = activity ?: run {
            error = "Biometric sign-in is unavailable on this device."
            return
        }
        isWorking = true
        scope.launch {
            val result = BiometricAuth.authenticate(
                activity = act,
                title = "Enable biometric sign-in",
                subtitle = vm.userEmail,
                reason = "Confirm it's you to enable faster sign-in.",
            )
            isWorking = false
            when (result) {
                BiometricResult.Success -> {
                    vm.setBiometricEnabled(true)
                    enabled = true
                }
                BiometricResult.Cancelled -> {}
                is BiometricResult.Failed -> error = result.message
            }
        }
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Sign-in") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            SectionHeader("Biometric login", onLight = true)
            VineyardCard {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    Box(
                        modifier = Modifier.size(44.dp).clip(CircleShape).background(VineColors.LeafGreen.copy(alpha = 0.15f)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(Icons.Filled.Fingerprint, contentDescription = null, tint = VineColors.LeafGreen)
                    }
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            "Use ${capability.displayName} for login",
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textPrimary,
                        )
                        Text(
                            "Sign in faster without retyping your password.",
                            fontSize = 13.sp,
                            color = vine.textSecondary,
                        )
                    }
                    Switch(
                        checked = enabled,
                        onCheckedChange = { toggle(it) },
                        enabled = canEnable && !isWorking,
                    )
                }
            }

            Text(
                when {
                    !canEnable -> "Biometric login isn't available on this device. Set up a fingerprint, face unlock, or a screen lock (PIN/pattern) in your device settings."
                    enabled -> "Biometric sign-in is enabled${vm.biometricSavedEmail?.let { " for $it" } ?: ""}. You'll be asked to unlock each time you open VineTrack."
                    else -> "Biometric login uses your device's secure authentication. Your password is never stored."
                },
                fontSize = 13.sp,
                color = vine.textSecondary,
            )

            error?.let { message ->
                VineyardCard {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Icon(Icons.Filled.WarningAmber, contentDescription = null, tint = VineColors.Destructive)
                        Text(message, color = VineColors.Destructive, fontSize = 13.sp)
                    }
                }
            }
        }
    }
}
