package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.RemoveCircle
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.chemical.AuthoritativeActivityGroups
import com.rork.vinetrack.data.chemical.ChemicalActivityGroup
import com.rork.vinetrack.data.chemical.ChemicalActivityGroupScheme
import com.rork.vinetrack.data.chemical.ChemicalConcentrationUnit
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalManualActiveDraft
import com.rork.vinetrack.data.chemical.ChemicalManualDraft
import com.rork.vinetrack.data.chemical.ChemicalManualEntry
import com.rork.vinetrack.data.chemical.ChemicalManualRateDraft
import com.rork.vinetrack.data.chemical.ChemicalManualUseDraft
import com.rork.vinetrack.data.chemical.ChemicalRegistrationScheme
import com.rork.vinetrack.data.chemical.ChemicalVerificationStatus
import com.rork.vinetrack.data.model.ProductCategories
import com.rork.vinetrack.data.spray.SprayTarget
import com.rork.vinetrack.ui.components.ChemicalConflictCard
import com.rork.vinetrack.ui.components.ChemicalVerificationBadge
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/**
 * The structured manual Chemical editor.
 *
 * This replaces the legacy scalar chemistry boxes — one `Active ingredient` text
 * field and one `Chemical group` text field — with the shape the record actually
 * has: a list of actives, each carrying its own concentration and its own
 * resistance group, plus structured label rates and structured uses.
 *
 * The operator can no longer produce `Chemical group = "3 + 11"`, because that
 * string was never a fact about a product. They produce Tebuconazole → FRAC 3 and
 * Azoxystrobin → FRAC 11, two independent relationships, and `"FRAC 3 + 11"` is
 * displayed back to them as a derived summary.
 *
 * Every decision this sheet makes is delegated to [ChemicalManualEntry]. It
 * collects text; it does not decide what any of it means, and in particular it
 * never decides what the record's verification status becomes.
 *
 * Mirrors the iOS `ChemicalManualEditorView` decision for decision.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ChemicalManualEditorSheet(
    draft: ChemicalManualDraft,
    /** The record's stored intelligence. Null for a brand-new product. */
    existing: ChemicalIntelligence?,
    onDraftChange: (ChemicalManualDraft) -> Unit,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)

    // What storing this draft would do to the record's trust. Recomputed as the
    // operator types so the consequence is visible before they commit, and
    // computed by the domain so this sheet cannot flatter it.
    val outcome = remember(draft, existing) {
        ChemicalManualEntry.outcome(draft, existing)
    }
    val problems = remember(draft) { ChemicalManualEntry.problems(draft) }
    val groupSummary = remember(draft) { ChemicalManualEntry.groupSummary(draft) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                "Chemistry & identity",
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = vine.textPrimary,
            )

            // ---- Verification ----
            // Trust, stated at the top, alongside what the current draft would
            // make it. There is no control here: verification is the conclusion
            // the evidence reaches, so the only honest thing a manual editor can
            // do about it is report it.
            SectionLabel("Verification")
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text("Current", fontSize = 13.sp, color = vine.textSecondary, modifier = Modifier.width(96.dp))
                ChemicalVerificationBadge(
                    existing?.resolvedVerificationStatus ?: ChemicalVerificationStatus.UNVERIFIED,
                )
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text("After saving", fontSize = 13.sp, color = vine.textSecondary, modifier = Modifier.width(96.dp))
                ChemicalVerificationBadge(outcome.resolvedStatus)
            }
            outcome.warning?.let { warning ->
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(VineColors.Warning.copy(alpha = 0.12f))
                        .padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        "Verification will be updated",
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textPrimary,
                    )
                    Text(warning, fontSize = 12.sp, color = vine.textSecondary)
                }
            }
            if (outcome.intelligence.verification.conflicts.isNotEmpty()) {
                ChemicalConflictCard(outcome.intelligence.verification.conflicts)
            }
            Text(
                "Information you enter yourself is recorded as unverified. It stays that " +
                    "way until Match & Verify or Re-verify confirms it against a register — " +
                    "completing every field does not make it verified.",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )

            HorizontalDivider()

            // ---- Product ----
            SectionLabel("Product")
            OutlinedTextField(
                value = draft.productName,
                onValueChange = { onDraftChange(draft.copy(productName = it)) },
                label = { Text("Product name") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            // A vineyard may stock an imported product, so the country the product
            // is registered in is not assumed to be the vineyard's.
            ManualDropdown(
                label = "Country",
                value = draft.countryCode.ifBlank { "Not stated" },
                options = listOf("" to "Not stated", "AU" to "Australia", "NZ" to "New Zealand"),
                onSelect = { onDraftChange(draft.copy(countryCode = it)) },
            )
            ManualDropdown(
                label = "Product type",
                value = ProductCategories.label(draft.productCategory),
                options = listOf("" to "Uncategorised") + ProductCategories.all,
                onSelect = { onDraftChange(draft.copy(productCategory = it)) },
            )
            OutlinedTextField(
                value = draft.registrant,
                onValueChange = { onDraftChange(draft.copy(registrant = it)) },
                label = { Text("Manufacturer / registrant (optional)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            // Registers offered for the chosen country, with the full list as a
            // fallback so an imported product is never unrepresentable.
            val schemeOptions = remember(draft.countryCode) {
                val forCountry = ChemicalRegistrationScheme.schemesForCountry(draft.countryCode)
                if (forCountry.isEmpty()) {
                    ChemicalRegistrationScheme.entries.toList()
                } else {
                    forCountry + ChemicalRegistrationScheme.OTHER
                }
            }
            ManualDropdown(
                label = "Register (optional)",
                value = draft.registrationScheme?.label ?: "Not stated",
                options = listOf("" to "Not stated") + schemeOptions.map { it.raw to it.label },
                onSelect = { raw ->
                    onDraftChange(
                        draft.copy(
                            registrationScheme = raw.takeIf { it.isNotEmpty() }
                                ?.let { ChemicalRegistrationScheme.from(it) },
                        ),
                    )
                },
            )
            OutlinedTextField(
                value = draft.registrationNumber,
                onValueChange = { onDraftChange(draft.copy(registrationNumber = it)) },
                label = { Text("Registration number (optional)") },
                placeholder = { Text("e.g. 62764") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                "A registration number you type is recorded as your own entry, not as " +
                    "confirmed identity. It is the first thing Match & Verify and Re-verify " +
                    "will use when they check this product against the register later.",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )

            HorizontalDivider()

            // ---- Active ingredients ----
            Row(verticalAlignment = Alignment.CenterVertically) {
                SectionLabel("Active ingredients", modifier = Modifier.weight(1f))
                if (groupSummary.isNotEmpty()) {
                    Text(
                        groupSummary,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textSecondary,
                    )
                }
            }
            draft.actives.forEach { active ->
                ManualActiveEditor(
                    active = active,
                    canRemove = draft.actives.size > 1,
                    onChange = { updated ->
                        onDraftChange(
                            draft.copy(
                                actives = draft.actives.map { if (it.id == updated.id) updated else it },
                            ),
                        )
                    },
                    onRemove = {
                        val remaining = draft.actives.filterNot { it.id == active.id }
                        onDraftChange(
                            draft.copy(
                                actives = remaining.ifEmpty { listOf(ChemicalManualActiveDraft()) },
                            ),
                        )
                    },
                )
            }
            OutlinedButton(
                onClick = {
                    onDraftChange(draft.copy(actives = draft.actives + ChemicalManualActiveDraft()))
                },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.size(8.dp))
                Text("Add active ingredient")
            }
            Text(
                "Each active ingredient carries its own resistance group. A two-active " +
                    "product genuinely belongs to both groups at once, which is what " +
                    "resistance planning needs to know — so it is recorded as two separate " +
                    "entries, not as one combined group.",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )

            HorizontalDivider()

            // ---- Product label rates ----
            SectionLabel("Product label rates")
            draft.productRates.forEach { rate ->
                ManualRateEditor(
                    rate = rate,
                    onChange = { updated ->
                        onDraftChange(
                            draft.copy(
                                productRates = draft.productRates.map {
                                    if (it.id == updated.id) updated else it
                                },
                            ),
                        )
                    },
                    onRemove = {
                        onDraftChange(
                            draft.copy(productRates = draft.productRates.filterNot { it.id == rate.id }),
                        )
                    },
                )
            }
            OutlinedButton(
                onClick = {
                    onDraftChange(
                        draft.copy(productRates = draft.productRates + ChemicalManualRateDraft()),
                    )
                },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.size(8.dp))
                Text("Add label rate")
            }
            Text(
                "The rate as the label states it — per hectare, per 100 L, or a range. This " +
                    "is not your spray rate or carrier volume: those belong to each spray " +
                    "job, and the vineyard's carrier settings are unaffected by what you " +
                    "enter here.",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )

            HorizontalDivider()

            // ---- Uses ----
            SectionLabel("Uses & restrictions")
            draft.uses.forEach { use ->
                ManualUseEditor(
                    use = use,
                    onChange = { updated ->
                        onDraftChange(
                            draft.copy(uses = draft.uses.map { if (it.id == updated.id) updated else it }),
                        )
                    },
                    onRemove = {
                        onDraftChange(draft.copy(uses = draft.uses.filterNot { it.id == use.id }))
                    },
                )
            }
            OutlinedButton(
                onClick = { onDraftChange(draft.copy(uses = draft.uses + ChemicalManualUseDraft())) },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.size(8.dp))
                Text("Add use")
            }
            Text(
                "A use is a crop and a target the product is registered against, with the " +
                    "rate and any withholding or re-entry period that applies. Recorded as " +
                    "your own entry until authoritative evidence confirms it.",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )

            if (problems.isNotEmpty()) {
                HorizontalDivider()
                SectionLabel("Check these")
                problems.forEach { problem ->
                    Text(problem, fontSize = 12.sp, color = VineColors.Warning)
                }
            }

            Spacer(Modifier.height(4.dp))
            Button(
                onClick = onDismiss,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
            ) { Text("Done") }
        }
    }
}

