package com.rork.vinetrack.ui.screens

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Storefront
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.subscription.SubscriptionUiState
import com.rork.vinetrack.ui.theme.VineColors

/**
 * Subscription / paywall screen — Android port of the iOS
 * `SubscriptionPaywallView`. Sells only the Google Play Solo yearly plan;
 * Team/Enterprise/portal access is honoured server-side and surfaced here as
 * guidance only. Safely handles an empty offering (Play product not yet live).
 */
@Composable
fun SubscriptionScreen(
    state: SubscriptionUiState,
    onPurchase: (Activity, String) -> Unit,
    onRestore: () -> Unit,
    onRecheckAccess: () -> Unit,
    onSignOut: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val activity = LocalContext.current.findActivity()

    Box(
        modifier
            .fillMaxSize()
            .background(VineColors.AppBackgroundLight),
    ) {
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(22.dp),
        ) {
            Header()

            if (state.isOffline) {
                OfflineNotice()
            }

            when {
                state.isLoading && state.packages.isEmpty() -> LoadingCard()
                state.packages.isEmpty() -> EmptyOfferingCard(
                    isConfigured = state.isConfigured,
                    isRestoring = state.isRestoring,
                    onRetry = onRecheckAccess,
                    onRestore = onRestore,
                )
                else -> PackageList(
                    state = state,
                    onPurchase = { packageId ->
                        if (activity != null) onPurchase(activity, packageId)
                    },
                )
            }

            if (state.packages.isNotEmpty()) {
                RestoreSection(isRestoring = state.isRestoring, onRestore = onRestore)
            }

            state.lastError?.let { error ->
                Text(
                    error,
                    color = VineColors.Destructive,
                    fontSize = 13.sp,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(horizontal = 8.dp),
                )
            }

            TeamEnterpriseCard(isChecking = state.isLoading, onRecheckAccess = onRecheckAccess)

            TextButton(onClick = onSignOut) {
                Text("Sign out", color = VineColors.Destructive)
            }
        }
    }
}

