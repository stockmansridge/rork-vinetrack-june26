package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.RestartAlt
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.VineyardAccessMatrix
import com.rork.vinetrack.data.model.Vineyard
import com.rork.vinetrack.ui.theme.VineColors

/**
 * Phase 2F restricted-vineyard experience (parity with iOS
 * `RestrictedVineyardView`). Shown when the ACCOUNT still has usable access
 * but the server matrix confirms the previously selected vineyard has lost
 * its entitlement. Deliberately NOT the paywall: the user can switch to
 * another accessible vineyard, restore purchases, or re-check access.
 */
@Composable
fun RestrictedVineyardScreen(
    vineyards: List<Vineyard>,
    accessMatrix: VineyardAccessMatrix?,
    selectedVineyardId: String?,
    isRestoring: Boolean,
    isChecking: Boolean,
    onChooseVineyard: (String) -> Unit,
    onRecheckAccess: () -> Unit,
    onRestorePurchases: () -> Unit,
    onSignOut: () -> Unit,
) {
    val selectedEntry = selectedVineyardId?.let { accessMatrix?.entryFor(it) }
    val selectedName = selectedEntry?.vineyardName
        ?: vineyards.firstOrNull { it.id == selectedVineyardId }?.name
        ?: "this vineyard"
    val isOwner = (selectedEntry?.membershipRole ?: "").equals("owner", ignoreCase = true)
    val accessibleIds = accessMatrix?.accessibleVineyardIds.orEmpty().toSet()
    val accessibleVineyards = vineyards.filter { it.id in accessibleIds }

    Box(
        Modifier
            .fillMaxSize()
            .background(VineColors.AppBackgroundLight)
            .systemBarsPadding(),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Spacer(Modifier.height(16.dp))

            Box(
                modifier = Modifier
                    .size(88.dp)
                    .background(Color(0xFFFFB74D).copy(alpha = 0.16f), CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Filled.Lock,
                    contentDescription = null,
                    tint = Color(0xFFEF6C00),
                    modifier = Modifier.size(40.dp),
                )
            }

            Text(
                text = "Access to $selectedName has expired",
                fontSize = 20.sp,
                fontWeight = FontWeight.SemiBold,
                color = VineColors.TextPrimaryLight,
                textAlign = TextAlign.Center,
            )
            Text(
                text = if (isOwner) {
                    "This vineyard no longer has an active subscription, trial, or grant. Review billing to restore access for you and your team. Your other vineyards are unaffected."
                } else {
                    "Access for this vineyard is managed by its Vineyard Owner. You can keep working in your other vineyards, and any pending invitations remain available."
                },
                fontSize = 14.sp,
                color = VineColors.TextSecondaryLight,
                textAlign = TextAlign.Center,
                lineHeight = 20.sp,
            )

            if (accessibleVineyards.isNotEmpty()) {
                Spacer(Modifier.height(4.dp))
                Text(
                    text = "You still have access to these vineyards",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = VineColors.TextSecondaryLight,
                    modifier = Modifier.fillMaxWidth(),
                )
                accessibleVineyards.forEach { vineyard ->
                    Card(
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(14.dp),
                        colors = CardDefaults.cardColors(containerColor = VineColors.CardBackgroundLight),
                        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp),
                        onClick = { onChooseVineyard(vineyard.id) },
                    ) {
                        Row(
                            Modifier.padding(16.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(36.dp)
                                    .background(VineColors.LeafGreen.copy(alpha = 0.14f), CircleShape),
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(
                                    Icons.Filled.Spa,
                                    contentDescription = null,
                                    tint = VineColors.LeafGreen,
                                    modifier = Modifier.size(18.dp),
                                )
                            }
                            Column(Modifier.weight(1f)) {
                                Text(
                                    vineyard.name,
                                    fontWeight = FontWeight.SemiBold,
                                    fontSize = 15.sp,
                                    color = VineColors.TextPrimaryLight,
                                    maxLines = 2,
                                )
                                val role = accessMatrix?.entryFor(vineyard.id)?.membershipRole
                                if (!role.isNullOrBlank()) {
                                    Text(
                                        role.replaceFirstChar { it.uppercase() },
                                        fontSize = 12.sp,
                                        color = VineColors.TextSecondaryLight,
                                    )
                                }
                            }
                            Icon(
                                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                                contentDescription = null,
                                tint = VineColors.TextSecondaryLight,
                            )
                        }
                    }
                }
            }

            Spacer(Modifier.height(8.dp))

            Button(
                onClick = onRecheckAccess,
                enabled = !isChecking,
                modifier = Modifier.fillMaxWidth().height(50.dp),
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen),
            ) {
                if (isChecking) {
                    CircularProgressIndicator(
                        color = Color.White,
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.size(8.dp))
                    Text("Checking access…", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                } else {
                    Icon(Icons.Filled.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(8.dp))
                    Text("Check access again", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                }
            }
            OutlinedButton(
                onClick = onRestorePurchases,
                enabled = !isRestoring,
                modifier = Modifier.fillMaxWidth().height(50.dp),
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = VineColors.LeafGreen),
            ) {
                if (isRestoring) {
                    CircularProgressIndicator(
                        color = VineColors.LeafGreen,
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.size(8.dp))
                    Text("Restoring…", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                } else {
                    Icon(Icons.Filled.RestartAlt, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(8.dp))
                    Text("Restore Purchases", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                }
            }

            Spacer(Modifier.weight(1f))

            TextButton(onClick = onSignOut) {
                Text("Sign out", color = VineColors.TextSecondaryLight)
            }
        }
    }
}
