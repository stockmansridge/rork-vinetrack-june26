package com.rork.vinetrack.ui.screens

/** Formats a Vintage identifier without locale grouping separators. */
object VintageYearText {
    fun format(year: Int): String = year.toString()

    fun label(year: Int): String = "Vintage ${format(year)}"
}
