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
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.SeasonScope
import com.rork.vinetrack.data.SeasonSelection
import com.rork.vinetrack.data.SeasonWindow
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import com.rork.vinetrack.ui.theme.VineExtraColors
import java.time.format.DateTimeFormatter
import java.util.Locale

private val seasonRangeFormatter: DateTimeFormatter =
    DateTimeFormatter.ofPattern("d MMM yyyy", Locale.getDefault())

/**
 * Season/Vintage selector for reporting screens — the same chip pattern the
 * Yield Reports screen uses, extracted so every dated function shares one
 * control instead of each inventing its own list.
 *
 * Contract (identical on iOS):
 * * **All vintages** is always first and removes the date restriction entirely.
 * * Only vintages that actually hold non-deleted records for this vineyard and
 *   surface are offered — no fixed span, no empty seasons.
 * * Every represented vintage appears, however far back it goes.
 * * The current season is selected by default only when it holds records;
 *   otherwise the screen opens on All.
 *
 * The selection is a **date range**, not a stored column: callers take the
 * resolved [SeasonScope] and filter records by whichever event-date column they
 * already have. Changing the selection refreshes lists, totals, charts and
 * exports together, because they all read the same scope.
 */
@Composable
fun SeasonSelector(
    scope: SeasonScope,
    onSelect: (SeasonSelection) -> Unit,
    modifier: Modifier = Modifier,
    /**
     * Set false ONLY for server-paged surfaces whose RPC cannot return every
     * vintage in one call (Irrigation Records). Offering an "All vintages" chip
     * there would silently show a single vintage's data under an All heading,
     * which is worse than not offering it.
     */
    allowAll: Boolean = true,
) {
    val vine = LocalVineColors.current

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
                .semantics { contentDescription = "Season, currently ${scope.title}" },
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (allowAll) {
                SeasonChip(
                    label = SeasonScope.ALL_TITLE,
                    isSelected = scope.isAll,
                    vine = vine,
                ) { onSelect(SeasonSelection.All) }
            }

            scope.available.forEach { vintage ->
                SeasonChip(
                    label = SeasonWindow.label(vintage, scope.currentVintage),
                    isSelected = scope.vintage == vintage,
                    vine = vine,
                ) {
                    // Choosing the current season returns the screen to its
                    // automatic state, so it keeps rolling over by itself.
                    onSelect(
                        if (vintage == scope.currentVintage) SeasonSelection.Automatic
                        else SeasonSelection.Vintage(vintage),
                    )
                }
            }
        }
        Text(
            text = rangeText(scope),
            style = MaterialTheme.typography.bodySmall,
            color = vine.textSecondary,
            modifier = Modifier.padding(top = 6.dp),
        )
    }
}

@Composable
private fun SeasonChip(
    label: String,
    isSelected: Boolean,
    vine: VineExtraColors,
    onClick: () -> Unit,
) {
    Text(
        text = label,
        color = if (isSelected) Color.White else vine.textSecondary,
        fontSize = 13.sp,
        fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(if (isSelected) VineColors.LeafGreen else vine.cardBackground)
            .clickable(enabled = !isSelected) { onClick() }
            .defaultMinSize(minHeight = 44.dp)
            .padding(horizontal = 14.dp, vertical = 13.dp),
    )
}

/** "1 Jul 2026 – 30 Jun 2027" — inclusive dates, though filtering is half-open. */
private fun rangeText(scope: SeasonScope): String {
    val window = scope.window
        ?: return if (scope.available.isEmpty()) "No dated records yet" else "Every record, all seasons"
    return "${window.start.format(seasonRangeFormatter)} – ${window.displayEnd.format(seasonRangeFormatter)}"
}
