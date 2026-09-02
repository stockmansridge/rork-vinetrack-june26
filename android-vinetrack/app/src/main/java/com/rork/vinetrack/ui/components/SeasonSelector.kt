package com.rork.vinetrack.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.SeasonWindow
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.time.format.DateTimeFormatter
import java.util.Locale

private val seasonRangeFormatter: DateTimeFormatter =
    DateTimeFormatter.ofPattern("d MMM yyyy", Locale.getDefault())

/**
 * Season/Vintage selector for reporting screens — the same chip pattern the
 * Yield Reports screen uses, extracted so every dated function shares one
 * control instead of each inventing its own list.
 *
 * The selection is a **date range**, not a stored column: callers take the
 * resulting [SeasonWindow] and filter records by whichever event-date column
 * they already have. Changing the selection must refresh lists, totals, charts
 * and exports together — not just a heading.
 */
@Composable
fun SeasonSelector(
    currentVintage: Int,
    selectedVintage: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    earliestRecordVintage: Int? = null,
    window: SeasonWindow? = null,
) {
    val vine = LocalVineColors.current
    val vintages = remember(currentVintage, selectedVintage, earliestRecordVintage) {
        SeasonWindow.availableVintages(currentVintage, selectedVintage, earliestRecordVintage)
    }

    Column(modifier = modifier.fillMaxWidth()) {
        Text(
            "Season",
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
            color = vine.textSecondary,
        )
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 8.dp)
                .horizontalScroll(rememberScrollState())
                .semantics { contentDescription = "Season, currently $selectedVintage" },
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            vintages.forEach { vintage ->
                val isSelected = vintage == selectedVintage
                Text(
                    text = SeasonWindow.label(vintage, currentVintage),
                    color = if (isSelected) Color.White else vine.textSecondary,
                    fontSize = 13.sp,
                    fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                    modifier = Modifier
                        .clip(RoundedCornerShape(50))
                        .background(if (isSelected) VineColors.LeafGreen else vine.cardBackground)
                        .clickable(enabled = !isSelected) { onSelect(vintage) }
                        .defaultMinSize(minHeight = 44.dp)
                        .padding(horizontal = 14.dp, vertical = 13.dp),
                )
            }
        }
        if (window != null) {
            Text(
                text = "${window.start.format(seasonRangeFormatter)} – " +
                    window.displayEnd.format(seasonRangeFormatter),
                style = MaterialTheme.typography.bodySmall,
                color = vine.textSecondary,
                modifier = Modifier.padding(top = 6.dp),
            )
        }
    }
}
