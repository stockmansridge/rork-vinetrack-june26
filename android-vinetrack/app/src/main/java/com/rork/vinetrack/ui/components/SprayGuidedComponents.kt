package com.rork.vinetrack.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.spray.SprayCarrierBasis
import com.rork.vinetrack.data.spray.SprayGeometrySource
import com.rork.vinetrack.data.spray.SprayGuidedBlocker
import com.rork.vinetrack.data.spray.SprayProductRateBasis
import java.text.DecimalFormat

/**
 * A selectable chip — targets (multi-select) and spray head target. The Compose
 * twin of the SwiftUI `GuidedChip`.
 */
@Composable
fun GuidedChip(
    label: String,
    isSelected: Boolean,
    accent: Color,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(9.dp),
        color = if (isSelected) accent else MaterialTheme.colorScheme.surfaceVariant,
        onClick = onClick,
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodySmall,
            fontWeight = FontWeight.Medium,
            color = if (isSelected) Color.White else MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
        )
    }
}

/**
 * A read-only panel of engine-calculated figures. Visually distinct from input
 * fields so it is obvious the operator does not type these values.
 */
@Composable
fun GuidedCalculatedPanel(
    title: String,
    accent: Color,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(accent.copy(alpha = 0.08f), RoundedCornerShape(10.dp))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = title.uppercase(),
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        content()
    }
}

/** One calculated figure. Never editable. */
@Composable
fun GuidedCalculatedRow(
    label: String,
    value: String,
    accent: Color,
    emphasis: Boolean = false,
    caption: String? = null,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = label,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (caption != null) {
                Text(
                    text = caption,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                )
            }
        }
        Text(
            text = value,
            style = if (emphasis) {
                MaterialTheme.typography.titleMedium
            } else {
                MaterialTheme.typography.bodyMedium
            },
            fontWeight = FontWeight.Bold,
            color = if (emphasis) accent else MaterialTheme.colorScheme.onSurface,
        )
    }
}

/**
 * An actionable blocker banner. Never a dead end: when block setup is at fault it
 * offers the route to fix it.
 */
@Composable
fun GuidedBlockerBanner(
    blocker: SprayGuidedBlocker,
    modifier: Modifier = Modifier,
    onFix: (() -> Unit)? = null,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(Color(0xFFFF9800).copy(alpha = 0.12f), RoundedCornerShape(10.dp))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            text = blocker.title,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.SemiBold,
            color = Color(0xFFE65100),
        )
        Text(
            text = blocker.message,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (blocker.needsBlockEditor && onFix != null) {
            Surface(
                shape = RoundedCornerShape(8.dp),
                color = Color.Transparent,
                onClick = onFix,
            ) {
                Text(
                    text = "Edit block details",
                    style = MaterialTheme.typography.bodySmall,
                    fontWeight = FontWeight.SemiBold,
                    color = Color(0xFFE65100),
                    modifier = Modifier.padding(vertical = 4.dp),
                )
            }
        }
    }
}

/** One line of the Review step. */
@Composable
fun GuidedReviewRow(label: String, value: String) {
    Row(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(132.dp),
        )
        Text(
            text = value,
            style = MaterialTheme.typography.bodySmall,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.weight(1f),
        )
    }
}

/**
 * Formatting helpers so the live sections and Review render engine values
 * identically, and identically to iOS. Pure presentation — no arithmetic beyond
 * rounding.
 */
object SprayGuidedFormat {

    private fun grouped(value: Double, decimals: Int): String {
        val pattern = if (decimals > 0) {
            "#,##0." + "0".repeat(decimals)
        } else {
            "#,##0"
        }
        return DecimalFormat(pattern).format(value)
    }

    fun hectares(value: Double?): String =
        if (value == null || !value.isFinite()) "—" else "${grouped(value, 2)} ha"

    fun metres(value: Double?, decimals: Int = 0): String =
        if (value == null || !value.isFinite()) "—" else "${grouped(value, decimals)} m"

    fun litres(value: Double?): String =
        if (value == null || !value.isFinite()) "—" else "${grouped(value, 0)} L"

    fun litresPerHectare(value: Double?): String =
        if (value == null || !value.isFinite()) "—" else "${grouped(value, 0)} L/ha"

    fun litresPer100m(value: Double?): String = when {
        value == null || !value.isFinite() -> "—"
        else -> "${grouped(value, if (value < 10) 1 else 0)} L/100 m"
    }

    fun factor(value: Double?): String =
        if (value == null || !value.isFinite()) "—" else "${grouped(value, 2)}×"

    /**
     * A product quantity in the line's own unit, or an explicit unavailable
     * marker — never a fabricated zero.
     */
    fun quantity(value: Double?, unit: String): String {
        if (value == null || !value.isFinite()) return "Unavailable"
        val decimals = if (value < 10) 2 else if (value < 100) 1 else 0
        return "${grouped(value, decimals)} $unit"
    }

    fun carrierBasisLabel(basis: SprayCarrierBasis): String = when (basis) {
        SprayCarrierBasis.LITRES_PER_HECTARE -> "L/ha"
        SprayCarrierBasis.LITRES_PER_100_METRES -> "L/100 m"
    }

    /** User-facing wording for a product's label rate basis. */
    fun productBasisLabel(basis: SprayProductRateBasis): String = when (basis) {
        SprayProductRateBasis.WHOLE_BLOCK_AREA -> "Whole Block Area"
        SprayProductRateBasis.TREATED_AREA -> "Treated Band Area"
        SprayProductRateBasis.PER_100_LITRES -> "Per 100 L Carrier"
        SprayProductRateBasis.PER_100_METRES -> "Per 100 m Row"
    }

    fun geometrySourceLabel(source: SprayGeometrySource): String = when (source) {
        SprayGeometrySource.OPERATOR_OVERRIDE -> "Manual row-length override"
        SprayGeometrySource.MAPPED_ROWS, SprayGeometrySource.STORED_ROW_LENGTH -> "Mapped rows"
        SprayGeometrySource.DERIVED_FROM_AREA_AND_SPACING -> "Derived from area & row spacing"
        SprayGeometrySource.UNAVAILABLE -> "Unavailable"
    }
}
