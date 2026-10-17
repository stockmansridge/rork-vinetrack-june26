package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.TrackingPattern
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.TripOccurrenceCoverage
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/** Read-only projection. Never infers coverage from GPS, cursor position or a repeated label. */
internal data class LiveTripGuidance(
    val current: Double?, val next: Double?, val mode: String?,
    val block: String?, val pass: Int?, val position: Int, val total: Int,
    val done: Int, val skipped: Int,
) {
    val hasPlan: Boolean get() = total > 0
    companion object {
        fun from(trip: Trip): LiveTripGuidance {
            if (trip.coverageBasis != TripOccurrenceCoverage.Basis.LEGACY) {
                val d = trip.occurrenceDocument
                    ?: return LiveTripGuidance(null, null, "Recovery required", null, null, 0, 0, 0, 0)
                val target = d.items.singleOrNull { it.id == d.targetId }
                val next = d.order.firstOrNull { it != d.targetId && d.status(it) == "incomplete" }
                    ?.let { id -> d.items.singleOrNull { it.id == id }?.label }
                return LiveTripGuidance(target?.label, next, if (target == null) "Plan complete" else null,
                    target?.blockName, target?.pass, (d.order.indexOf(d.targetId) + 1).coerceAtLeast(0),
                    d.order.size, d.count("done"), d.count("skipped"))
            }
            val sequence = trip.rowSequence
            if (sequence.isEmpty()) {
                val free = trip.trackingPattern == null || trip.trackingPattern == "freeDrive"
                return LiveTripGuidance(null, null, if (free) "Free Drive" else "Waiting for plan", trip.paddockName, null, 0, 0, 0, 0)
            }
            // Match the existing legacy action cursor; do not adopt the GPS-detected row.
            val current = sequence.getOrNull(trip.sequenceIndex)
            val next = sequence.drop((trip.sequenceIndex + 1).coerceAtLeast(0)).firstOrNull {
                it !in trip.completedPaths.orEmpty() && it !in trip.skippedPaths.orEmpty()
            }
            return LiveTripGuidance(current, next, if (current == null) "Plan complete" else null,
                trip.paddockName, null, (trip.sequenceIndex + 1).coerceIn(1, sequence.size), sequence.size,
                sequence.count { it in trip.completedPaths.orEmpty() }, sequence.count { it in trip.skippedPaths.orEmpty() })
        }
    }
}

/** Compact iOS hierarchy with Android-native type, opaque surfaces and accessible reflow. */
@Composable
internal fun LiveTripInformation(
    trip: Trip,
    guidance: LiveTripGuidance,
    distance: String,
    duration: String,
    speed: String,
    gps: String,
    gpsColor: Color,
    eta: String,
    modifier: Modifier = Modifier,
    quickActions: @Composable () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(modifier.fillMaxWidth()) {
        Box(Modifier.padding(horizontal = 12.dp)) { quickActions() }
        val facts = listOf(
            Triple("CURRENT PATH", guidance.current?.let(::livePathLabel) ?: guidance.mode ?: "Waiting", VineColors.Primary),
            Triple("NEXT PATH", guidance.next?.let(::livePathLabel) ?: if (guidance.mode == "Free Drive") "Not planned" else if (guidance.current != null) "Last path" else "Not ready", vine.textPrimary),
            Triple("DISTANCE", distance, vine.textPrimary), Triple("DURATION", duration, vine.textPrimary))
        BoxWithConstraints(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
            val reflow = LocalDensity.current.fontScale > 1.2f
            Column {
                facts.chunked(if (reflow) 2 else 4).forEach { group ->
                    Row(Modifier.fillMaxWidth()) {
                        group.forEachIndexed { index, (caption, value, tint) ->
                            if (index > 0) Box(Modifier.width(1.dp).height(42.dp).background(vine.cardBorder))
                            Column(Modifier.weight(1f).padding(horizontal = 6.dp, vertical = 2.dp)) {
                                Text(caption, fontSize = 10.sp, fontWeight = FontWeight.Bold, color = vine.textSecondary)
                                Text(value, fontSize = if (caption.contains("PATH") && guidance.hasPlan) 28.sp else 18.sp,
                                    fontWeight = FontWeight.Bold, color = tint, fontFamily = FontFamily.SansSerif)
                            }
                        }
                    }
                }
            }
        }
        Row(Modifier.fillMaxWidth().background(vine.appBackground).padding(horizontal = 8.dp, vertical = 5.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            LiveTripStatus("SPEED", speed, vine.textPrimary, Modifier.weight(1f))
            LiveTripStatus("GPS QUALITY", gps, gpsColor, Modifier.weight(1f))
            LiveTripStatus("REMAINING", eta, VineColors.Orange, Modifier.weight(1f))
        }
        if (guidance.hasPlan) Column(Modifier.padding(horizontal = 12.dp, vertical = 4.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(TrackingPattern.fromRaw(trip.trackingPattern).title, Modifier.weight(1f), fontSize = 11.sp, color = vine.textSecondary)
                Text("Position ${guidance.position} of ${guidance.total}", fontSize = 11.sp, color = vine.textSecondary)
            }
            LinearProgressIndicator(progress = { guidance.done.toFloat() / guidance.total },
                modifier = Modifier.fillMaxWidth().padding(top = 4.dp), color = VineColors.Primary, trackColor = vine.cardBorder)
            Text("${guidance.done} done · ${guidance.skipped} skipped", fontSize = 10.sp, color = vine.textSecondary)
        }
    }
}

@Composable
private fun LiveTripStatus(caption: String, value: String, color: Color, modifier: Modifier = Modifier) {
    Column(modifier) {
        Text(caption, fontSize = 9.sp, color = LocalVineColors.current.textSecondary)
        Text(value, fontSize = 12.sp, color = color, fontWeight = FontWeight.SemiBold)
    }
}

internal fun livePathLabel(value: Double): String = com.rork.vinetrack.data.TripRowSequencePlanner.formatPath(value)
