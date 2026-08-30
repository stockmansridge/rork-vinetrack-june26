package com.rork.vinetrack.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.automirrored.filled.LibraryBooks
import androidx.compose.material.icons.filled.Adjust
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Help
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.chemical.ChemicalActiveIngredient
import com.rork.vinetrack.data.chemical.ChemicalActivityGroup
import com.rork.vinetrack.data.chemical.ChemicalJurisdiction
import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalProvenanceBadge
import com.rork.vinetrack.data.chemical.ChemicalProvenanceTier
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.ChemicalRegistration
import com.rork.vinetrack.data.chemical.ChemicalUseProvenanceFact
import com.rork.vinetrack.data.chemical.ChemicalWithholdingDisplay
import com.rork.vinetrack.data.chemical.provenancePlan
import com.rork.vinetrack.data.chemical.uniformRatesBadge
import com.rork.vinetrack.data.chemical.ChemicalVerification
import com.rork.vinetrack.data.chemical.ChemicalVerificationConflict
import com.rork.vinetrack.data.chemical.ChemicalVerificationStatus
import com.rork.vinetrack.data.chemical.legacyGroupProjection
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/**
 * Shared presentation for Chemical Intelligence — the Android mirror of the iOS
 * `ChemicalIntelligenceUI.swift`.
 *
 * Every screen that shows a chemical's trust state renders it through this file.
 * That is deliberate: verification is a claim about how much a grower can rely on
 * resistance data, and it must read identically in the Chemical Store, the verify
 * wizard and the spray picker — and identically across the two platforms. Two
 * subtly different badges would be two subtly different promises.
 */
fun chemicalVerificationIcon(status: ChemicalVerificationStatus): ImageVector = when (status) {
    ChemicalVerificationStatus.VERIFIED -> Icons.Filled.Verified
    ChemicalVerificationStatus.PARTIALLY_VERIFIED -> Icons.Filled.Adjust
    ChemicalVerificationStatus.NEEDS_MATCH -> Icons.Filled.Help
    ChemicalVerificationStatus.CONFLICT -> Icons.Filled.Warning
    ChemicalVerificationStatus.UNVERIFIED -> Icons.Filled.RadioButtonUnchecked
}

fun chemicalVerificationTint(status: ChemicalVerificationStatus): Color = when (status) {
    ChemicalVerificationStatus.VERIFIED -> VineColors.Success
    ChemicalVerificationStatus.PARTIALLY_VERIFIED -> VineColors.Info
    ChemicalVerificationStatus.NEEDS_MATCH -> VineColors.Warning
    ChemicalVerificationStatus.CONFLICT -> VineColors.Destructive
    ChemicalVerificationStatus.UNVERIFIED -> VineColors.Stone
}

/** Compact trust chip used in lists and pickers. */
@Composable
fun ChemicalVerificationBadge(
    status: ChemicalVerificationStatus,
    modifier: Modifier = Modifier,
    compact: Boolean = false,
) {
    val tint = chemicalVerificationTint(status)
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(50))
            .background(tint.copy(alpha = 0.12f))
            .padding(horizontal = if (compact) 5.dp else 7.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(
            chemicalVerificationIcon(status),
            contentDescription = status.label,
            tint = tint,
            modifier = Modifier.size(12.dp),
        )
        if (!compact) {
            Text(status.label, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = tint)
        }
    }
}

/**
 * Full-width jurisdiction warning: this product is registered under another
 * country's law than the vineyard it is being viewed in.
 *
 * Identity and chemistry stand — the record is never re-keyed — but its
 * registered uses, label rates, withholding and re-entry periods are not
 * vineyard-authoritative. Mirrors the iOS `ChemicalJurisdictionMismatchBanner`.
 */
