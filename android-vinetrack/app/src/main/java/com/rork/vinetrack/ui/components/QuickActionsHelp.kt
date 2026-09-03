package com.rork.vinetrack.ui.components

import com.rork.vinetrack.R

/**
 * Copy for the Quick Actions help sheet opened from the dashboard heading.
 * Mirrors the iOS `QuickActionsHelp` enum in `HelpSheetView.swift` — keep both
 * in step when pages are added or reworded.
 */
object QuickActionsHelp {
    const val TITLE: String = "How to Use"

    val pages: List<HelpPage> = listOf(
        HelpPage(
            id = "vineyard",
            title = "Built to work where you work",
            message = "Quick Actions are designed for use while you are moving through the vineyard.\n\n" +
                "When you see something that needs attention, use the Repairs or Growth buttons to " +
                "mark it immediately — without stopping to work out the block, row or exact position yourself.",
            imageRes = R.drawable.quick_actions_help,
        ),
        HelpPage(
            id = "drop",
            title = "See it. Mark it. Keep moving.",
            message = "Choose the Quick Action that best describes what you have found.\n\n" +
                "Repairs and Growth actions can be customised for the jobs and observations that " +
                "matter in your vineyard.\n\n" +
                "Tap the relevant button and VineTrack records the issue at your current position.",
            supporting = "Add a photo or notes when you need more detail.",
        ),
        HelpPage(
            id = "placement",
            title = "Find it again easily",
            message = "VineTrack uses your location, the vineyard map and your direction of travel to " +
                "work out where the pin belongs.\n\n" +
                "It records the block, row, side and direction so the issue can be found again with " +
                "much more precision than a normal map marker.",
            supporting = "Later, open the pin to see the exact details and navigate back to it.",
        ),
    )
}
