package com.rork.vinetrack.data

/**
 * Pure layout rules for the full-screen block boundary + row editor.
 *
 * Kept out of Compose so the panel anchoring and sheet sizing contract is
 * unit-testable on the JVM (`BlockEditorLayoutTest`) rather than only
 * verifiable by eye on a device.
 */
object BlockEditorLayout {

    /**
     * Gap between the bottom control bar and the bottom of the usable map area.
     *
     * The editor is hosted inside the app Scaffold, which already consumes the
     * VineTrack navigation bar AND the Android system navigation / gesture
     * inset. Re-applying `WindowInsets.navigationBars` here is what floated the
     * boundary panel a full nav-bar height above the navigation — so the anchor
     * is a small visual gap only.
     */
    const val BOTTOM_ANCHOR_GAP_DP: Int = 8

    /** Compact boundary bar: one summary line + one action row. */
    const val BOUNDARY_BAR_HEIGHT_DP: Int = 88

    /** Row sheet at rest: grab handle + one summary line + two actions. */
    const val ROW_SHEET_COLLAPSED_HEIGHT_DP: Int = 104

    /** The expanded row sheet may never take more than half the usable map. */
    const val ROW_SHEET_MAX_FRACTION: Double = 0.5

    /** Below this the expanded sheet is unusable even on a small phone. */
    const val ROW_SHEET_MIN_EXPANDED_DP: Int = 240

    /** Beyond this a tablet sheet is just empty space. */
    const val ROW_SHEET_MAX_EXPANDED_DP: Int = 420

    /** Drag past this fraction of the travel to flip the sheet's state. */
    const val ROW_SHEET_SNAP_FRACTION: Double = 0.35

    /**
     * Height of the expanded row sheet for a map area [usableHeightDp] tall.
     *
     * Never more than [ROW_SHEET_MAX_FRACTION] of the map, so the grower can
     * always see the rows react to the control they are dragging. On a very
     * short screen the minimum wins, but the result is still clamped so it can
     * never exceed the map itself.
     */
    fun expandedSheetHeightDp(usableHeightDp: Int): Int {
        if (usableHeightDp <= 0) return 0
        val half = (usableHeightDp * ROW_SHEET_MAX_FRACTION).toInt()
        val preferred = half.coerceIn(ROW_SHEET_MIN_EXPANDED_DP, ROW_SHEET_MAX_EXPANDED_DP)
        return preferred.coerceAtMost(usableHeightDp)
    }

    /** Map height still visible behind an expanded sheet. */
    fun visibleMapHeightDp(usableHeightDp: Int, sheetHeightDp: Int): Int =
        (usableHeightDp - sheetHeightDp).coerceAtLeast(0)

    /**
     * Bottom obstruction the "Fit" control must clear, in dp: the panel itself
     * plus its anchor gap. Passed to `fitToContent(bottomInsetPx = …)` so the
     * framed geometry ends up in the part of the map the panel is not covering.
     */
    fun fitBottomInsetDp(panelHeightDp: Int): Int =
        panelHeightDp.coerceAtLeast(0) + BOTTOM_ANCHOR_GAP_DP

    /**
     * Top obstruction the "Fit" control must clear: the status bar, the mode
     * selector row and any tip/warning banner currently drawn over the map.
     */
    fun fitTopInsetDp(topChromeHeightDp: Int): Int = topChromeHeightDp.coerceAtLeast(0)
}
