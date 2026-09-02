package com.rork.vinetrack.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
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
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/**
 * Shared Vintage option window — the single definition of which vintages a
 * selector offers, mirroring iOS `VintageWindow`.
 *
 * The platform-wide Vintage audit found every screen inventing its own list
 * (three to seven years, and in one case *calendar* years rather than
 * vintages). The rule is:
 *  - the current vintage is the default and is labelled "Current";
 *  - the previous 15 vintages are always offered;
 *  - a forward-planning screen may also offer the next vintage;
 *  - a vintage already being viewed is always present even if it falls outside
 *    that window, so a deep link into an old record can never select a missing
 *    option.
 *
 * The current vintage itself must come from [com.rork.vinetrack.data.VintageResolver]
 * (the mirror of the authoritative sql/119 resolver) — never from
 * `LocalDate.now().year`, which is only correct for a 1 January season start.
 */
object VintageWindow {

    /** Number of previous vintages offered alongside the current one. */
    const val PREVIOUS_COUNT = 15

    /** Descending option list. */
    fun options(
        currentVintage: Int,
        includesNextVintage: Boolean = false,
        selected: Int? = null,
    ): List<Int> {
        val years = sortedSetOf<Int>()
        if (includesNextVintage) years.add(currentVintage + 1)
        for (offset in 0..PREVIOUS_COUNT) years.add(currentVintage - offset)
        selected?.let { years.add(it) }
        return years.filter { it > 0 }.sortedDescending()
    }

    /** "2027 · Current" for the current vintage, otherwise "2027". */
    fun label(vintage: Int, currentVintage: Int): String =
        if (vintage == currentVintage) "$vintage · Current" else "$vintage"
}

/**
 * Horizontal chip-style Vintage selector.
 *
 * Changing the selection must refresh the screen's totals, charts, exports and
 * record lists — not just a heading. Callers drive that by keying their load on
 * the selected value.
 */
@Composable
fun VintageSelector(
    currentVintage: Int,
    selected: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    includesNextVintage: Boolean = false,
) {
    val vine = LocalVineColors.current
    val options = remember(currentVintage, includesNextVintage, selected) {
        VintageWindow.options(currentVintage, includesNextVintage, selected)
    }
    Row(
        modifier = modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .semantics { contentDescription = "Vintage, currently $selected" },
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        options.forEach { vintage ->
            val isSelected = vintage == selected
            Text(
                text = VintageWindow.label(vintage, currentVintage),
                color = if (isSelected) Color.White else vine.textSecondary,
                fontSize = 12.sp,
                fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .background(if (isSelected) VineColors.LeafGreen else vine.cardBackground)
                    .clickable { onSelect(vintage) }
                    .defaultMinSize(minHeight = 44.dp)
                    .padding(horizontal = 14.dp, vertical = 13.dp),
            )
        }
    }
}