@Composable
fun ChemicalJurisdictionMismatchBanner(
    registrationCountry: String,
    vineyardCountry: String,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(VineColors.Warning.copy(alpha = 0.08f))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                Icons.Filled.Public,
                contentDescription = null,
                tint = VineColors.Warning,
                modifier = Modifier.size(14.dp),
            )
            Text(
                ChemicalJurisdiction.mismatchHeadline(registrationCountry, vineyardCountry),
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
                color = VineColors.Warning,
            )
        }
        Text(
            ChemicalJurisdiction.mismatchGuidance(registrationCountry, vineyardCountry),
            fontSize = 11.sp,
            color = LocalVineColors.current.textSecondary,
        )
    }
}

/**
 * Compact foreign-label mark shown next to the trust badge in lists and
 * pickers — e.g. "AU label — not NZ".
 *
 * Deliberately NOT a block: the product stays selectable (there may be a
 * legitimate local reason to use it), but its label information can never
 * silently read as valid for this vineyard's jurisdiction.
 */
@Composable
fun ChemicalJurisdictionChip(
    registrationCountry: String,
    vineyardCountry: String,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(50))
            .background(VineColors.Warning.copy(alpha = 0.12f))
            .padding(horizontal = 7.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(
            Icons.Filled.Public,
            contentDescription = ChemicalJurisdiction.mismatchHeadline(
                registrationCountry,
                vineyardCountry,
            ),
            tint = VineColors.Warning,
            modifier = Modifier.size(12.dp),
        )
        Text(
            "$registrationCountry label — not $vineyardCountry",
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            color = VineColors.Warning,
        )
    }
}

/**
 * One active ingredient, rendered as its own row with its own group.
 *
 * The active — not the product — is the thing that carries an activity group, so
 * a mixture shows two of these rather than one "3 + 11" line. The group chip
 * repeats per active on purpose: it is what makes "both groups apply" visually
 * obvious rather than something the reader has to infer.
 */
@Composable
fun ChemicalActiveIngredientRow(
    active: ChemicalActiveIngredient,
    modifier: Modifier = Modifier,
    showSource: Boolean = true,
) {
    val vine = LocalVineColors.current
    Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            active.name.ifBlank { "Unnamed active" },
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
            color = if (active.name.isBlank()) vine.textSecondary else vine.textPrimary,
        )

        val concentration = active.concentration
        val unit = active.concentrationUnit
        if (concentration != null && unit != null) {
            Text(
                "${ChemicalActiveIngredient.formatConcentration(concentration)} ${unit.label}",
                fontSize = 12.sp,
                color = vine.textSecondary,
            )
        } else {
            Text("Concentration not confirmed", fontSize = 12.sp, color = vine.textSecondary)
        }

        val group = active.activityGroup
        if (group != null && group.isResistanceRelevant) {
            ChemicalPill(group.displayLabel, VineColors.Olive)
        } else {
            ChemicalPill("Activity group unknown", VineColors.Warning)
        }

        // Never let an AI reading masquerade as a regulator's word.
        val source = active.groupSource
        if (showSource && source != null) {
            Text(
                if (source.isAuthoritative) "Source: ${source.label}"
                else "Source: ${source.label} — not independently verified",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )
        }
    }
}

/**
 * The derived `FRAC 3 + 11` display line.
 *
 * Derived from structured actives every time it is drawn. Nothing here ever reads
 * the legacy `chemical_group` text, which is why a verified record can never
 * display a group the structured data does not actually contain.
 */
@Composable
fun ChemicalGroupSummaryLine(groups: List<ChemicalActivityGroup>, modifier: Modifier = Modifier) {
    if (groups.isEmpty()) return
    ChemicalPill(groups.legacyGroupProjection(), VineColors.Olive, modifier)
}

/** Small capsule used for group / metadata chips. */
@Composable
fun ChemicalPill(text: String, tint: Color, modifier: Modifier = Modifier) {
    Text(
        text,
        fontSize = 11.sp,
        fontWeight = FontWeight.Bold,
        color = tint,
        modifier = modifier
            .clip(RoundedCornerShape(50))
            .background(tint.copy(alpha = 0.12f))
            .padding(horizontal = 7.dp, vertical = 3.dp),
    )
}

