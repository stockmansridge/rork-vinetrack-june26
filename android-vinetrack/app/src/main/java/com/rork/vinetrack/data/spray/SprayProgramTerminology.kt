package com.rork.vinetrack.data.spray

/**
 * The operator-facing Spray Program vocabulary — the Android mirror of the
 * iOS `SprayProgramTerminology`.
 *
 * The word "template" is banned from operator-facing copy: a reusable step in
 * the vineyard's spray program is a "Program Step", the collection is the
 * "Program", and a planned-but-not-started spray reads as "Upcoming". The
 * labels are pinned here so a test can prove both platforms use the same
 * words rather than five near-misses.
 */
object SprayProgramTerminology {
    const val PROGRAM: String = "Program"
    const val PROGRAM_STEP: String = "Program Step"
    const val ADD_PROGRAM_STEP: String = "Add Program Step"
    const val PLAN_FROM_PROGRAM: String = "Plan from Program"
    const val PLAN_SPRAY: String = "Plan Spray"
    const val ONE_OFF_SPRAY: String = "One-off Spray"
    const val UPCOMING: String = "Upcoming"
    const val DOWNLOAD_IMPORT_CSV: String = "Download Import CSV"

    /** Every pinned label, for the vocabulary test. */
    val allLabels: List<String> = listOf(
        PROGRAM,
        PROGRAM_STEP,
        ADD_PROGRAM_STEP,
        PLAN_FROM_PROGRAM,
        PLAN_SPRAY,
        ONE_OFF_SPRAY,
        UPCOMING,
        DOWNLOAD_IMPORT_CSV,
    )
}
