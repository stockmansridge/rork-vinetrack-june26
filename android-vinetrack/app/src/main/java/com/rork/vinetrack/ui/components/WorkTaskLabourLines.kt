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
import com.rork.vinetrack.data.WorkTaskLabourCosting
import com.rork.vinetrack.data.model.OperatorCategory
import com.rork.vinetrack.data.model.PieceRateCosting
import com.rork.vinetrack.data.model.WorkTaskCostingMethod
import com.rork.vinetrack.data.model.WorkTaskLabourLine
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/**
 * THE standard Work Task labour-line surface — one implementation shared by the
 * Work Task detail screen and the Pruning Activity editor, so the two can never
 * drift into two incompatible labour editors.
 *
 * Labour lines belong to the PARENT Work Task, never to a pruning allocation:
 * labour type, hourly rate, worker count, hours per worker, person-hours and
 * cost are all owned here. The Pruning Activity keeps only operational output
 * and its `work_task_id`.
 *
 * Every number comes from [WorkTaskLabourCosting], which is mirrored 1:1 in
 * Swift, so iOS and Android produce identical totals.
 */

/**
 * Optional piece-rate capability for the labour surface (sql/188) — the Kotlin
 * twin of the Swift `WorkTaskCostingContext`.
 *
 * Supplied by hosts that already know which rows a job covers (the Pruning
 * Activity editor, where blocks and quarters are chosen before labour). When
 * present, the ONE labour sheet offers the Hourly / Piece Rate choice and owns
 * writing `work_tasks.costing_method`. When absent the sheet behaves exactly as
 * it always has, so every existing caller is untouched and every legacy task
 * stays hourly.
 */
data class WorkTaskCostingContext(
    val taskId: String,
    /** The task's CURRENT basis, so reopening shows the agreement in force. */
    val method: WorkTaskCostingMethod = WorkTaskCostingMethod.HOURLY,
    /**
     * Vines under the rows already selected — the DEFAULT piece-rate quantity,
     * so the operator confirms a number rather than counting one.
     */
    val suggestedVineCount: Int? = null,
    val savedRatePerVine: Double? = null,
    val savedVineCount: Int? = null,
    /**
     * May AGREE a price in the field. Supervisors and above — they are the ones
     * settling the rate with the crew at the vine.
     */
    val canEnterPricing: Boolean = false,
    /**
     * May REVIEW or CHANGE a price already agreed, and see money totals.
     * Owners and managers only.
     */
    val canReviewPricing: Boolean = false,
) {
    /** True once this job carries an agreed price. */
    val isAlreadyPriced: Boolean get() = (savedRatePerVine ?: 0.0) > 0.0

    /**
     * A supervisor may set the price once; revisiting it afterwards is
     * owner/manager work. The figures are WITHHELD rather than shown read-only
     * — an amount on screen is exactly what "review" means.
     */
    val isPricingLocked: Boolean get() = isAlreadyPriced && !canReviewPricing

    val isPieceRate: Boolean get() = method == WorkTaskCostingMethod.PIECE_RATE

    /** THE agreed cost of this job, when the viewer is allowed a figure. */
    val pieceCost: Double? get() = PieceRateCosting.cost(savedVineCount, savedRatePerVine)
}

/** Rounded currency label, e.g. "$1,250" / "$42.50". */
fun formatLabourCurrency(value: Double): String {
    val rounded = if (value % 1.0 == 0.0) "%,d".format(value.toLong()) else "%,.2f".format(value)
    return "$$rounded"
}

/** Compact hours label, e.g. "18 h", "7.5 h". */
fun formatLabourHours(hours: Double): String =
    if (hours % 1.0 == 0.0) "${hours.toInt()} h" else "%.1f h".format(hours)

private fun trimNumber(value: Double): String =
    if (value % 1.0 == 0.0) value.toInt().toString() else "%.2f".format(value).trimEnd('0').trimEnd('.')

/**
 * One labour line row: labour type, `N× · H h each · P h total`, and the line
 * cost. An absent rate reads "Not specified" — never `$0.00`.
 */
