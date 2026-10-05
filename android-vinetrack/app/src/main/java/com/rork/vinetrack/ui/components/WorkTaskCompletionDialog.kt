package com.rork.vinetrack.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.WorkTaskCompletion
import com.rork.vinetrack.data.model.WorkTask
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/** Business-date confirmation with UTC picker values interpreted as calendar dates, not instants. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WorkTaskCompletionDialog(task: WorkTask, zone: ZoneId, onConfirm: (LocalDate) -> Unit, onDismiss: () -> Unit, modifier: Modifier = Modifier) {
    val today = Instant.now().atZone(zone).toLocalDate()
    val workDate = WorkTaskCompletion.workDate(task, zone)
    val initial = if (task.isFinalized) WorkTaskCompletion.completedDate(task, zone) ?: today else today
    var selected by remember(task.id) { mutableStateOf(initial) }
    var showPicker by remember { mutableStateOf(false) }
    val format = DateTimeFormatter.ofPattern("d MMMM yyyy")
    val valid = WorkTaskCompletion.isValid(task, selected, zone, Instant.now())
    AlertDialog(
        modifier = modifier,
        onDismissRequest = onDismiss,
        title = { Text(if (task.isFinalized) "Edit Completed Date" else "Complete Work Task") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Work Date — ${workDate?.format(format) ?: "Not recorded"}")
                OutlinedButton(onClick = { showPicker = true }) { Text("Completed Date — ${selected.format(format)}") }
                Text("Choose a date between the Work Date and today. The completion audit timestamp is recorded separately.")
                if (!valid) Text("Completed Date cannot precede Work Date or be in the future.", color = MaterialTheme.colorScheme.error)
            }
        },
        confirmButton = { TextButton(onClick = { onConfirm(selected) }, enabled = valid) { Text(if (task.isFinalized) "Save date" else "Complete") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
    if (showPicker) {
        val picker = rememberDatePickerState(
            initialSelectedDateMillis = selected.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli(),
            selectableDates = object : SelectableDates {
                override fun isSelectableDate(utcTimeMillis: Long): Boolean {
                    val day = Instant.ofEpochMilli(utcTimeMillis).atZone(ZoneOffset.UTC).toLocalDate()
                    return !day.isAfter(today) && (workDate == null || !day.isBefore(workDate))
                }
            },
        )
        DatePickerDialog(onDismissRequest = { showPicker = false },
            confirmButton = { TextButton(onClick = {
                picker.selectedDateMillis?.let { selected = Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate() }
                showPicker = false
            }, enabled = picker.selectedDateMillis != null) { Text("Choose date") } },
            dismissButton = { TextButton(onClick = { showPicker = false }) { Text("Cancel") } },
        ) { DatePicker(state = picker) }
    }
}
