package com.rork.vinetrack.ui.auth

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Fingerprint
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.fragment.app.FragmentActivity
import com.rork.vinetrack.R
import com.rork.vinetrack.data.auth.BiometricAuth
import com.rork.vinetrack.data.auth.BiometricResult
import com.rork.vinetrack.ui.components.LoginVineyardBackground
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch

/**
 * Full-screen unlock gate shown after the session is restored when the user has
 * opted into biometric login. Mirrors the iOS BiometricLockView: auto-triggers
 * the prompt, allows a manual retry, and offers a "use a different account"
 * escape that signs out.
 */
@Composable
fun BiometricLockScreen(
    savedEmail: String?,
    onUnlocked: () -> Unit,
    onUseDifferentAccount: () -> Unit,
) {
    val context = LocalContext.current
    val activity = context as? FragmentActivity
    val scope = rememberCoroutineScope()
    var isWorking by remember { mutableStateOf(false) }
    var didAutoTrigger by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    fun unlock() {
        val act = activity ?: return
        if (isWorking) return
        isWorking = true
        error = null
        scope.launch {
            val result = BiometricAuth.authenticate(
                activity = act,
                title = "Welcome back",
                subtitle = savedEmail,
                reason = "Unlock VineTrack to continue.",
            )
            isWorking = false
            when (result) {
                BiometricResult.Success -> onUnlocked()
                BiometricResult.Cancelled -> error = null
                is BiometricResult.Failed -> error = result.message
            }
        }
    }

    LaunchedEffect(Unit) {
        if (!didAutoTrigger) {
            didAutoTrigger = true
            unlock()
        }
    }

    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        LoginVineyardBackground()
        Column(
            modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Image(
                painter = painterResource(R.drawable.vinetrack_logo),
                contentDescription = "VineTrack",
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .shadow(14.dp, RoundedCornerShape(24.dp), clip = false)
                    .size(96.dp)
                    .clip(RoundedCornerShape(24.dp))
                    .border(1.2.dp, Color.White.copy(alpha = 0.24f), RoundedCornerShape(24.dp)),
            )

            Spacer(Modifier.height(24.dp))

            Text("Welcome back", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 24.sp)
            if (!savedEmail.isNullOrBlank()) {
                Spacer(Modifier.height(6.dp))
                Text(savedEmail, color = Color.White.copy(alpha = 0.82f), fontSize = 15.sp)
            }
            Spacer(Modifier.height(6.dp))
            Text(
                "Use biometric unlock to continue.",
                color = Color.White.copy(alpha = 0.78f),
                fontSize = 13.sp,
                textAlign = TextAlign.Center,
            )

            Spacer(Modifier.height(28.dp))

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(52.dp)
                    .shadow(14.dp, RoundedCornerShape(16.dp), clip = false)
                    .clip(RoundedCornerShape(16.dp))
                    .background(VineColors.Info)
                    .clickable(enabled = !isWorking) { unlock() },
                contentAlignment = Alignment.Center,
            ) {
                if (isWorking) {
                    CircularProgressIndicator(color = Color.White, modifier = Modifier.size(24.dp), strokeWidth = 2.dp)
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.Fingerprint, contentDescription = null, tint = Color.White, modifier = Modifier.size(22.dp))
                        Spacer(Modifier.width(10.dp))
                        Text("Unlock with biometrics", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                    }
                }
            }

            error?.let { message ->
                Spacer(Modifier.height(16.dp))
                Text(
                    message,
                    color = Color.White,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .clip(RoundedCornerShape(12.dp))
                        .background(VineColors.Destructive.copy(alpha = 0.85f))
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                )
            }

            Spacer(Modifier.height(24.dp))

            TextButton(onClick = onUseDifferentAccount) {
                Text(
                    "Use a different account",
                    color = Color.White.copy(alpha = 0.9f),
                    fontWeight = FontWeight.Medium,
                )
            }
        }
    }
}