@Composable
fun WorkTaskLabourLineRow(
    line: WorkTaskLabourLine,
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
            val personHours = WorkTaskLabourCosting.personHours(line)
            Text(
                "${line.workerCount}× · ${formatLabourHours(line.hoursPerWorker)} each · ${formatLabourHours(personHours)} person-hours",
                color = vine.textSecondary,
                fontSize = 12.sp,
                maxLines = 1,
            )
        }
        if (canViewCosting) {
            val cost = WorkTaskLabourCosting.lineCost(line)
            Text(
                cost?.let { formatLabourCurrency(it) } ?: "Not specified",
                color = vine.textPrimary,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
    }
}

/**
 * The standard labour list + totals + add/edit/remove entry points for ONE Work
 * Task. Drop it into any screen that owns a task id.
 *
 * @param canEdit false renders read-only (no Add, rows not tappable).
 * @param canViewCosting false hides every monetary value; person-hours remain.
 * @param costingContext non-null lets the ONE add/edit sheet choose Hourly or
 *   Piece Rate, and renders the piece-rate agreement in place of an hourly
 *   money total so the two are never presented as if they add up.
 */
@Composable
fun WorkTaskLabourLinesSection(
    lines: List<WorkTaskLabourLine>,
    operatorCategories: List<OperatorCategory>,
    canEdit: Boolean,
    canViewCosting: Boolean,
    isLoading: Boolean,
    onAdd: () -> Unit,
    onEdit: (WorkTaskLabourLine) -> Unit,
    modifier: Modifier = Modifier,
    costingContext: WorkTaskCostingContext? = null,
) {
    val vine = LocalVineColors.current
    val totals = remember(lines) { WorkTaskLabourCosting.totals(lines) }
    val isPieceRate = costingContext?.isPieceRate == true
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
                        if (costingContext != null && lines.isEmpty() && !isPieceRate) "  Add labour" else "  Add labour line",
                        fontSize = 13.sp,
                        color = VineColors.PrimaryAccent,
                    )
                }
            }
        }

        // THE piece-rate cost of this job, shown in place of an hourly total.
        if (isPieceRate && costingContext != null) {
            PieceRateSummary(context = costingContext, hours = totals.personHours)
        }

        when {
            isLoading && lines.isEmpty() -> Box(
                Modifier.fillMaxWidth().padding(12.dp),
                contentAlignment = Alignment.Center,
            ) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), color = VineColors.LeafGreen)
            }

            // On a piece-rate job, having no hourly lines is the normal, correct
            // outcome — the empty state must not read as an error.
            lines.isEmpty() -> Text(
                when {
                    isPieceRate -> "No hours recorded. This job is paid per vine, so hours are optional."
                    canEdit -> "No labour lines yet. Add labour type, people and hours per person to record the cost."
                    else -> "No labour lines recorded on this task."
                },
                color = vine.textSecondary,
                fontSize = 12.sp,
            )

            else -> Column(modifier = Modifier.fillMaxWidth()) {
                lines.forEachIndexed { index, line ->
                    if (index > 0) {
                        Box(Modifier.fillMaxWidth().height(0.5.dp).background(vine.cardBorder))
                    }
                    WorkTaskLabourLineRow(
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
                        "${formatLabourHours(totals.personHours)} total person-hours",
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textPrimary,
                    )
                }
                // On a piece-rate job the money belongs to the agreement above,
                // so only the hours are summarised here.
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
    }
}

/**
 * The agreed piece-rate basis of a job. The rate itself is a commercial term:
 * reviewing it after the fact is owner/manager work, so a supervisor sees only
 * the operational quantity they worked.
 */
