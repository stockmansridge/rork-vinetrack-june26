package com.rork.vinetrack.ui.components

import androidx.compose.foundation.background
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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.PruningActivityLabourCosting
import com.rork.vinetrack.data.WorkTaskLabourCosting
import com.rork.vinetrack.data.model.OperatorCategory
import com.rork.vinetrack.data.model.PieceRateCosting
import com.rork.vinetrack.data.model.PruningActivityLabourLine
import com.rork.vinetrack.data.model.WorkTaskCostingMethod
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/**
 * THE labour surface of a Pruning Activity (sql/190) — the Kotlin twin of the
 * Swift `PruningActivityLabourLinesSection`.
 *
 * Labour is **PRUNING-OWNED**: these lines belong to the activity, not to the
 * linked Work Task, and they are counted ONCE no matter how many blocks the
 * activity covers. A linked Work Task never gets a copy — it reads through to
 * the same rows — so the Pruning report and the Work Task report show the same
 * number from the same record.
 *
 * What is rendered depends on where the activity's labour actually comes from,
 * resolved by [PruningActivityLabourCosting.resolve]:
 *
 *  * `PIECE_RATE` — a linked piece-rate job. Its snapshot IS the cost; hours
 *    here are operational history and never move the money.
 *  * `PRUNING_LABOUR_LINES` — the activity's own lines. Fully editable.
 *  * `WORK_TASK_LINES` — labour recorded on the linked task before SQL 190.
 *    Shown read-through, clearly attributed, never duplicated locally.
 *  * `ACTIVITY_HOURS` — a legacy single-crew record. Shown exactly as recorded,
 *    with an explicit opt-in conversion. Never silently rewritten.
 */