/** One active ingredient, with its own concentration and its own group. */
@Composable
private fun ManualActiveEditor(
    active: ChemicalManualActiveDraft,
    canRemove: Boolean,
    onChange: (ChemicalManualActiveDraft) -> Unit,
    onRemove: () -> Unit,
) {
    val vine = LocalVineColors.current
    // What the local classification table says this active belongs to, shown as
    // help while typing. Only ever displayed: the operator's own value is what
    // gets stored, and a genuine disagreement is raised as a conflict by the
    // reconciler rather than being silently corrected here.
    val reference = remember(active.name) {
        active.name.trim().takeIf { it.length >= 3 }
            ?.let { AuthoritativeActivityGroups.groupForActive(it) }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(vine.textSecondary.copy(alpha = 0.05f))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = active.name,
                onValueChange = { onChange(active.copy(name = it)) },
                label = { Text("Active ingredient name") },
                singleLine = true,
                modifier = Modifier.weight(1f),
            )
            if (canRemove) {
                IconButton(onClick = onRemove) {
                    Icon(
                        Icons.Filled.RemoveCircle,
                        contentDescription = "Remove active ingredient",
                        tint = VineColors.Destructive,
                    )
                }
            }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedTextField(
                value = active.concentrationText,
                onValueChange = { onChange(active.copy(concentrationText = it.numericFilter())) },
                label = { Text("Concentration") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.weight(1f),
            )
            ManualDropdown(
                label = "Unit",
                value = active.concentrationUnit?.label ?: "Unit",
                options = listOf("" to "Unit") +
                    ChemicalConcentrationUnit.entries.map { it.raw to it.label },
                onSelect = { raw ->
                    onChange(
                        active.copy(
                            concentrationUnit = raw.takeIf { it.isNotEmpty() }
                                ?.let { ChemicalConcentrationUnit.parse(it) },
                        ),
                    )
                },
                modifier = Modifier.weight(1f),
            )
        }

        // Scheme first, then code. A bare "3" means nothing until the system is
        // known: FRAC 3 and IRAC 3 are unrelated chemistries.
        ManualDropdown(
            label = "Resistance group system",
            value = when (active.scheme) {
                ChemicalActivityGroupScheme.FRAC -> "FRAC — Fungicides"
                ChemicalActivityGroupScheme.HRAC -> "HRAC — Herbicides"
                ChemicalActivityGroupScheme.IRAC -> "IRAC — Insecticides"
                ChemicalActivityGroupScheme.NOT_APPLICABLE -> "Not applicable"
                null -> "Not stated"
            },
            options = listOf(
                "" to "Not stated",
                ChemicalActivityGroupScheme.FRAC.raw to "FRAC — Fungicides",
                ChemicalActivityGroupScheme.HRAC.raw to "HRAC — Herbicides",
                ChemicalActivityGroupScheme.IRAC.raw to "IRAC — Insecticides",
                ChemicalActivityGroupScheme.NOT_APPLICABLE.raw to "Not applicable",
            ),
            onSelect = { raw ->
                onChange(
                    active.copy(
                        scheme = raw.takeIf { it.isNotEmpty() }
                            ?.let { value ->
                                ChemicalActivityGroupScheme.entries.firstOrNull { it.raw == value }
                            },
                    ),
                )
            },
        )

        if (active.scheme != null && active.scheme != ChemicalActivityGroupScheme.NOT_APPLICABLE) {
            // Free text on purpose. Resistance classification tables are reissued
            // annually and gain codes; a hard-coded list would make this year's
            // product unrecordable next season.
            OutlinedTextField(
                value = active.groupCode,
                onValueChange = { onChange(active.copy(groupCode = it)) },
                label = { Text("Group") },
                placeholder = { Text("e.g. 3, 11, M5, 4A") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
        }

        reference?.let {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Icon(
                    Icons.Filled.Verified,
                    contentDescription = null,
                    tint = vine.textSecondary,
                    modifier = Modifier.size(12.dp),
                )
                Text(
                    "Reference table: ${it.displayLabel}",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )
            }
        }
    }
}