/** Surfaces a source disagreement in full, without picking a winner. */
@Composable
fun ChemicalConflictCard(
    conflicts: List<ChemicalVerificationConflict>,
    modifier: Modifier = Modifier,
) {
    if (conflicts.isEmpty()) return
    val vine = LocalVineColors.current
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(VineColors.Destructive.copy(alpha = 0.07f))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                Icons.Filled.Warning,
                contentDescription = null,
                tint = VineColors.Destructive,
                modifier = Modifier.size(16.dp),
            )
            Text(
                "Verification conflict",
                fontSize = 15.sp,
                fontWeight = FontWeight.Bold,
                color = VineColors.Destructive,
            )
        }
        Text(
            "The extracted product information and the activity-group classification " +
                "do not agree. This product cannot be verified until the disagreement is resolved.",
            fontSize = 12.sp,
            color = vine.textSecondary,
        )
        conflicts.forEach { conflict ->
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                conflict.activeIngredientName?.takeIf { it.isNotBlank() }?.let {
                    Text(it, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                }
                ConflictLine("Extracted:", conflict.extractedValue)
                ConflictLine("Reference classification:", conflict.authoritativeValue)
            }
        }
    }
}

@Composable
private fun ConflictLine(label: String, value: String) {
    val vine = LocalVineColors.current
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(label, fontSize = 11.sp, color = vine.textSecondary)
        Text(value, fontSize = 11.sp, fontWeight = FontWeight.Medium, color = vine.textPrimary)
    }
}

/**
 * Expandable provenance. Enough transparency to justify the trust claim, without
 * turning the screen into a debugging dump.
 */
@Composable
fun ChemicalVerificationEvidenceView(
    verification: ChemicalVerification,
    resolvedStatus: ChemicalVerificationStatus,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    var expanded by remember { mutableStateOf(false) }

    Column(modifier = modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { expanded = !expanded }
                .padding(vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Verification details", fontSize = 15.sp, color = vine.textPrimary)
            Spacer(Modifier.weight(1f))
            ChemicalVerificationBadge(resolvedStatus)
            Icon(
                if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                contentDescription = null,
                tint = vine.textSecondary,
                modifier = Modifier.size(20.dp),
            )
        }

        if (expanded) {
            Column(
                modifier = Modifier.padding(top = 6.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(resolvedStatus.detail, fontSize = 12.sp, color = vine.textSecondary)

                if (verification.sources.isNotEmpty()) {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(
                            "Sources",
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textPrimary,
                        )
                        verification.sources.forEach { source ->
                            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                                ) {
                                    Icon(
                                        if (source.kind.isAuthoritative) Icons.Filled.Verified
                                        else Icons.Filled.Adjust,
                                        contentDescription = null,
                                        tint = if (source.kind.isAuthoritative) VineColors.Success
                                        else vine.textSecondary,
                                        modifier = Modifier.size(12.dp),
                                    )
                                    Text(
                                        source.name.ifBlank { source.kind.label },
                                        fontSize = 12.sp,
                                        color = vine.textPrimary,
                                    )
                                }
                                Text(
                                    if (source.kind.isAuthoritative) source.kind.label
                                    else "${source.kind.label} — not independently verified",
                                    fontSize = 11.sp,
                                    color = vine.textSecondary,
                                )
                                source.reference?.takeIf { it.isNotBlank() }?.let {
                                    Text(it, fontSize = 11.sp, color = vine.textSecondary, maxLines = 2)
                                }
                            }
                        }
                    }
                }

                if (verification.unresolvedFields.isNotEmpty()) {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(
                            "Not confirmed",
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textPrimary,
                        )
                        verification.unresolvedFields.forEach {
                            Text("• $it", fontSize = 11.sp, color = vine.textSecondary)
                        }
                    }
                }

                verification.verifiedAt?.takeIf { it.isNotBlank() }?.let {
                    Text("Last checked $it", fontSize = 11.sp, color = vine.textSecondary)
                }
            }
        }
    }
}