@Composable
fun PruningActivityLabourLinesSection(
    lines: List<PruningActivityLabourLine>,
    resolved: PruningActivityLabourCosting.Resolved,
    operatorCategories: List<OperatorCategory>,
    canEdit: Boolean,
    canViewCosting: Boolean,
    isLoading: Boolean,
    /** Legacy `worker_or_crew` — free text, never split automatically. */
    legacyWorker: String,
    legacyHours: Double?,
    legacyRate: Double?,
    onAdd: () -> Unit,
    onEdit: (PruningActivityLabourLine) -> Unit,
    onConvertLegacy: (() -> Unit)?,
    modifier: Modifier = Modifier,
    pieceRateVineCount: Int? = null,
    pieceRatePerVine: Double? = null,
) {
    val vine = LocalVineColors.current
    val totals = remember(lines) { PruningActivityLabourCosting.totals(lines) }
    val isPieceRate = resolved.source == PruningActivityLabourCosting.Source.PIECE_RATE

    Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Labour", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Spacer(Modifier.weight(1f))
            if (canEdit) {
                TextButton(onClick = onAdd) {
                    Icon(
                        Icons.Filled.Add,
                        contentDescription = null,
                        modifier = Modifier.size(17.dp),
                        tint = VineColors.PrimaryAccent,
                    )
                    Text(
                        if (lines.isEmpty()) "  Add labour" else "  Add labour line",
                        fontSize = 13.sp,
                        color = VineColors.PrimaryAccent,
                    )
                }
            }
        }

        when (resolved.source) {
            // THE piece-rate cost of this job, shown in place of an hourly total
            // so the two are never presented as if they add up.
            PruningActivityLabourCosting.Source.PIECE_RATE -> PruningPieceRateSummary(
                cost = resolved.cost,
                vineCount = pieceRateVineCount,
                ratePerVine = pieceRatePerVine,
                canViewCosting = canViewCosting,
            )
            // Labour recorded on the linked Work Task before this activity owned
            // any. Displayed READ-THROUGH — the rows live in one place and are
            // never copied here, so the two modules cannot double-count.
            PruningActivityLabourCosting.Source.WORK_TASK_LINES -> PruningLabourNotice(
                title = "On the linked Work Task",
                icon = { Icon(Icons.Filled.Link, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(16.dp)) },
                amount = if (canViewCosting) resolved.cost else null,
                detail = buildString {
                    append(formatLabourHours(resolved.hours ?: 0.0))
                    append(" person-hours recorded on the Work Task. ")
                    append("Adding labour here makes this activity the record instead.")
                },
                tint = vine.textSecondary,
            )
            // A pre-SQL-190 single-crew record, shown EXACTLY as recorded.
            PruningActivityLabourCosting.Source.ACTIVITY_HOURS -> PruningLabourNotice(
                title = "Original crew record",
                icon = { Icon(Icons.Filled.History, contentDescription = null, tint = VineColors.Warning, modifier = Modifier.size(16.dp)) },
                amount = if (canViewCosting) resolved.cost else null,
                detail = buildString {
                    val parts = mutableListOf<String>()
                    legacyWorker.trim().takeIf { it.isNotBlank() }?.let { parts += it }
                    legacyHours?.let { parts += formatLabourHours(it) }
                    if (canViewCosting) legacyRate?.let { parts += "${formatLabourCurrency(it)}/h" }
                    append(if (parts.isEmpty()) "Recorded before labour lines existed." else parts.joinToString(" · "))
                    append(" — kept exactly as recorded.")
                },
                tint = VineColors.Warning,
            )
            else -> Unit
        }

        when {
            isLoading && lines.isEmpty() -> Box(
                Modifier.fillMaxWidth().padding(12.dp),
                contentAlignment = Alignment.Center,
            ) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), color = VineColors.LeafGreen)
            }

            lines.isEmpty() && resolved.source in setOf(
                PruningActivityLabourCosting.Source.PRUNING_LABOUR_LINES,
                PruningActivityLabourCosting.Source.NONE,
            ) -> Text(
                if (canEdit) {
                    "No labour lines yet. Add labour type, people and hours per person — one line per crew or rate."
                } else {
                    "No labour recorded on this activity."
                },
                color = vine.textSecondary,
                fontSize = 12.sp,
            )

            lines.isNotEmpty() -> Column(modifier = Modifier.fillMaxWidth()) {
                lines.forEachIndexed { index, line ->
                    if (index > 0) {
                        Box(Modifier.fillMaxWidth().height(0.5.dp).background(vine.cardBorder))
                    }
                    PruningActivityLabourLineRow(
                        line = line,
                        categoryName = operatorCategories.firstOrNull { it.id == line.operatorCategoryId }?.displayName,
                        canViewCosting = canViewCosting,
                        onClick = if (canEdit) ({ onEdit(line) }) else null,
                    )
                }
            }
        }

        if (!totals.isEmpty) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(VineColors.LeafGreen.copy(alpha = 0.10f))
                    .padding(horizontal = 12.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        "${totals.lineCount} labour line${if (totals.lineCount == 1) "" else "s"} · ${totals.workers} people",
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                    Text(
                        "${formatLabourHours(totals.personHours)} total labour hours",
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textPrimary,
                    )
                    // Hours count every line; cost counts only the rated ones —
                    // say so, rather than letting the two look inconsistent.
                    val unrated = lines.count { !it.isRated }
                    if (unrated > 0) {
                        Text(
                            if (unrated == lines.size) {
                                "No rates entered — hours are recorded, cost is not specified."
                            } else {
                                "$unrated line${if (unrated == 1) "" else "s"} without a rate: counted in hours, not in cost."
                            },
                            fontSize = 11.sp,
                            color = VineColors.Warning,
                        )
                    }
                }
                // On a piece-rate job the money belongs to the agreement above.
                if (canViewCosting && !isPieceRate) {
                    Text(
                        totals.cost?.let { formatLabourCurrency(it) } ?: "Not specified",
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Bold,
                        color = VineColors.PrimaryAccent,
                    )
                }
            }
        }

        // Converting a legacy record is an explicit USER action. It is offered,
        // never performed automatically, because `worker_or_crew` is free text
        // that cannot be honestly split into a worker type and a crew size.
        if (canEdit &&
            onConvertLegacy != null &&
            lines.isEmpty() &&
            resolved.source == PruningActivityLabourCosting.Source.ACTIVITY_HOURS
        ) {
            TextButton(onClick = onConvertLegacy) {
                Text(
                    "Convert to labour lines",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = VineColors.PrimaryAccent,
                )
            }
        }
    }
}