@Composable
private fun PieceRateSummary(context: WorkTaskCostingContext, hours: Double) {
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
            Text(
                "Piece rate",
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                color = VineColors.LeafGreen,
            )
            Spacer(Modifier.weight(1f))
            if (context.canReviewPricing) {
                Text(
                    context.pieceCost?.let { formatLabourCurrency(it) } ?: "Not specified",
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                    color = VineColors.LeafGreen,
                )
            }
        }
        val vines = context.savedVineCount
        val rate = context.savedRatePerVine
        if (context.canReviewPricing && vines != null && rate != null) {
            Text(
                "${PieceRateCosting.vineCountLabel(vines)} vines × ${PieceRateCosting.rateLabel(rate)} per vine",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )
        } else if (vines != null && vines > 0) {
            Text(
                "${PieceRateCosting.vineCountLabel(vines)} vines priced per vine",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )
        }
        if (hours > 0) {
            Text(
                "${formatLabourHours(hours)} recorded for history — hours do not change this cost.",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )
        }
    }
}

/**
 * The standard labour-line form. Labour type seeds its saved hourly rate;
 * person-hours and line cost recalculate live as the operator types.
 *
 * Validation is [WorkTaskLabourCosting.validate] — shown inline, and nothing
 * entered is discarded when it fails.
 *
 * When [costingContext] is supplied this is ALSO the one place a job is priced:
 * the Hourly / Piece Rate choice lives here, so labour is never asked for twice
 * across two screens.
 *
 * @param onSaveCosting writes the task's costing basis. Called before the line
 *   itself, because the basis decides whether the line is a cost or just
 *   operational history.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WorkTaskLabourLineSheet(
    operatorCategories: List<OperatorCategory>,
    existing: WorkTaskLabourLine?,
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
                ?.let { trimNumber(it) }
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
        mutableStateOf(existing?.hoursPerWorker?.takeIf { it > 0 }?.let { trimNumber(it) } ?: "")
    }
    var rateText by remember {
        mutableStateOf(
            existing?.hourlyRate?.let { trimNumber(it) }
                ?: WorkTaskLabourCosting
                    .defaultRate(operatorCategories.firstOrNull { it.id == existing?.operatorCategoryId })
                    ?.let { trimNumber(it) }
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
    val rateProvided = rateText.isNotBlank()
    val resolvedType = operatorCategories.firstOrNull { it.id == categoryId }?.displayName
        ?: workerType

    val issues = WorkTaskLabourCosting.validate(
        labourType = resolvedType,
        workerCount = workerCount,
        hoursPerWorker = hoursPerWorker,
        hourlyRate = hourlyRate,
        rateProvided = rateProvided,
    )
    val personHours = WorkTaskLabourCosting.personHours(workerCount ?: 0, hoursPerWorker ?: 0.0)
    val lineCost = WorkTaskLabourCosting.lineCost(
        workerCount ?: 0,
        hoursPerWorker ?: 0.0,
        if (rateProvided) hourlyRate else null,
    )

    val isPieceRate = supportsPieceRate && costingMethod == WorkTaskCostingMethod.PIECE_RATE
    val ratePerVine = ratePerVineText.replace(',', '.').toDoubleOrNull()
    val vineCount = vineCountText.replace(",", "").toIntOrNull()
    val pieceIssues = PieceRateCosting.validate(ratePerVine, vineCount)
    val pieceCost = PieceRateCosting.cost(vineCount, ratePerVine)
    // Managers always; plus the supervisor agreeing the price right now, so they
    // can sanity-check the total before committing to it.
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
                    "Labour belongs to the Work Task. Person-hours = people × hours each; cost = person-hours × rate."
                },
                fontSize = 12.sp,
                color = vine.textSecondary,
            )

            // THE single switch between the two costing methods (sql/188).
            // Choosing one here is what decides which figure this job is costed
            // on — the two are never summed.
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
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(
                                "Priced per vine",
                                fontSize = 13.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = VineColors.LeafGreen,
                            )
                            Text(
                                "The agreed rate is locked. Ask an owner or manager to review or change it. You can still record hours below.",
                                fontSize = 11.sp,
                                color = vine.textSecondary,
                            )
                        }
                    }
                } else {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
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
                                    isError = showIssues &&
                                        PieceRateCosting.message(
                                            pieceIssues,
                                            PieceRateCosting.PieceRateField.RATE_PER_VINE,
                                        ) != null,
                                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                                    modifier = Modifier.fillMaxWidth(),
                                )
                                if (showIssues) {
                                    PieceRateCosting
                                        .message(pieceIssues, PieceRateCosting.PieceRateField.RATE_PER_VINE)
                                        ?.let { InlineIssue(it) }
                                }
                            }
                            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                OutlinedTextField(
                                    value = vineCountText,
                                    onValueChange = { vineCountText = it.filter { c -> c.isDigit() } },
                                    label = { Text("Vines in this job") },
                                    placeholder = { Text("0") },
                                    singleLine = true,
                                    isError = showIssues &&
                                        PieceRateCosting.message(
                                            pieceIssues,
                                            PieceRateCosting.PieceRateField.VINE_COUNT,
                                        ) != null,
                                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                    modifier = Modifier.fillMaxWidth(),
                                )
                                if (showIssues) {
                                    PieceRateCosting
                                        .message(pieceIssues, PieceRateCosting.PieceRateField.VINE_COUNT)
                                        ?.let { InlineIssue(it) }
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
                        Text(
                            "Counted automatically from the rows selected for this job — each row's own vine count, or your manual count where you set one. Adjust it here if you agreed a different quantity.",
                            fontSize = 11.sp,
                            color = vine.textSecondary,
                        )
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
                        isError = showIssues &&
                            WorkTaskLabourCosting.message(issues, WorkTaskLabourCosting.LabourLineField.LABOUR_TYPE) != null,
                        label = { Text("Labour type") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = categoryMenu) },
                        modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                    )
                    ExposedDropdownMenu(
                        expanded = categoryMenu,
                        onDismissRequest = { categoryMenu = false },
                    ) {
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
                                    // The labour type's saved rate is the default;
                                    // an explicit edit is never overwritten.
                                    WorkTaskLabourCosting.defaultRate(category)?.let { rateText = trimNumber(it) }
                                    categoryMenu = false
                                },
                            )
                        }
                    }
                }
                if (showIssues) {
                    WorkTaskLabourCosting
                        .message(issues, WorkTaskLabourCosting.LabourLineField.LABOUR_TYPE)
                        ?.let { InlineIssue(it) }
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
                        isError = showIssues &&
                            WorkTaskLabourCosting.message(issues, WorkTaskLabourCosting.LabourLineField.WORKER_COUNT) != null,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    if (showIssues) {
                        WorkTaskLabourCosting
                            .message(issues, WorkTaskLabourCosting.LabourLineField.WORKER_COUNT)
                            ?.let { InlineIssue(it) }
                    }
                }
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    OutlinedTextField(
                        value = hoursText,
                        onValueChange = { hoursText = it.filter { c -> c.isDigit() || c == '.' || c == ',' } },
                        label = { Text("Hours per person") },
                        singleLine = true,
                        isError = showIssues &&
                            WorkTaskLabourCosting.message(issues, WorkTaskLabourCosting.LabourLineField.HOURS_PER_WORKER) != null,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    if (showIssues) {
                        WorkTaskLabourCosting
                            .message(issues, WorkTaskLabourCosting.LabourLineField.HOURS_PER_WORKER)
                            ?.let { InlineIssue(it) }
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
                        label = { Text("Hourly rate") },
                        singleLine = true,
                        isError = showIssues &&
                            WorkTaskLabourCosting.message(issues, WorkTaskLabourCosting.LabourLineField.HOURLY_RATE) != null,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    if (showIssues) {
                        WorkTaskLabourCosting
                            .message(issues, WorkTaskLabourCosting.LabourLineField.HOURLY_RATE)
                            ?.let { InlineIssue(it) }
                    }
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
                    "${workerCount ?: 0} × ${trimNumber(hoursPerWorker ?: 0.0)} h = ${formatLabourHours(personHours)} person-hours",
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
                        // Pricing is untouchable for this role — only the optional
                        // hours are written, and the costing basis is left alone.
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
                        // Hours, if given, are ordinary operational history.
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
                            // basis, so the hourly lines become the whole cost.
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
            text = { Text("This removes the line for your whole team. The Work Task itself is kept.") },
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
private fun InlineIssue(message: String) {
    Text(message, fontSize = 11.sp, color = VineColors.Destructive)
}
