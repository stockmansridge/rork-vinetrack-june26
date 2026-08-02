package com.rork.vinetrack.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.android.gms.maps.model.LatLng
import com.google.maps.android.compose.GoogleMapComposable
import com.google.maps.android.compose.MarkerComposable
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.Polygon
import com.google.maps.android.compose.Polyline
import com.google.maps.android.compose.rememberMarkerState
import com.rork.vinetrack.data.BlockRowLayout
import com.rork.vinetrack.data.model.CoordinatePoint

/** Shared palette so the editor and the read-only preview never drift apart. */
object BlockGeometryColors {
    val Boundary: Color = Color(0xFF0A84FF)
    val BoundaryFill: Color = Color(0x260A84FF)
    val OtherBlock: Color = Color(0xFFFF9500)

    /** Bright core of a row line — reads on dark canopy and pale soil alike. */
    val RowCore: Color = Color(0xFFFFFFFF)

    /** Dark casing drawn under the core so rows survive bright imagery. */
    val RowCasing: Color = Color(0xB3101314)

    /** The outermost rows, which carry the first / last labels. */
    val RowEdge: Color = Color(0xFF34C759)
}

private const val ROW_CASING_Z = 3f
private const val ROW_CORE_Z = 4f
private const val BOUNDARY_Z = 2f

/** The block outline: clean stroke, subtle fill, never a pin in sight. */
@Composable
@GoogleMapComposable
fun BlockBoundaryOverlay(
    points: List<LatLng>,
    strokeColor: Color = BlockGeometryColors.Boundary,
    fillColor: Color = BlockGeometryColors.BoundaryFill,
    strokeWidth: Float = 3f,
) {
    when {
        points.size >= 3 -> Polygon(
            points = points,
            fillColor = fillColor,
            strokeColor = strokeColor,
            strokeWidth = strokeWidth,
            zIndex = BOUNDARY_Z,
        )
        // Two points draw a line only — never a self-closing polygon.
        points.size == 2 -> Polyline(
            points = points,
            color = strokeColor,
            width = strokeWidth,
            zIndex = BOUNDARY_Z,
        )
    }
}

/**
 * Generated row centre-lines, drawn ABOVE the imagery and the boundary fill
 * with a two-stroke treatment (dark casing + bright core) so they stay legible
 * over both sunlit soil and dark canopy without being thick enough to hide the
 * vineyard.
 */
@Composable
@GoogleMapComposable
fun BlockRowLinesOverlay(layout: BlockRowLayout) {
    layout.rows.forEach { row ->
        val points = listOf(row.line.start.toMapLatLng(), row.line.end.toMapLatLng())
        val isEdge = row.index == layout.rows.first().index || row.index == layout.rows.last().index
        Polyline(
            points = points,
            color = BlockGeometryColors.RowCasing,
            width = if (isEdge) 8f else 5f,
            zIndex = ROW_CASING_Z,
        )
        Polyline(
            points = points,
            color = if (isEdge) BlockGeometryColors.RowEdge else BlockGeometryColors.RowCore,
            width = if (isEdge) 4f else 2f,
            zIndex = ROW_CORE_Z,
        )
    }
}

/**
 * First and last row labels only — a label on every row is unreadable at block
 * zoom. Both sit at the same headland because every row is clipped in the same
 * direction, so they read as the two ends of the numbering range.
 */
@Composable
@GoogleMapComposable
fun BlockRowLabelsOverlay(layout: BlockRowLayout) {
    val first = layout.firstRow ?: return
    val last = layout.lastRow
    RowNumberMarker(first.labelAnchor, first.number)
    if (last != null && last.index != first.index) {
        RowNumberMarker(last.labelAnchor, last.number)
    }
}

@Composable
@GoogleMapComposable
private fun RowNumberMarker(point: CoordinatePoint, number: Int) {
    val position = point.toMapLatLng()
    val state: MarkerState = rememberMarkerState(position = position)
    state.position = position
    MarkerComposable(
        number,
        position,
        state = state,
        anchor = Offset(0.5f, 0.5f),
        zIndex = 5f,
        title = "Row $number",
        // Informational only — a tap must never start an edit.
        onClick = { true },
    ) {
        RowNumberChip(number)
    }
}

@Composable
private fun RowNumberChip(number: Int) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .background(Color(0xE60A84FF))
            .border(1.dp, Color.White.copy(alpha = 0.9f), RoundedCornerShape(8.dp))
            .padding(horizontal = 7.dp, vertical = 3.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text("Row $number", color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Bold)
    }
}

/** Context polygons for the other blocks already mapped in this vineyard. */
@Composable
@GoogleMapComposable
fun OtherBlockOutlines(polygons: List<List<LatLng>>) {
    polygons.forEach { points ->
        if (points.size > 2) {
            Polygon(
                points = points,
                fillColor = BlockGeometryColors.OtherBlock.copy(alpha = 0.10f),
                strokeColor = BlockGeometryColors.OtherBlock.copy(alpha = 0.7f),
                strokeWidth = 2f,
                zIndex = 1f,
            )
        }
    }
}

fun CoordinatePoint.toMapLatLng(): LatLng = LatLng(latitude, longitude)