/** One label rate: a basis, then whichever value shape that basis needs. */
@Composable
private fun ManualRateEditor(
    rate: ChemicalManualRateDraft,
    onChange: (ChemicalManualRateDraft) -> Unit,
    onRemove: () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(vine.textSecondary.copy(alpha = 0.05f))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            ManualDropdown(
                label = "Basis",
                value = rate.basis.label,
                options = ChemicalLabelRateBasis.entries.map { it.raw to it.label },
                onSelect = { onChange(rate.copy(basis = ChemicalLabelRateBasis.from(it))) },
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = onRemove) {
                Icon(
                    Icons.Filled.RemoveCircle,
                    contentDescription = "Remove label rate",
                    tint = VineColors.Destructive,
                )
            }
        }

        when (rate.basis) {
            ChemicalLabelRateBasis.PER_HECTARE, ChemicalLabelRateBasis.PER_100_LITRES -> {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedTextField(
                        value = rate.valueText,
                        onValueChange = { onChange(rate.copy(valueText = it.numericFilter())) },
                        label = { Text("Rate") },
                        suffix = { Text("${rate.unit}${rate.basis.suffix}", fontSize = 12.sp) },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.weight(2f),
                    )
                    ManualDropdown(
                        label = "Unit",
                        value = rate.unit,
                        options = listOf("L" to "L", "mL" to "mL", "kg" to "kg", "g" to "g"),
                        onSelect = { onChange(rate.copy(unit = it)) },
                        modifier = Modifier.weight(1f),
                    )
                }
            }

            ChemicalLabelRateBasis.RANGE_PER_HECTARE,
            ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
            -> {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = rate.minText,
                        onValueChange = { onChange(rate.copy(minText = it.numericFilter())) },
                        label = { Text("Min") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.weight(1f),
                    )
                    OutlinedTextField(
                        value = rate.maxText,
                        onValueChange = { onChange(rate.copy(maxText = it.numericFilter())) },
                        label = { Text("Max") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.weight(1f),
                    )
                    ManualDropdown(
                        label = "Unit",
                        value = rate.unit,
                        options = listOf("L" to "L", "mL" to "mL", "kg" to "kg", "g" to "g"),
                        onSelect = { onChange(rate.copy(unit = it)) },
                        modifier = Modifier.weight(1f),
                    )
                }
                Text(
                    "Recorded low to high${rate.basis.suffix}.",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )
            }

            ChemicalLabelRateBasis.OTHER -> {
                OutlinedTextField(
                    value = rate.rawText,
                    onValueChange = { onChange(rate.copy(rawText = it)) },
                    label = { Text("Rate as the label words it") },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }

        OutlinedTextField(
            value = rate.label,
            onValueChange = { onChange(rate.copy(label = it)) },
            label = { Text("Rate name (optional)") },
            placeholder = { Text("e.g. High disease pressure") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

/** One registered use: crop, target, its own rates, and its restrictions. */
@Composable
private fun ManualUseEditor(
    use: ChemicalManualUseDraft,
    onChange: (ChemicalManualUseDraft) -> Unit,
    onRemove: () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(vine.textSecondary.copy(alpha = 0.05f))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = use.crop,
                onValueChange = { onChange(use.copy(crop = it)) },
                label = { Text("Crop") },
                singleLine = true,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = onRemove) {
                Icon(
                    Icons.Filled.RemoveCircle,
                    contentDescription = "Remove use",
                    tint = VineColors.Destructive,
                )
            }
        }
        OutlinedTextField(
            value = use.targetRaw,
            onValueChange = { onChange(use.copy(targetRaw = it)) },
            label = { Text("Target") },
            placeholder = { Text("e.g. Powdery Mildew") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        // VineTrack's own targets assist entry without bounding it: a label may
        // register a target VineTrack has no word for, and that use must still be
        // recordable.
        Row(
            modifier = Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            SprayTarget.entries.forEach { target ->
                OutlinedButton(
                    onClick = { onChange(use.copy(targetRaw = target.label)) },
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(
                        horizontal = 10.dp,
                        vertical = 2.dp,
                    ),
                ) { Text(target.label, fontSize = 11.sp) }
            }
        }

        use.rates.forEach { rate ->
            ManualRateEditor(
                rate = rate,
                onChange = { updated ->
                    onChange(use.copy(rates = use.rates.map { if (it.id == updated.id) updated else it }))
                },
                onRemove = { onChange(use.copy(rates = use.rates.filterNot { it.id == rate.id })) },
            )
        }
        OutlinedButton(
            onClick = { onChange(use.copy(rates = use.rates + ChemicalManualRateDraft())) },
            modifier = Modifier.fillMaxWidth(),
        ) {
            Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(16.dp))
            Spacer(Modifier.size(6.dp))
            Text("Add rate for this use", fontSize = 13.sp)
        }

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedTextField(
                value = use.withholdingPeriodDaysText,
                onValueChange = {
                    onChange(use.copy(withholdingPeriodDaysText = it.numericFilter()))
                },
                label = { Text("Withholding period") },
                suffix = { Text("days", fontSize = 11.sp) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.weight(1f),
            )
            OutlinedTextField(
                value = use.reEntryPeriodHoursText,
                onValueChange = { onChange(use.copy(reEntryPeriodHoursText = it.numericFilter())) },
                label = { Text("Re-entry period") },
                suffix = { Text("hours", fontSize = 11.sp) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.weight(1f),
            )
        }
        OutlinedTextField(
            value = use.restrictions,
            onValueChange = { onChange(use.copy(restrictions = it)) },
            label = { Text("Label restrictions (optional)") },
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

/** Small grey section header used inside the manual editor. */
@Composable
private fun SectionLabel(text: String, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Text(
        text.uppercase(),
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        color = vine.textSecondary,
        modifier = modifier,
    )
}

/** Keeps a numeric field numeric while the operator types. */
private fun String.numericFilter(): String = filter { c -> c.isDigit() || c == '.' || c == ',' }

/** Small labelled dropdown used throughout the manual editor. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ManualDropdown(
    label: String,
    value: String,
    options: List<Pair<String, String>>,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var expanded by remember { mutableStateOf(false) }
    ExposedDropdownMenuBox(
        expanded = expanded,
        onExpandedChange = { expanded = it },
        modifier = modifier,
    ) {
        OutlinedTextField(
            value = value,
            onValueChange = {},
            readOnly = true,
            label = { Text(label) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier
                .fillMaxWidth()
                .menuAnchor(MenuAnchorType.PrimaryNotEditable),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            options.forEach { (key, text) ->
                DropdownMenuItem(
                    text = { Text(text) },
                    onClick = {
                        onSelect(key)
                        expanded = false
                    },
                )
            }
        }
    }
}