/**
 * One labour line row: labour type, `N× · H h each · P h total`, and the line
 * cost. An absent rate reads "No rate — hours only", never `$0.00`.
 */
@Composable
private fun PruningActivityLabourLineRow(
    line: PruningActivityLabourLine,
    categoryName: String?,
    canViewCosting: Boolean,
    onClick: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable { onClick() } else Modifier)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier.size(28.dp).clip(CircleShape).background(VineColors.Indigo.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.Groups, contentDescription = null, tint = VineColors.Indigo, modifier = Modifier.size(16.dp))
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            val title = categoryName ?: line.workerType.takeIf { it.isNotBlank() } ?: "Labour"
            Text(title, color = vine.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
            Text(
                "${line.workerCount}× · ${formatLabourHours(line.hoursPerWorker)} each · " +
                    "${formatLabourHours(PruningActivityLabourCosting.personHours(line))} person-hours",
                color = vine.textSecondary,
                fontSize = 12.sp,
                maxLines = 1,
            )
        }
        if (canViewCosting) {
            Text(
                PruningActivityLabourCosting.lineCost(line)?.let { formatLabourCurrency(it) }
                    ?: "No rate — hours only",
                color = vine.textPrimary,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
    }
}

/** A one-line attribution banner for labour that lives somewhere else. */
@Composable
private fun PruningLabourNotice(
    title: String,
    icon: @Composable () -> Unit,
    amount: Double?,
    detail: String,
    tint: Color,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(tint.copy(alpha = 0.08f))
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            icon()
            Text(title, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = tint)
            Spacer(Modifier.weight(1f))
            if (amount != null) {
                Text(
                    formatLabourCurrency(amount),
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Bold,
                    color = tint,
                )
            }
        }
        Text(detail, fontSize = 11.sp, color = vine.textSecondary)
    }
}

/**
 * The agreed piece-rate basis of a job. The rate itself is a commercial term:
 * reviewing it after the fact is owner/manager work, so a viewer without
 * costing visibility sees only the operational quantity.
 */
@Composable
private fun PruningPieceRateSummary(
    cost: Double?,
    vineCount: Int?,
    ratePerVine: Double?,
    canViewCosting: Boolean,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(VineColors.LeafGreen.copy(alpha = 0.10f))
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Piece rate", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = VineColors.LeafGreen)
            Spacer(Modifier.weight(1f))
            if (canViewCosting) {
                Text(
                    cost?.let { formatLabourCurrency(it) } ?: "Not specified",
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                    color = VineColors.LeafGreen,
                )
            }
        }
        if (canViewCosting && vineCount != null && ratePerVine != null) {
            Text(
                "${PieceRateCosting.vineCountLabel(vineCount)} vines × ${PieceRateCosting.rateLabel(ratePerVine)} per vine",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )
        }
        Text(
            "This job is paid per vine. Hours below are recorded for productivity — they never change what it costs.",
            fontSize = 11.sp,
            color = vine.textSecondary,
        )
    }
}

