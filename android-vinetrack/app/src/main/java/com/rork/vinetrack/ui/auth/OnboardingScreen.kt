package com.rork.vinetrack.ui.auth

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Group
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.R
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch

private data class OnboardingPage(
    val icon: ImageVector,
    val iconColor: Color,
    val title: String,
    val message: String,
    val showLogo: Boolean = false,
)

private val onboardingPages = listOf(
    OnboardingPage(
        icon = Icons.Filled.Spa,
        iconColor = VineColors.LeafGreen,
        title = "Welcome to VineTrack",
        message = "Built by vignerons for vignerons — manage vineyard observations, spray records, irrigation, disease risk and team activity in one place.",
        showLogo = true,
    ),
    OnboardingPage(
        icon = Icons.Filled.LocationOn,
        iconColor = Color(0xFF007AFF),
        title = "Track work in the vineyard",
        message = "Drop pins for repairs and observations, record trips, capture growth stages and keep your team aligned row by row.",
    ),
    OnboardingPage(
        icon = Icons.Filled.Cloud,
        iconColor = Color(0xFFFF9500),
        title = "Smarter vineyard decisions",
        message = "Use weather data, irrigation recommendations and disease-risk alerts for Downy, Powdery and Botrytis to help prioritise vineyard work.",
    ),
    OnboardingPage(
        icon = Icons.Filled.Group,
        iconColor = Color(0xFFAF52DE),
        title = "Sync with your vineyard team",
        message = "Choose or create a vineyard, invite team members, manage roles and keep records synced securely across devices.",
    ),
)

/**
 * First-launch welcome carousel shown once after sign-in, mirroring the iOS
 * `OnboardingView`. Four swipeable pages with Continue / Skip / Get Started,
 * invoking [onComplete] (which persists the completed flag) when finished.
 */
@Composable
fun OnboardingScreen(onComplete: () -> Unit) {
    val pagerState = rememberPagerState(pageCount = { onboardingPages.size })
    val scope = rememberCoroutineScope()
    val isLastPage = pagerState.currentPage == onboardingPages.size - 1

    Box(
        Modifier
            .fillMaxSize()
            .background(VineColors.AppBackgroundLight),
    ) {
        Column(Modifier.fillMaxSize()) {
            HorizontalPager(
                state = pagerState,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
                contentPadding = PaddingValues(horizontal = 0.dp),
            ) { index ->
                PageContent(onboardingPages[index])
            }

            PageIndicator(
                count = onboardingPages.size,
                current = pagerState.currentPage,
                modifier = Modifier
                    .align(Alignment.CenterHorizontally)
                    .padding(bottom = 16.dp),
            )

            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 24.dp)
                    .padding(bottom = 32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Button(
                    onClick = {
                        if (isLastPage) {
                            onComplete()
                        } else {
                            scope.launch { pagerState.animateScrollToPage(pagerState.currentPage + 1) }
                        }
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(52.dp),
                    shape = RoundedCornerShape(14.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen),
                ) {
                    Text(
                        if (isLastPage) "Get Started" else "Continue",
                        fontSize = 17.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Color.White,
                    )
                }
                if (!isLastPage) {
                    TextButton(onClick = onComplete) {
                        Text("Skip", color = VineColors.TextSecondaryLight, fontSize = 15.sp)
                    }
                }
            }
        }
    }
}

@Composable
private fun PageContent(page: OnboardingPage) {
    Column(
        Modifier
            .fillMaxSize()
            .padding(horizontal = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        if (page.showLogo) {
            Image(
                painter = painterResource(R.drawable.vinetrack_logo),
                contentDescription = null,
                modifier = Modifier
                    .size(140.dp)
                    .border(1.dp, Color.White.copy(alpha = 0.6f), RoundedCornerShape(30.dp))
                    .padding(2.dp),
            )
        } else {
            Box(
                Modifier
                    .size(140.dp)
                    .background(page.iconColor.copy(alpha = 0.15f), CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    page.icon,
                    contentDescription = null,
                    tint = page.iconColor,
                    modifier = Modifier.size(64.dp),
                )
            }
        }
        Spacer(Modifier.height(24.dp))
        Text(
            page.title,
            fontSize = 26.sp,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center,
            color = VineColors.TextPrimaryLight,
        )
        Spacer(Modifier.height(16.dp))
        Text(
            page.message,
            fontSize = 16.sp,
            color = VineColors.TextSecondaryLight,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun PageIndicator(count: Int, current: Int, modifier: Modifier = Modifier) {
    androidx.compose.foundation.layout.Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        repeat(count) { index ->
            val active = index == current
            Box(
                Modifier
                    .size(if (active) 10.dp else 8.dp)
                    .background(
                        if (active) VineColors.LeafGreen else VineColors.TextSecondaryLight.copy(alpha = 0.35f),
                        CircleShape,
                    ),
            )
        }
    }
}
