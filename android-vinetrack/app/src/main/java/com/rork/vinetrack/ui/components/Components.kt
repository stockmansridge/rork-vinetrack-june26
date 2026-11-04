package com.rork.vinetrack.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.ui.theme.LocalVineColors

/** Standard back arrow for a TopAppBar `navigationIcon`. */
@Composable
fun BackNavIcon(onBack: () -> Unit) {
    IconButton(onClick = onBack) {
        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
    }
}

/** Rounded surface card, mirrors iOS `VineyardCard`. */
@Composable
fun VineyardCard(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(vine.cardBackground)
            .border(BorderStroke(0.5.dp, vine.cardBorder), RoundedCornerShape(14.dp))
            .padding(16.dp)
    ) { content() }
}

/**
 * Uppercase section header on tinted backgrounds (iOS `plainSectionHeader`).
 *
 * Set [fillWidth] to false when the header shares a row with a trailing control
 * (for example a ⓘ help button) that should sit directly beside the text
 * rather than at the far edge.
 */
@Composable
fun SectionHeader(
    title: String,
    onLight: Boolean = false,
    modifier: Modifier = Modifier,
    fillWidth: Boolean = true,
) {
    val vine = LocalVineColors.current
    Text(
        text = title.uppercase(),
        fontSize = 13.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 0.5.sp,
        color = if (onLight) vine.textSecondary else Color.White.copy(alpha = 0.95f),
        modifier = if (fillWidth) modifier.fillMaxWidth() else modifier,
    )
}

/** Tile with circular icon badge, used for operational tools (iOS `operationalTile`). */
@Composable
fun OperationalTile(
    title: String,
    subtitle: String,
    icon: ImageVector,
    tint: Color,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = modifier
            .height(138.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(vine.cardBackground)
            .border(BorderStroke(0.5.dp, vine.cardBorder), RoundedCornerShape(14.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            modifier = Modifier
                .size(44.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(tint.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(22.dp))
        }
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                title,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                color = vine.textPrimary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (subtitle.isNotEmpty()) {
                Text(subtitle, fontSize = 12.sp, color = vine.textSecondary, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

/** Compact stat column used in the vineyard overview card. */
@Composable
fun OverviewStat(value: String, label: String, icon: ImageVector, iconTint: Color, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(icon, contentDescription = null, tint = iconTint, modifier = Modifier.size(18.dp))
        Text(value, fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
        Text(label, fontSize = 12.sp, color = vine.textSecondary)
    }
}

/**
 * Painter-based variant of [OverviewStat] for drawable icons such as the
 * grape vine leaf brand mark (matches the iOS Vines stat icon).
 */
@Composable
fun OverviewStat(value: String, label: String, icon: Painter, iconTint: Color, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(icon, contentDescription = null, tint = iconTint, modifier = Modifier.size(18.dp))
        Text(value, fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
        Text(label, fontSize = 12.sp, color = vine.textSecondary)
    }
}

@Composable
fun StatusBadge(text: String, tint: Color) {
    Box(
        modifier = Modifier
            .clip(CircleShape)
            .background(tint.copy(alpha = 0.15f))
            .padding(horizontal = 8.dp, vertical = 4.dp)
    ) {
        Text(text, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = tint)
    }
}

/**
 * Standard empty-state placeholder. Pass [actionLabel] + [onAction] to render the shared
 * primary CTA button instead of duplicating an inline button at the call site.
 */
@Composable
fun EmptyState(
    icon: ImageVector,
    title: String,
    message: String? = null,
    actionLabel: String? = null,
    actionIcon: ImageVector = Icons.Filled.Add,
    onAction: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = modifier.fillMaxWidth().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Box(
            modifier = Modifier.size(96.dp).clip(CircleShape).background(com.rork.vinetrack.ui.theme.VineColors.PrimaryAccent.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = com.rork.vinetrack.ui.theme.VineColors.PrimaryAccent, modifier = Modifier.size(44.dp))
        }
        Text(title, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
        if (message != null) {
            Text(
                message,
                fontSize = 15.sp,
                color = vine.textSecondary,
                style = MaterialTheme.typography.bodyMedium,
            )
        }
        if (actionLabel != null && onAction != null) {
            Button(
                onClick = onAction,
                colors = ButtonDefaults.buttonColors(
                    containerColor = com.rork.vinetrack.ui.theme.VineColors.Primary,
                ),
            ) {
                Icon(actionIcon, contentDescription = null, modifier = Modifier.size(18.dp))
                Text("  $actionLabel")
            }
        }
    }
    Spacer(Modifier.height(0.dp))
}

// ---------------------------------------------------------------------------
// Shared blue action controls (Issue #55 UI consistency).
// One definition of "selected / primary" so screens stop hand-rolling green
// copies. Semantic status colours (completion green, warning orange/red) and
// pin/overlay colours are NOT routed through these.
// ---------------------------------------------------------------------------

/** Standard top-bar Add `+` in the shared action blue. Use in TopAppBar `actions`. */
@Composable
fun VineAddAction(onClick: () -> Unit, contentDescription: String, enabled: Boolean = true) {
    IconButton(onClick = onClick, enabled = enabled) {
        Icon(
            Icons.Filled.Add,
            contentDescription = contentDescription,
            tint = com.rork.vinetrack.ui.theme.VineColors.Primary.copy(alpha = if (enabled) 1f else 0.38f),
        )
    }
}

/** Filled blue primary button colours (iOS `.borderedProminent` parity). */
@Composable
fun vinePrimaryButtonColors() = ButtonDefaults.buttonColors(
    containerColor = com.rork.vinetrack.ui.theme.VineColors.Primary,
    contentColor = Color.White,
    disabledContainerColor = com.rork.vinetrack.ui.theme.VineColors.Primary.copy(alpha = 0.35f),
    disabledContentColor = Color.White.copy(alpha = 0.8f),
)

/** Rounded filter pill: selected = solid blue, unselected = neutral surface. */
@Composable
fun VineFilterPill(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val vine = LocalVineColors.current
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(50))
            .background(
                if (selected) com.rork.vinetrack.ui.theme.VineColors.Primary else vine.cardBackground,
            )
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 7.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            color = if (selected) Color.White else vine.textPrimary,
            maxLines = 1,
        )
    }
}

/**
 * Shared segmented control (iOS segmented Picker parity). Selected segment is
 * solid blue. Labels wrap to two lines rather than clipping at large font scales.
 */
@Composable
fun VineSegmented(
    options: List<String>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    val blue = com.rork.vinetrack.ui.theme.VineColors.Primary
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(vine.appBackground)
            .border(BorderStroke(1.dp, blue.copy(alpha = 0.35f)), RoundedCornerShape(10.dp))
            .padding(2.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        options.forEachIndexed { index, label ->
            val selected = index == selectedIndex
            Box(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (selected) blue else Color.Transparent)
                    .clickable { onSelect(index) }
                    .padding(horizontal = 8.dp, vertical = 8.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    label,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = if (selected) Color.White else vine.textPrimary,
                    maxLines = 2,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
            }
        }
    }
}
