package com.rork.vinetrack.data

/**
 * Everything the Pruning Activity Report must survive while the user is off
 * inspecting a linked Work Task: the growing season, the sort, the search and
 * which record sheet was open.
 *
 * Deep-linking into a Work Task only ever changes [openWorkTaskId] — every
 * other field is carried through untouched, which is what guarantees the user
 * comes back to the report exactly as they left it. Ad-hoc filters live in the
 * screen's own [com.rork.vinetrack.data.model.PruningActivityFilter] state and
 * are retained the same way, by keeping the report composed behind the task.
 */
data class PruningReportNavigation(
    val seasonYear: Int,
    val sortColumnKey: String? = null,
    val sortAscending: Boolean = false,
    val search: String = "",
    val selectedRowId: String? = null,
    val openWorkTaskId: String? = null,
) {
    val isShowingWorkTask: Boolean get() = openWorkTaskId != null

    /**
     * Deep link into a linked Work Task. The record sheet is dismissed (the
     * task takes over the screen) but the season, sort and search are kept so
     * returning restores the same view.
     */
    fun openingWorkTask(taskId: String?): PruningReportNavigation {
        val id = taskId?.takeIf { it.isNotBlank() } ?: return this
        return copy(selectedRowId = null, openWorkTaskId = id)
    }

    /** Return from the Work Task to the untouched report. */
    fun closingWorkTask(): PruningReportNavigation = copy(openWorkTaskId = null)

    fun openingRow(rowId: String): PruningReportNavigation = copy(selectedRowId = rowId)

    fun closingRow(): PruningReportNavigation = copy(selectedRowId = null)

    fun withSeason(year: Int): PruningReportNavigation = copy(seasonYear = year)

    fun withSearch(text: String): PruningReportNavigation = copy(search = text)

    fun withSort(columnKey: String?, ascending: Boolean): PruningReportNavigation =
        copy(sortColumnKey = columnKey, sortAscending = ascending)
}
