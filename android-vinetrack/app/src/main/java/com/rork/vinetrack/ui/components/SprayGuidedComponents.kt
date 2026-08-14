package com.rork.vinetrack.ui.components

import androidx.compose.animation.AnimatedVisibility
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.spray.SprayCarrierBasis
import com.rork.vinetrack.data.spray.SprayGeometrySource
import com.rork.vinetrack.data.spray.SprayGuidedBlocker
import com.rork.vinetrack.data.spray.SprayGuidedStep
import com.rork.vinetrack.data.spray.SprayProductLineResult
import com.rork.vinetrack.data.spray.SprayProductRateBasis
import java.text.DecimalFormat

/**
 * A progressively-disclosed section of the guided Spray Calculator — the Compose
 * twin of the SwiftUI `GuidedStepCard`, with the same three visual states driven
 * entirely by `SprayGuidedFlow` so neither platform can drift from the shared
 * validation rules:
 *
 *  - **Locked** — an earlier decision is outstanding. Dimmed, not tappable.
 *  - **Active** — the current decision. Expanded, accented.
 *  - **Done** — complete and behind the active step. Collapsed to a one-line
 *    summary with an Edit affordance.
 *
 * A single scrolling screen rather than a rigid page-by-page wizard: field
 * operators need to jump back to a section in one tap.
 */
@Composable
fun GuidedStepCard(
    step: SprayGuidedStep,
    index: Int,
    isLocked: Boolean,
    isDone: Boolean,
    isExpanded: Boolean,
    summary: String,
    accent: Color,
    doneAccent: Color,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val headerAccent = when {
        isLocked -> MaterialTheme.colorScheme.onSurfaceVariant
        isDone -> doneAccent
        else -> accent
    }
    Surface(
        modifier = modifier.fillMaxWidth().alpha(if (isLocked) 0.55f else 1f),
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surface,
        border = if (isExpanded && !isLocked) {
            androidx.compose.foundation.BorderStroke(1.5.dp, headerAccent.copy(alpha = 0.45f))
        } else {
            null
        },
    ) {
        Column(modifier = Modifier.fillMaxWidth()) {
            Surface(
                color = Color.Transparent,
                enabled = !isLocked,
                onClick = onToggle,
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .size(28.dp)
                            .background(
                                if (isDone) doneAccent else headerAccent.copy(alpha = 0.15f),
                                CircleShape,
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        if (isDone) {
                            Icon(
                                Icons.Filled.Check,
                                contentDescription = null,
                                tint = Color.White,
                                modifier = Modifier.size(16.dp),
                            )
                        } else {
                            Text(
                                text = "$index",
                                style = MaterialTheme.typography.labelMedium,
                                fontWeight = FontWeight.Bold,
                                color = headerAccent,
                            )
                        }
                    }
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = step.title,
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.SemiBold,
                            color = if (isLocked) {
                                MaterialTheme.colorScheme.onSurfaceVariant
                            } else {
                                MaterialTheme.colorScheme.onSurface
                            },
                        )
                        if (summary.isNotEmpty()) {
                            Text(
                                text = summary,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 2,
                            )
                        }
                    }
                    when {
                        isLocked -> Icon(
                            Icons.Filled.Lock,
                            contentDescription = "Locked",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(16.dp),
                        )
                        isDone && !isExpanded -> Text(
                            text = "Edit",
                            style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.SemiBold,
                            color = accent,
                        )
                        else -> Icon(
                            if (isExpanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(20.dp),
                        )
                    }
                }
            }
            AnimatedVisibility(visible = isExpanded && !isLocked) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = 14.dp, end = 14.dp, bottom = 14.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .height(0.5.dp)
                            .background(MaterialTheme.colorScheme.outlineVariant),
                    )
                    content()
                }
            }
        }
    }
}

/** A titled group of Review rows with a jump-back Edit action. */
@Composable
fun GuidedReviewGroup(
    title: String,
    accent: Color,
    modifier: Modifier = Modifier,
    onEdit: (() -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(
                MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
                RoundedCornerShape(10.dp),
            )
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = title.uppercase(),
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f),
            )
            if (onEdit != null) {
                Surface(color = Color.Transparent, onClick = onEdit) {
                    Text(
                        text = "Edit",
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.SemiBold,
                        color = accent,
                    )
                }
            }
        }
        content()
    }
}

