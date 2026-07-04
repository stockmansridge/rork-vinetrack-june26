package com.rork.vinetrack.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.rork.vinetrack.ui.auth.BiometricLockScreen
import com.rork.vinetrack.ui.auth.LoginScreen
import com.rork.vinetrack.ui.auth.OnboardingScreen
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.components.LoginVineyardBackground
import com.rork.vinetrack.ui.main.MainScaffold
import com.rork.vinetrack.ui.theme.VineColors
import androidx.compose.material.icons.filled.Spa

@Composable
fun RootScreen() {
    val vm: AppViewModel = viewModel()
    val state by vm.ui.collectAsStateWithLifecycle()
    val authState by vm.authState.collectAsStateWithLifecycle()

    // Silently revalidate/refresh the Supabase session whenever the app
    // returns to the foreground, so a stale token never bounces the user to
    // the login screen on their next save after long idle.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_START) vm.onAppForegrounded()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    when (state.route) {
        AppRoute.Restoring -> SplashScreen()
        AppRoute.Login -> LoginScreen(
            state = authState,
            onSignIn = vm::signIn,
            onSignUp = vm::signUp,
            onForgotPassword = { email, cb -> vm.sendPasswordReset(email, cb) },
            onResetPassword = { email, pin, newPassword, cb ->
                vm.resetPasswordWithPin(email, pin, newPassword, cb)
            },
        )
        AppRoute.BiometricLock -> BiometricLockScreen(
            savedEmail = vm.biometricSavedEmail,
            onUnlocked = vm::onBiometricUnlocked,
            onUseDifferentAccount = vm::signOutFromBiometricLock,
        )
        AppRoute.VineyardLoading -> LoadingScreen("Loading vineyards…")
        AppRoute.VineyardLoadFailed -> LoadFailedScreen(
            onRetry = vm::retryVineyardLoad,
            onSignOut = vm::signOut,
        )
        AppRoute.NoVineyards -> NoVineyardsScreen(onSignOut = vm::signOut)
        AppRoute.Main ->
            if (!state.onboardingCompleted) OnboardingScreen(onComplete = vm::completeOnboarding)
            else MainScaffold(vm, state)
    }
}

@Composable
private fun SplashScreen() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        LoginVineyardBackground()
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Box(
                modifier = Modifier.size(96.dp).background(Color.White.copy(alpha = 0.14f), RoundedCornerShape(24.dp)),
                contentAlignment = Alignment.Center,
            ) { Text("\uD83C\uDF47", fontSize = 48.sp) }
            Text("VineTrack", color = Color.White, fontSize = 32.sp, fontWeight = FontWeight.Bold)
            CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp)
        }
    }
}

@Composable
private fun LoadingScreen(message: String) {
    Box(
        Modifier.fillMaxSize().background(VineColors.AppBackgroundLight),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
            CircularProgressIndicator(color = VineColors.LeafGreen)
            Text(message, color = VineColors.TextSecondaryLight)
        }
    }
}

@Composable
private fun LoadFailedScreen(onRetry: () -> Unit, onSignOut: () -> Unit) {
    Box(
        Modifier.fillMaxSize().background(VineColors.AppBackgroundLight).padding(24.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Icon(Icons.Filled.CloudOff, contentDescription = null, tint = VineColors.Warning, modifier = Modifier.size(44.dp))
            Text("Couldn't load your vineyards", fontWeight = FontWeight.Bold, fontSize = 18.sp)
            Text(
                "We couldn't reach the server to confirm your vineyard access. Check your connection and try again.",
                color = VineColors.TextSecondaryLight,
                textAlign = TextAlign.Center,
            )
            Button(onClick = onRetry, colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary)) {
                Text("Retry")
            }
            TextButton(onClick = onSignOut) { Text("Sign out", color = VineColors.TextSecondaryLight) }
        }
    }
}

@Composable
private fun NoVineyardsScreen(onSignOut: () -> Unit) {
    Box(
        Modifier.fillMaxSize().background(VineColors.AppBackgroundLight),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            EmptyState(
                icon = Icons.Filled.Spa,
                title = "No vineyards yet",
                message = "You're not a member of any vineyard yet. Ask an owner to invite you, or create one from the web portal.",
            )
            TextButton(onClick = onSignOut) { Text("Sign out", color = VineColors.TextSecondaryLight) }
        }
    }
}
