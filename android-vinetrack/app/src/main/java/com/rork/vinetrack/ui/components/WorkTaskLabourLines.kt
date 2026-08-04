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
) {
    val vine = LocalVineColors.current
    val totals = remember(lines) { WorkTaskLabourCosting.totals(lines) }
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
                    Text("  Add labour line", fontSize = 13.sp, color = VineColors.PrimaryAccent)
                }
            }
        }

        when {
            isLoading && lines.isEmpty() -> Box(
                Modifier.fillMaxWidth().padding(12.dp),
                contentAlignment = Alignment.Center,
            ) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), color = VineColors.LeafGreen)
            }

            lines.isEmpty() -> Text(
                if (canEdit) {
                    "No labour lines yet. Add labour type, people and hours per person to record the cost."
                } else {
                    "No labour lines recorded on this task."
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
                if (canViewCosting) {
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
 * The standard labour-line form. Labour type seeds its saved hourly rate;
 * person-hours and line cost recalculate live as the operator types.
 *
 * Validation is [WorkTaskLabourCosting.validate] — shown inline, and nothing
 * entered is discarded when it fails.
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
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)

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
                "Labour belongs to the Work Task. Person-hours = people × hours each; cost = person-hours × rate.",
                fontSize = 12.sp,
                color = vine.textSecondary,
            )

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

            if (canViewCosting) {
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
                if (canViewCosting) {
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
                    if (issues.isEmpty()) {
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
                },
                enabled = !isBusy,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
            ) {
                if (isBusy) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White)
                } else {
                    Text(if (existing == null) "Add labour line" else "Save labour line")
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