/**
 * The per-product area-basis picker.
 *
 * Deliberately a full-width, always-visible control on the product line rather
 * than something behind an "advanced" disclosure: on a banded pass the difference
 * between whole-block and treated-band hectares is a 4x difference in product, so
 * it is not a detail the operator should have to go looking for.
 */
@Composable
fun GuidedProductBasisPicker(
    selected: SprayProductRateBasis,
    accent: Color,
    modifier: Modifier = Modifier,
    onSelect: (SprayProductRateBasis) -> Unit,
) {
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            text = "Apply this product rate to:",
            style = MaterialTheme.typography.bodySmall,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SprayProductRateBasis.areaChoices.forEach { basis ->
                GuidedChip(
                    label = SprayGuidedFormat.productBasisLabel(basis),
                    isSelected = selected == basis,
                    accent = accent,
                    modifier = Modifier.weight(1f),
                    onClick = { onSelect(basis) },
                )
            }
        }
    }
}

/**
 * The calculated explanation for one product line.
 *
 * Shows the arithmetic in the operator's own terms - rate x measured amount -
 * then the requirement. When the line cannot resolve it names the ONE missing
 * input instead of showing a zero.
 */
@Composable
fun GuidedProductCalculationRow(
    line: SprayProductLineResult,
    accent: Color,
    modifier: Modifier = Modifier,
) {
    val warning = Color(0xFFE65100)
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(
                (if (line.isUnresolved) warning else accent).copy(alpha = 0.08f),
                RoundedCornerShape(8.dp),
            )
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        val calculation = SprayGuidedFormat.productCalculation(line)
        if (calculation != null) {
            Text(
                text = calculation,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                text = SprayGuidedFormat.productRequirement(line),
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Bold,
                color = accent,
            )
        } else {
            line.unresolvedReason?.let { reason ->
                Text(
                    text = reason.title,
                    style = MaterialTheme.typography.bodySmall,
                    fontWeight = FontWeight.SemiBold,
                    color = warning,
                )
                Text(
                    text = reason.message,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/**
 * The reserved slot for the future Resistance Check.
 *
 * Deliberately renders NOTHING when disabled: showing a fake "no resistance
 * issues" result would be worse than showing nothing, because an operator would
 * trust it. The rules engine is a separate task; this only fixes the location -
 * immediately beneath the product line it will judge.
 */
@Composable
fun ResistanceCheckSlot(isApplicable: Boolean) {
    if (isApplicable) Spacer(Modifier.height(0.dp))
}

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

    /** The rate as written on the label, e.g. `2 L/ha` or `100 mL/100 L`. */
    fun productRate(line: SprayProductLineResult): String {
        val decimals = if (line.rate < 10) 1 else 0
        return "${grouped(line.rate, decimals)} ${line.unit}${line.basis.rateSuffix}"
    }

    /**
     * The MEASURED half of the calculation, e.g. `10.00 ha whole block`.
     *
     * Reads `basisInput` straight off the planner's line — the screen never
     * substitutes its own hectares or litres here, so the explanation and the
     * quantity can never describe different arithmetic.
     */
    fun productMeasuredInput(line: SprayProductLineResult): String? {
        val input = line.basisInput ?: return null
        if (!input.isFinite()) return null
        val decimals = if (line.basis.measuredUnit == "ha") 2 else 0
        return "${grouped(input, decimals)} ${line.basis.measuredUnit} ${line.basis.measuredNoun}"
    }

    /** The full one-line explanation, e.g. `2 L/ha × 10.00 ha whole block`. */
    fun productCalculation(line: SprayProductLineResult): String? {
        val measured = productMeasuredInput(line) ?: return null
        return "${productRate(line)} × $measured"
    }

    /** The resulting requirement, e.g. `20.0 L required`. */
    fun productRequirement(line: SprayProductLineResult): String {
        val total = line.totalQuantity ?: return "Unavailable"
        return "${quantity(total, line.unit)} required"
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