/**
 * The add/edit form for ONE pruning-activity labour line — the Kotlin twin of
 * the Swift `AddEditPruningActivityLabourLineView`.
 *
 * When a Work Task is linked this is ALSO the one place the job is priced: the
 * Hourly / Piece Rate choice lives here, so labour is never asked for twice
 * across two screens.
 *
 * Piece rate is a property of the linked Work Task (sql/188), NOT a labour type:
 * choosing it writes the task's costing basis, and any hours recorded alongside
 * it are saved as an UNRATED pruning labour line — operational history that
 * never moves the cost. A synthetic "piece rate" labour line is never created.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PruningActivityLabourLineSheet(
    operatorCategories: List<OperatorCategory>,
    existing: PruningActivityLabourLine?,
    canViewCosting: Boolean,
    isBusy: Boolean,
    onSave: (
        lineId: String?,
        operatorCategoryId: String?,
        workerType: String,
        workerCount: Int,
        hoursPerWorker: Double,
        hourlyRate: Double?,
        notes: String?,
    ) -> Unit,
    onDelete: ((String) -> Unit)?,
    onDismiss: () -> Unit,
    costingContext: WorkTaskCostingContext? = null,
    onSaveCosting: ((method: WorkTaskCostingMethod, ratePerVine: Double?, vineCount: Int?) -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)

    // Piece rate is offered to supervisors too — they settle the rate with the
    // crew at the vine, so blocking them would push pricing onto paper.
    val supportsPieceRate = costingContext != null &&
        onSaveCosting != null &&
        costingContext.canEnterPricing
    val isPricingLocked = costingContext?.isPricingLocked == true
    var costingMethod by remember {
        mutableStateOf(costingContext?.method ?: WorkTaskCostingMethod.HOURLY)
    }
    // A role that may not review the price never receives it — not even into a
    // field it cannot edit.
    var ratePerVineText by remember {
        mutableStateOf(
            costingContext?.savedRatePerVine
                ?.takeIf { !isPricingLocked }
                ?.let { trimPruningNumber(it) }
                .orEmpty(),
        )
    }
    var vineCountText by remember {
        mutableStateOf(
            (costingContext?.savedVineCount ?: costingContext?.suggestedVineCount)
                ?.takeIf { it > 0 && !isPricingLocked }
                ?.toString()
                .orEmpty(),
        )
    }

    var categoryId by remember { mutableStateOf(existing?.operatorCategoryId) }
    var workerType by remember { mutableStateOf(existing?.workerType ?: "") }
    var countText by remember { mutableStateOf((existing?.workerCount ?: 1).toString()) }
    var hoursText by remember {
        mutableStateOf(existing?.hoursPerWorker?.takeIf { it > 0 }?.let { trimPruningNumber(it) } ?: "")
    }
    var rateText by remember {
        mutableStateOf(
            existing?.hourlyRate?.let { trimPruningNumber(it) }
                ?: WorkTaskLabourCosting
                    .defaultRate(operatorCategories.firstOrNull { it.id == existing?.operatorCategoryId })
                    ?.let { trimPruningNumber(it) }
                ?: "",
        )
    }
    var notes by remember { mutableStateOf(existing?.notes ?: "") }
    var categoryMenu by remember { mutableStateOf(false) }
    var showIssues by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }

    val workerCount = countText.toIntOrNull()
    val hoursPerWorker = hoursText.replace(',', '.').toDoubleOrNull()
    val hourlyRate = rateText.replace(',', '.').toDoubleOrNull()
    // An EMPTY rate field is a deliberate "no rate entered", not zero.
    val rateProvided = rateText.isNotBlank()
    val resolvedType = operatorCategories.firstOrNull { it.id == categoryId }?.displayName ?: workerType

    val issues = PruningActivityLabourCosting.validate(
        labourType = resolvedType,
        workerCount = workerCount,
        hoursPerWorker = hoursPerWorker,
        hourlyRate = hourlyRate,
        rateProvided = rateProvided,
    )
    val personHours = PruningActivityLabourCosting.personHours(workerCount ?: 0, hoursPerWorker ?: 0.0)
    val lineCost = if (rateProvided && hourlyRate != null && hourlyRate.isFinite()) {
        personHours * hourlyRate.coerceAtLeast(0.0)
    } else {
        null
    }

    val isPieceRate = supportsPieceRate && costingMethod == WorkTaskCostingMethod.PIECE_RATE
    val ratePerVine = ratePerVineText.replace(',', '.').toDoubleOrNull()
    val vineCount = vineCountText.replace(",", "").toIntOrNull()
    val pieceIssues = PieceRateCosting.validate(ratePerVine, vineCount)
    val pieceCost = PieceRateCosting.cost(vineCount, ratePerVine)
    val canSeePieceCost = canViewCosting || (isPieceRate && !isPricingLocked)
    // On a piece-rate job people and hours are OPTIONAL operational history, so
    // they must never block the save.
    val recordsOptionalHours = (workerCount ?: 0) > 0 && (hoursPerWorker ?: 0.0) > 0.0

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                if (existing == null) "Add labour line" else "Edit labour line",
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = vine.textPrimary,
            )
            Text(
                if (isPieceRate) {
                    "Paid per vine. The agreed rate is multiplied by the vines in the rows selected for this job — hours never change a piece-rate cost."
                } else {
                    "Labour belongs to this pruning activity and is counted once, however many blocks it covers. Person-hours = people × hours each; cost = person-hours × rate."
                },
                fontSize = 12.sp,
                color = vine.textSecondary,
            )

            if (supportsPieceRate) {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        "How is this job paid?",
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textPrimary,
                    )
                    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                        WorkTaskCostingMethod.entries.forEachIndexed { index, method ->
                            SegmentedButton(
                                selected = costingMethod == method,
                                onClick = { if (!isPricingLocked) costingMethod = method },
                                enabled = !isPricingLocked,
                                shape = SegmentedButtonDefaults.itemShape(
                                    index = index,
                                    count = WorkTaskCostingMethod.entries.size,
                                ),
                            ) { Text(method.label) }
                        }
                    }
                    if (isPricingLocked) {
                        Text(
                            "This job has already been priced. Ask an owner or manager to review or change how it is paid.",
                            fontSize = 11.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
            }

            if (isPieceRate) {
                if (isPricingLocked) {
                    // The agreed figures are withheld deliberately: reviewing a
                    // price is owner/manager work, and showing the amount
                    // read-only would BE the review.
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .background(VineColors.LeafGreen.copy(alpha = 0.10f))
                            .padding(horizontal = 12.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Icon(
                            Icons.Filled.Lock,
                            contentDescription = null,
                            tint = VineColors.LeafGreen,
                            modifier = Modifier.size(16.dp),
                        )
                        Text(
                            "The agreed rate is locked. Ask an owner or manager to review or change it. You can still record hours below.",
                            fontSize = 11.sp,
                            color = vine.textSecondary,
                        )
                    }
                } else {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            OutlinedTextField(
                                value = ratePerVineText,
                                onValueChange = {
                                    ratePerVineText = it.filter { c -> c.isDigit() || c == '.' || c == ',' }
                                },
                                label = { Text("Rate per vine") },
                                placeholder = { Text("0.00") },
                                singleLine = true,
                                isError = showIssues && PieceRateCosting.message(
                                    pieceIssues,
                                    PieceRateCosting.PieceRateField.RATE_PER_VINE,
                                ) != null,
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                                modifier = Modifier.fillMaxWidth(),
                            )
                            if (showIssues) {
                                PieceRateCosting
                                    .message(pieceIssues, PieceRateCosting.PieceRateField.RATE_PER_VINE)
                                    ?.let { PruningInlineIssue(it) }
                            }
                        }
                        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            OutlinedTextField(
                                value = vineCountText,
                                onValueChange = { vineCountText = it.filter { c -> c.isDigit() } },
                                label = { Text("Vines in this job") },
                                placeholder = { Text("0") },
                                singleLine = true,
                                isError = showIssues && PieceRateCosting.message(
                                    pieceIssues,
                                    PieceRateCosting.PieceRateField.VINE_COUNT,
                                ) != null,
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                modifier = Modifier.fillMaxWidth(),
                            )
                            if (showIssues) {
                                PieceRateCosting
                                    .message(pieceIssues, PieceRateCosting.PieceRateField.VINE_COUNT)
                                    ?.let { PruningInlineIssue(it) }
                            }
                        }
                    }
                    val suggested = costingContext?.suggestedVineCount
                    if (suggested != null && suggested > 0 && vineCount != suggested) {
                        TextButton(onClick = { vineCountText = suggested.toString() }) {
                            Text(
                                "Use ${PieceRateCosting.vineCountLabel(suggested)} vines from the selected rows",
                                fontSize = 12.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = VineColors.PrimaryAccent,
                            )
                        }
                    }
                }
            }

            // Labour type — also supplies its saved hourly rate as the default.
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                ExposedDropdownMenuBox(expanded = categoryMenu, onExpandedChange = { categoryMenu = it }) {
                    OutlinedTextField(
                        value = operatorCategories.firstOrNull { it.id == categoryId }?.displayName
                            ?: workerType.takeIf { it.isNotBlank() }
                            ?: "Choose labour type",
                        onValueChange = {},
                        readOnly = true,
                        isError = showIssues && !isPieceRate && WorkTaskLabourCosting.message(
                            issues,
                            WorkTaskLabourCosting.LabourLineField.LABOUR_TYPE,
                        ) != null,
                        label = { Text("Labour type") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = categoryMenu) },
                        modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                    )
                    ExposedDropdownMenu(expanded = categoryMenu, onDismissRequest = { categoryMenu = false }) {
                        operatorCategories.forEach { category ->
                            DropdownMenuItem(
                                text = {
                                    Text(
                                        WorkTaskLabourCosting.defaultRate(category)
                                            ?.let { "${category.displayName} · ${formatLabourCurrency(it)}/h" }
                                            ?: category.displayName,
                                    )
                                },
                                onClick = {
                                    categoryId = category.id
                                    workerType = category.displayName
                                    // The labour type's saved rate is the
                                    // default; an explicit edit is never
                                    // overwritten.
                                    WorkTaskLabourCosting.defaultRate(category)
                                        ?.let { rateText = trimPruningNumber(it) }
                                    categoryMenu = false
                                },
                            )
                        }
                    }
                }
                if (showIssues && !isPieceRate) {
                    WorkTaskLabourCosting
                        .message(issues, WorkTaskLabourCosting.LabourLineField.LABOUR_TYPE)
                        ?.let { PruningInlineIssue(it) }
                }
                if (operatorCategories.isEmpty()) {
                    Text(
                        "Add labour types in Settings → Worker Types to get saved hourly rates.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                }
            }

            if (isPieceRate) {
                Text(
                    "Hours worked (optional)",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = vine.textPrimary,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    OutlinedTextField(
                        value = countText,
                        onValueChange = { countText = it.filter { c -> c.isDigit() } },
                        label = { Text("Number of people") },
                        singleLine = true,
                        isError = showIssues && !isPieceRate && WorkTaskLabourCosting.message(
                            issues,
                            WorkTaskLabourCosting.LabourLineField.WORKER_COUNT,
                        ) != null,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    if (showIssues && !isPieceRate) {
                        WorkTaskLabourCosting
                            .message(issues, WorkTaskLabourCosting.LabourLineField.WORKER_COUNT)
                            ?.let { PruningInlineIssue(it) }
                    }
                }
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    OutlinedTextField(
                        value = hoursText,
                        onValueChange = { hoursText = it.filter { c -> c.isDigit() || c == '.' || c == ',' } },
                        label = { Text("Hours per person") },
                        singleLine = true,
                        isError = showIssues && !isPieceRate && WorkTaskLabourCosting.message(
                            issues,
                            WorkTaskLabourCosting.LabourLineField.HOURS_PER_WORKER,
                        ) != null,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    if (showIssues && !isPieceRate) {
                        WorkTaskLabourCosting
                            .message(issues, WorkTaskLabourCosting.LabourLineField.HOURS_PER_WORKER)
                            ?.let { PruningInlineIssue(it) }
                    }
                }
            }
            if (isPieceRate) {
                Text(
                    "Optional. Hours are kept as operational history on a piece-rate job — they never change what it costs. Leave blank if you are not tracking them.",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )
            }

            if (canViewCosting && !isPieceRate) {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    OutlinedTextField(
                        value = rateText,
                        onValueChange = { rateText = it.filter { c -> c.isDigit() || c == '.' || c == ',' } },
                        label = { Text("Hourly rate (optional)") },
                        singleLine = true,
                        isError = showIssues && WorkTaskLabourCosting.message(
                            issues,
                            WorkTaskLabourCosting.LabourLineField.HOURLY_RATE,
                        ) != null,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    if (showIssues) {
                        WorkTaskLabourCosting
                            .message(issues, WorkTaskLabourCosting.LabourLineField.HOURLY_RATE)
                            ?.let { PruningInlineIssue(it) }
                    }
                    Text(
                        "Leave blank if no rate has been agreed. The hours still count; the cost is reported as not specified rather than $0.00.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                }
            }

            OutlinedTextField(
                value = notes,
                onValueChange = { notes = it },
                label = { Text("Notes (optional)") },
                modifier = Modifier.fillMaxWidth(),
            )

            // Live calculation — always visible, so the operator sees the effect
            // of every keystroke before saving.
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(vine.cardBorder.copy(alpha = 0.4f))
                    .padding(horizontal = 12.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    "${workerCount ?: 0} × ${trimPruningNumber(hoursPerWorker ?: 0.0)} h = ${formatLabourHours(personHours)} person-hours",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = vine.textPrimary,
                )
                if (isPieceRate) {
                    if (canSeePieceCost) {
                        Text(
                            "Piece-rate cost " + (pieceCost?.let { formatLabourCurrency(it) } ?: "not specified"),
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = VineColors.LeafGreen,
                        )
                        Text(
                            "${PieceRateCosting.vineCountLabel(vineCount ?: 0)} vines × " +
                                "${PieceRateCosting.rateLabel(ratePerVine ?: 0.0)} per vine. " +
                                "Hours above are recorded but do not affect this.",
                            fontSize = 11.sp,
                            color = vine.textSecondary,
                        )
                    } else {
                        Text(
                            "Hours are recorded as operational history — they do not affect what this job costs.",
                            fontSize = 11.sp,
                            color = vine.textSecondary,
                        )
                    }
                } else if (canViewCosting) {
                    Text(
                        lineCost?.let { "Line cost ${formatLabourCurrency(it)}" } ?: "Line cost not specified",
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                }
            }

            Button(
                onClick = {
                    showIssues = true
                    when {
                        // Pricing is untouchable for this role — only the
                        // optional hours are written, and the costing basis is
                        // left alone.
                        isPieceRate && isPricingLocked -> {
                            if (recordsOptionalHours) {
                                onSave(
                                    existing?.id,
                                    categoryId,
                                    resolvedType.trim(),
                                    workerCount ?: 0,
                                    hoursPerWorker ?: 0.0,
                                    null,
                                    notes.trim().ifBlank { null },
                                )
                            } else {
                                onDismiss()
                            }
                        }

                        // Piece rate: the AGREEMENT lives on the task, so a
                        // completed job keeps the quantity it was priced on.
                        // Hours, if given, become an UNRATED labour line.
                        isPieceRate -> {
                            if (pieceIssues.isEmpty()) {
                                onSaveCosting?.invoke(
                                    WorkTaskCostingMethod.PIECE_RATE,
                                    ratePerVine,
                                    vineCount,
                                )
                                if (recordsOptionalHours) {
                                    onSave(
                                        existing?.id,
                                        categoryId,
                                        resolvedType.trim(),
                                        workerCount ?: 0,
                                        hoursPerWorker ?: 0.0,
                                        null,
                                        notes.trim().ifBlank { null },
                                    )
                                } else {
                                    onDismiss()
                                }
                            }
                        }

                        issues.isEmpty() -> {
                            // Switching back to hourly clears the piece-rate
                            // basis, so this activity's own lines become the
                            // whole cost.
                            if (supportsPieceRate && costingContext?.isPieceRate == true) {
                                onSaveCosting?.invoke(WorkTaskCostingMethod.HOURLY, null, null)
                            }
                            onSave(
                                existing?.id,
                                categoryId,
                                resolvedType.trim(),
                                workerCount ?: 0,
                                hoursPerWorker ?: 0.0,
                                if (rateProvided) hourlyRate else null,
                                notes.trim().ifBlank { null },
                            )
                        }
                    }
                },
                enabled = !isBusy,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
            ) {
                if (isBusy) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White)
                } else {
                    Text(
                        when {
                            isPieceRate && !isPricingLocked -> "Save piece rate"
                            existing == null -> "Add labour line"
                            else -> "Save labour line"
                        },
                    )
                }
            }

            if (existing != null && onDelete != null) {
                TextButton(onClick = { confirmDelete = true }, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Filled.Delete, contentDescription = null, tint = VineColors.Destructive)
                    Text("  Remove labour line", color = VineColors.Destructive)
                }
            }
        }
    }

    if (confirmDelete && existing != null && onDelete != null) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Remove labour line?") },
            text = {
                Text("This removes the line for your whole team. The pruning activity and its other labour lines are kept.")
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    onDelete(existing.id)
                }) { Text("Remove", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun PruningInlineIssue(message: String) {
    Text(message, fontSize = 11.sp, color = VineColors.Destructive)
}

private fun trimPruningNumber(value: Double): String =
    if (value % 1.0 == 0.0) value.toInt().toString() else "%.2f".format(value).trimEnd('0').trimEnd('.')