@Composable
private fun Header() {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier
                .size(86.dp)
                .background(VineColors.DarkGreen, RoundedCornerShape(20.dp)),
            contentAlignment = Alignment.Center,
        ) { Text("\uD83C\uDF47", fontSize = 44.sp) }

        Text(
            "Start with 3 months free",
            fontSize = 28.sp,
            fontWeight = FontWeight.Bold,
            color = Color(0xFF1A4D29),
            textAlign = TextAlign.Center,
        )
        Text(
            "No charge today. Billing starts only after your free trial unless you cancel.",
            fontSize = 14.sp,
            color = VineColors.TextSecondaryLight,
            textAlign = TextAlign.Center,
        )
        Text(
            "Solo gives one user access to VineTrack's mobile app, making it easy to capture vineyard work, trips, pins and field records directly from the vineyard.",
            fontSize = 13.sp,
            color = VineColors.TextSecondaryLight,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun PackageList(
    state: SubscriptionUiState,
    onPurchase: (String) -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(22.dp),
        color = VineColors.CardBackgroundLight,
        modifier = Modifier
            .fillMaxWidth()
            .border(0.5.dp, VineColors.SeparatorLight, RoundedCornerShape(22.dp)),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            state.packages.forEach { pkg ->
                Surface(
                    shape = RoundedCornerShape(16.dp),
                    color = VineColors.AppBackgroundLight,
                    onClick = { if (!state.isPurchasing) onPurchase(pkg.packageId) },
                    enabled = !state.isPurchasing,
                    modifier = Modifier
                        .fillMaxWidth()
                        .border(
                            1.dp,
                            VineColors.LeafGreen.copy(alpha = 0.25f),
                            RoundedCornerShape(16.dp),
                        ),
                ) {
                    Row(
                        Modifier.padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                            Text(
                                pkg.title,
                                fontWeight = FontWeight.SemiBold,
                                fontSize = 17.sp,
                                color = VineColors.TextPrimaryLight,
                            )
                            Text(
                                pkg.renewalLine,
                                fontWeight = FontWeight.SemiBold,
                                fontSize = 15.sp,
                                color = VineColors.LeafGreen,
                            )
                            Text(
                                pkg.productTitle,
                                fontSize = 12.sp,
                                color = VineColors.TextSecondaryLight,
                            )
                        }
                        if (state.isPurchasing) {
                            CircularProgressIndicator(
                                color = VineColors.LeafGreen,
                                strokeWidth = 2.dp,
                                modifier = Modifier.size(24.dp),
                            )
                        } else {
                            Icon(
                                Icons.AutoMirrored.Filled.ArrowForward,
                                contentDescription = "Start free trial",
                                tint = VineColors.LeafGreen,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun RestoreSection(isRestoring: Boolean, onRestore: () -> Unit) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        OutlinedButton(onClick = onRestore, enabled = !isRestoring) {
            Icon(Icons.Filled.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text("Restore Purchases")
            if (isRestoring) {
                Spacer(Modifier.width(8.dp))
                CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
            }
        }
        Text(
            "Google Play confirms the trial and billing date before you subscribe. Cancel anytime through Google Play — at least 24 hours before the trial ends to avoid renewal.",
            fontSize = 12.sp,
            color = VineColors.TextSecondaryLight,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun LoadingCard() {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp),
        modifier = Modifier.padding(vertical = 24.dp),
    ) {
        CircularProgressIndicator(color = VineColors.LeafGreen)
        Text(
            "Loading subscription options…",
            fontSize = 14.sp,
            color = VineColors.TextSecondaryLight,
        )
    }
}

/**
 * Shown when RevenueCat returns no offering/packages (e.g. the Google Play
 * product isn't live yet) or the SDK key is missing. Never blank, never a
 * crash — offers Retry / Restore, and sign-out stays available below.
 */
@Composable
private fun EmptyOfferingCard(
    isConfigured: Boolean,
    isRestoring: Boolean,
    onRetry: () -> Unit,
    onRestore: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(22.dp),
        color = VineColors.CardBackgroundLight,
        modifier = Modifier
            .fillMaxWidth()
            .border(0.5.dp, VineColors.SeparatorLight, RoundedCornerShape(22.dp)),
    ) {
        Column(
            Modifier.padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Icon(
                Icons.Filled.Storefront,
                contentDescription = null,
                tint = VineColors.LeafGreen,
                modifier = Modifier.size(40.dp),
            )
            Text(
                "Subscription options are being set up. Please try again shortly.",
                fontSize = 15.sp,
                color = VineColors.TextPrimaryLight,
                textAlign = TextAlign.Center,
            )
            if (!isConfigured) {
                Text(
                    "The subscription service isn't configured in this build yet.",
                    fontSize = 12.sp,
                    color = VineColors.TextSecondaryLight,
                    textAlign = TextAlign.Center,
                )
            }
            Button(
                onClick = onRetry,
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen),
            ) { Text("Retry") }
            OutlinedButton(onClick = onRestore, enabled = !isRestoring) {
                Text("Restore Purchases")
                if (isRestoring) {
                    Spacer(Modifier.width(8.dp))
                    CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
                }
            }
        }
    }
}

@Composable
private fun TeamEnterpriseCard(isChecking: Boolean, onRecheckAccess: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = VineColors.CardBackgroundLight,
        modifier = Modifier
            .fillMaxWidth()
            .border(0.5.dp, VineColors.SeparatorLight, RoundedCornerShape(16.dp)),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Filled.Groups,
                    contentDescription = null,
                    tint = VineColors.DarkGreen,
                    modifier = Modifier.size(22.dp),
                )
                Spacer(Modifier.width(10.dp))
                Text(
                    "Team or Enterprise access",
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 15.sp,
                    color = VineColors.TextPrimaryLight,
                )
            }
            Text(
                "Team and Enterprise plans are managed through the VineTrack portal. If your vineyard already has a Team or Enterprise plan, ask an owner or admin to invite you.",
                fontSize = 13.sp,
                color = VineColors.TextSecondaryLight,
            )
            TextButton(onClick = onRecheckAccess, enabled = !isChecking) {
                Text("I already have access — check again", color = VineColors.DarkGreen)
                if (isChecking) {
                    Spacer(Modifier.width(8.dp))
                    CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
                }
            }
        }
    }
}

@Composable
private fun OfflineNotice() {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = VineColors.Warning.copy(alpha = 0.12f),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.Filled.CloudOff,
                contentDescription = null,
                tint = VineColors.Warning,
                modifier = Modifier.size(20.dp),
            )
            Spacer(Modifier.width(10.dp))
            Text(
                "You're offline. Connect to the internet to verify your access or start a subscription.",
                fontSize = 13.sp,
                color = VineColors.TextPrimaryLight,
            )
        }
    }
}

/** Unwrap the Activity hosting this composition (needed for the Play billing sheet). */
private fun Context.findActivity(): Activity? {
    var current: Context = this
    while (current is ContextWrapper) {
        if (current is Activity) return current
        current = current.baseContext
    }
    return null
}