/**
 * Registered/label rates.
 *
 * Titled "Product label rate" and never merged with carrier settings: the label
 * rate is a legal instruction attached to the product, while carrier volume is
 * how this vineyard chooses to apply water. An NZ block spraying on L/100 m still
 * applies a 1.5 L/ha label product.
 */
@Composable
fun ChemicalLabelRatesView(uses: List<ChemicalRegisteredUse>, modifier: Modifier = Modifier) {
    val rates: List<ChemicalLabelRate> = uses.flatMap { it.rates }
    if (rates.isEmpty()) return
    val vine = LocalVineColors.current
    Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                "Product label rate",
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                color = vine.textSecondary,
            )
            // Shown only when every rate-owning use proves the same
            // authoritative tier — read from stored provenance, never
            // inferred from the values themselves.
            uses.uniformRatesBadge()?.let { ChemicalProvenanceTag(it) }
        }
        rates.forEach { rate ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    rate.displayRate,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = vine.textPrimary,
                )
                Text(rate.basis.label, fontSize = 11.sp, color = vine.textSecondary)
            }
        }
        Text(
            "Label rates are set by the product registration. They are separate from " +
                "this vineyard's carrier volume method.",
            fontSize = 11.sp,
            color = vine.textSecondary,
        )
    }
}

/**
 * Registered uses, with an explicit statement when grape use is unconfirmed.
 *
 * [hasManufacturerLabelSource] says whether the payload cites the
 * manufacturer's approved label as a data source. It drives ONLY the
 * withholding "not required" wording — see [ChemicalWithholdingDisplay] — and
 * defaults to false so a call site that cannot prove label evidence fails
 * closed to plain day counts. Mirrors the iOS `ChemicalRegisteredUsesView`.
 */
@Composable
fun ChemicalRegisteredUsesView(
    uses: List<ChemicalRegisteredUse>,
    modifier: Modifier = Modifier,
    hasManufacturerLabelSource: Boolean = false,
) {
    val vine = LocalVineColors.current
    Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (uses.isEmpty()) {
            GrapeNotVerifiedLabel()
            Text(
                "No registered uses were confirmed for this product. Check the label before applying.",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )
        } else {
            uses.forEach { use ->
                // Tags come from STORED per-use provenance only: one badge for
                // the card when every fact shares a tier, per-fact badges only
                // when trust is mixed, nothing for legacy or unproven records.
                // See ChemicalUseProvenancePlan.
                val plan = use.provenancePlan
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(
                            use.crop.ifBlank { "Crop not stated" },
                            fontSize = 15.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textPrimary,
                        )
                        plan.headerBadge?.let { ChemicalProvenanceTag(it) }
                    }
                    Text(
                        "• ${use.targetRaw.ifBlank { "Target not stated" }}",
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                    use.rates.forEach { rate ->
                        Text(
                            rate.displayRate,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Medium,
                            color = vine.textPrimary,
                        )
                    }
                    // WHP/REI rows are ALWAYS drawn, even when the label said
                    // nothing: a hidden row reads as "no restriction", while
                    // "Not stated" reads as "go and check". Mirrors iOS.
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        val whp = ChemicalWithholdingDisplay.display(
                            days = use.withholdingPeriodDays,
                            restrictions = use.restrictions,
                            hasManufacturerLabelSource = hasManufacturerLabelSource,
                        )
                        Text("Withholding period: $whp", fontSize = 11.sp, color = vine.textSecondary)
                        // Provenance capsules render only beside STATED values.
                        if (use.withholdingPeriodDays != null) {
                            plan.badgeFor(ChemicalUseProvenanceFact.WITHHOLDING_PERIOD)
                                ?.let { ChemicalProvenanceTag(it) }
                        }
                    }
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        val reEntry = ChemicalWithholdingDisplay.reEntrySummary(
                            hours = use.reEntryPeriodHours,
                            statement = use.reEntryStatement,
                        )
                        Text("Re-entry: $reEntry", fontSize = 11.sp, color = vine.textSecondary)
                        if (ChemicalWithholdingDisplay.reEntryIsStated(
                                hours = use.reEntryPeriodHours,
                                statement = use.reEntryStatement,
                            )
                        ) {
                            plan.badgeFor(ChemicalUseProvenanceFact.RE_ENTRY)
                                ?.let { ChemicalProvenanceTag(it) }
                        }
                    }
                    use.restrictions?.takeIf { it.isNotEmpty() }?.let { restrictions ->
                        ChemicalUseRestrictionsView(
                            text = restrictions,
                            badge = plan.badgeFor(ChemicalUseProvenanceFact.RESTRICTIONS),
                        )
                    }
                }
            }
            // Registered uses are never inferred from activity group: if no grape
            // use was confirmed, say so rather than implying approval.
            if (uses.none { it.isViticultural }) {
                GrapeNotVerifiedLabel()
            }
        }
    }
}

