package com.rork.vinetrack.ui.components

import androidx.annotation.DrawableRes
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.ui.theme.LocalVineColors

/**
 * A single page of a paged help sheet (iOS parity: `HelpPage` in
 * `HelpSheetView.swift`).
 *
 * Only [title] and [message] are required, so new pages can be added without
 * touching the sheet layout: image-led pages, plain text pages, or text plus a
 * smaller supporting line all render from the same model.
 */
data class HelpPage(
    val id: String,
    val title: String,
    val message: String,
    @param:DrawableRes val imageRes: Int? = null,
    val supporting: String? = null,
)

/**
 * Reusable swipeable help sheet, mirroring the iOS `HelpSheetView`.
 *
 * Pages are data-driven — appending to the [pages] list is the only change
 * needed to add a fourth or fifth page. Each page scrolls independently so long
 * copy never clips on small phones, and the pager height is a fraction of the
 * screen so the dots and Done action always stay visible.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HelpSheet(
    title: String,
    pages: List<HelpPage>,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    val pagerState = rememberPagerState(pageCount = { pages.size })
    val screenHeight = LocalConfiguration.current.screenHeightDp
    val pagerHeight = (screenHeight * 0.60f).coerceIn(320f, 620f).dp

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(modifier = Modifier.fillMaxWidth().padding(bottom = 20.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = title,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = vine.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = onDismiss) {
                    Text("Done", fontWeight = FontWeight.SemiBold)
                }
            }

            HorizontalPager(
                state = pagerState,
                modifier = Modifier.fillMaxWidth().height(pagerHeight),
            ) { index ->
                HelpPageContent(page = pages[index])
            }

            if (pages.size > 1) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    for (index in pages.indices) {
                        val active = index == pagerState.currentPage
                        Box(
                            modifier = Modifier
                                .padding(horizontal = 4.dp)
                                .size(if (active) 8.dp else 7.dp)
                                .clip(CircleShape)
                                .background(
                                    if (active) vine.textPrimary else vine.textSecondary.copy(alpha = 0.35f),
                                ),
                        )
                    }
                }
            }
        }
    }
}

/** One rendered help page: optional image, heading, body and supporting line. */
@Composable
private fun HelpPageContent(page: HelpPage) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        page.imageRes?.let { res ->
            Image(
                painter = androidx.compose.ui.res.painterResource(res),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(200.dp)
                    .clip(RoundedCornerShape(14.dp))
                    .background(Color.Black.copy(alpha = 0.05f)),
            )
        }
        Text(
            text = page.title,
            fontSize = 21.sp,
            fontWeight = FontWeight.Bold,
            color = vine.textPrimary,
        )
        Text(
            text = page.message,
            fontSize = 15.sp,
            lineHeight = 21.sp,
            color = vine.textPrimary,
        )
        page.supporting?.let { supporting ->
            Text(
                text = supporting,
                fontSize = 14.sp,
                lineHeight = 19.sp,
                color = vine.textSecondary,
            )
        }
        Spacer(Modifier.height(8.dp))
    }
}