/**
 * Tiny capsule naming the evidence tier behind a displayed fact.
 *
 * Rendered exclusively from STORED provenance ([ChemicalProvenanceBadge]): it
 * never derives a tier from the value it sits beside, and it simply does not
 * exist for records without recorded provenance. Mirrors the iOS
 * `ChemicalProvenanceTagView`.
 */
@Composable
fun ChemicalProvenanceTag(badge: ChemicalProvenanceBadge, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(50))
            .background(vine.textSecondary.copy(alpha = 0.10f))
            .padding(horizontal = 6.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Icon(
            when (badge) {
                is ChemicalProvenanceBadge.Authoritative -> when (badge.tier) {
                    ChemicalProvenanceTier.OFFICIAL_REGISTER -> Icons.Filled.Verified
                    ChemicalProvenanceTier.MANUFACTURER_LABEL -> Icons.Filled.Description
                    ChemicalProvenanceTier.AUTHORITATIVE_CLASSIFICATION -> Icons.Filled.Shield
                    ChemicalProvenanceTier.MASTER_CATALOGUE -> Icons.AutoMirrored.Filled.LibraryBooks
                }
                ChemicalProvenanceBadge.Unresolved -> Icons.AutoMirrored.Filled.HelpOutline
            },
            contentDescription = "Source: ${badge.text}",
            tint = vine.textSecondary,
            modifier = Modifier.size(10.dp),
        )
        Text(badge.text, fontSize = 10.sp, color = vine.textSecondary)
    }
}

/**
 * A registered use's verbatim label restriction statements.
 *
 * The wording is legal text: it renders exactly as the label states it, never
 * paraphrased or summarised. Long statements collapse to a few lines with an
 * explicit expand control, so the full wording stays one tap away without
 * dominating the product summary. Mirrors the iOS `ChemicalUseRestrictionsView`.
 */
@Composable
fun ChemicalUseRestrictionsView(
    text: String,
    modifier: Modifier = Modifier,
    badge: ChemicalProvenanceBadge? = null,
) {
    val vine = LocalVineColors.current
    var expanded by remember(text) { mutableStateOf(false) }
    // Whether the statement plausibly exceeds the collapsed window and
    // deserves an expand control. A cheap display heuristic — it never alters
    // the text itself.
    val isLong = text.length > 160 || text.lines().size > COLLAPSED_RESTRICTION_LINES
    Column(
        modifier = modifier.fillMaxWidth().padding(top = 2.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                "Label restrictions",
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                color = vine.textSecondary,
            )
            badge?.let { ChemicalProvenanceTag(it) }
        }
        Text(
            text,
            fontSize = 11.sp,
            color = vine.textSecondary,
            maxLines = if (expanded) Int.MAX_VALUE else COLLAPSED_RESTRICTION_LINES,
            overflow = TextOverflow.Ellipsis,
        )
        if (isLong) {
            Text(
                if (expanded) "Show less" else "Show full restrictions",
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                color = VineColors.Primary,
                modifier = Modifier.clickable { expanded = !expanded },
            )
        }
    }
}

private const val COLLAPSED_RESTRICTION_LINES: Int = 3

@Composable
private fun GrapeNotVerifiedLabel() {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(
            Icons.Filled.Warning,
            contentDescription = null,
            tint = VineColors.Warning,
            modifier = Modifier.size(14.dp),
        )
        Text(
            "Grape registration not verified",
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            color = VineColors.Warning,
        )
    }
}

/** Product identity block used by both Match and Verify. */
@Composable
fun ChemicalIdentityView(
    productName: String,
    registration: ChemicalRegistration?,
    productCategory: String,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            productName.ifBlank { "Unnamed product" },
            fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold,
            color = vine.textPrimary,
        )

        if (registration != null) {
            registration.registrant?.takeIf { it.isNotBlank() }?.let {
                ChemicalLabelledLine("Registrant", it)
            }
            if (registration.countryCode.isNotBlank()) {
                ChemicalLabelledLine("Country", registration.countryCode)
            }
            val identifier = registration.displayIdentifier
            if (identifier != null) {
                ChemicalLabelledLine("Registration", identifier)
            } else {
                Text(
                    "No registration identifier found",
                    fontSize = 12.sp,
                    color = VineColors.Warning,
                )
            }
        } else {
            Text(
                "No registered identity found for this product",
                fontSize = 12.sp,
                color = VineColors.Warning,
            )
        }

        if (productCategory.isNotBlank()) {
            ChemicalLabelledLine("Type", productCategory.replaceFirstChar { it.uppercase() })
        }
    }
}

/**
 * The one-line intelligence summary shown under a product name in a picker.
 *
 * Renders the actives summary, the DERIVED group projection, and the trust badge.
 * Deliberately read-only and non-blocking: an unverified product must still be
 * sprayable today, because refusing to record a real spray would push the
 * operator to write it down somewhere VineTrack can never see. The badge is the
 * signal; the future Resistance Check is what will act on it.
 *
 * Legacy `chemicalGroup` text appears only when there is no structured group at
 * all, and is visibly marked as unstructured so it is never mistaken for
 * confirmed chemistry.
 */
@Composable
fun ChemicalPickerIntelligenceRow(
    chemical: SavedChemical,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    val intel = chemical.resolvedIntelligence
    val actives = intel.activeIngredients.filter { it.name.isNotBlank() }
    val structuredGroups = intel.activityGroups
    val activeSummary = actives.joinToString(" + ") { it.displayLabel }
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        if (activeSummary.isNotBlank()) {
            Text(activeSummary, fontSize = 11.sp, color = vine.textSecondary, maxLines = 2)
        }
        Row(
            horizontalArrangement = Arrangement.spacedBy(5.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ChemicalVerificationBadge(chemical.verificationStatus, compact = true)
            if (structuredGroups.isNotEmpty()) {
                // e.g. "FRAC 3 + 11" — derived from the actives, never parsed back.
                ChemicalPill(
                    "${structuredGroups.first().scheme.label} ${structuredGroups.legacyGroupProjection()}",
                    VineColors.Olive,
                )
            } else if (chemical.chemicalGroup.isNotBlank()) {
                ChemicalPill("Group ${chemical.chemicalGroup} (unstructured)", VineColors.Stone)
            }
        }
    }
}

@Composable
fun ChemicalLabelledLine(title: String, value: String) {
    val vine = LocalVineColors.current
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            title,
            fontSize = 12.sp,
            color = vine.textSecondary,
            modifier = Modifier.width(96.dp),
        )
        Text(value, fontSize = 12.sp, fontWeight = FontWeight.Medium, color = vine.textPrimary)
    }
}
