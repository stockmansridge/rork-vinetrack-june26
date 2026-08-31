package com.rork.vinetrack.data.chemical

/**
 * What the Spray Calculator's "Add New Chemical to List" flow does next.
 *
 * # Why these decisions live outside the Composable
 *
 * They are the decisions that can lose an operator's work or put an
 * unconfirmed product in a tank, and inside a `@Composable` none of them can
 * be asserted on: this module has no Compose test harness, so a rule written
 * there is a rule nothing checks. They are ordinary functions here, the screen
 * calls them, and the tests exercise the SAME code the screen runs rather than
 * a description of it.
 *
 * # The pending-append snapshot
 *
 * The flow records which chemical ids existed when it opened, so the product
 * it creates can be recognised by difference. That snapshot is a loaded gun:
 * left armed after a run that created nothing, the next chemical created by
 * any unrelated action — a bulk import, a second device syncing, the operator
 * adding a product from the Chemical Store — matches the difference and is
 * appended to a spray it was never meant to be in. So every terminal path that
 * produced no product disarms it.
 */
object ChemicalAddFromSprayRouting {

    /**
     * The effects of one step. All independent, because several apply at once:
     * "check for updates" closes the register flow, disarms the snapshot and
     * opens re-verification in a single move.
     */
    data class Outcome(
        val closeRegisterFlow: Boolean = false,
        val openManualEntry: Boolean = false,
        val openReverify: Boolean = false,
        /** Forget the pending append — this path creates no product. */
        val disarmSnapshot: Boolean = false,
        /** Add a line to the open spray. */
        val appendLine: Boolean = false,
    )

    /**
     * "Yes, check for updates" on the pre-research duplicate question.
     *
     * Opens the canonical re-verification and appends NOTHING.
     *
     * This used to append the stored record instead of checking it, which
     * answered a question the operator had not asked: they wanted to know
     * whether their saved information was still current, and got a spray line
     * while the stored information stayed exactly as stale as it was. The
     * re-check can also end in a database update, and coupling that decision
     * to a spray-line mutation makes "I only wanted to look" silently change
     * the tank. The operator adds the product afterwards with "Add Chemical".
     */
    fun onCheckForUpdates(): Outcome = Outcome(
        closeRegisterFlow = true,
        openReverify = true,
        disarmSnapshot = true,
        appendLine = false,
    )

    /**
     * The register flow closed.
     *
     * A successful save and a cancel both arrive here, so [created] is the only
     * thing that separates them. "No, keep it as it is" is a cancel: it runs no
     * lookup, writes nothing and appends nothing.
     */
    fun onRegisterFlowClosed(created: Boolean): Outcome = Outcome(
        closeRegisterFlow = true,
        disarmSnapshot = !created,
    )

    /**
     * "Enter manually" — the ONE transfer that keeps the snapshot armed,
     * because it is still on its way to creating the product the operator
     * asked for.
     */
    fun onEnterManually(): Outcome = Outcome(
        closeRegisterFlow = true,
        openManualEntry = true,
        disarmSnapshot = false,
    )

    /** The manual form closed. Same rule as the register flow. */
    fun onManualEntryClosed(created: Boolean): Outcome = Outcome(
        disarmSnapshot = !created,
    )

    /**
     * Re-verification closed, by either button.
     *
     * Nothing is appended on this route at all: neither "Keep what I have" nor
     * "Use updated information" is a request to change the spray.
     */
    fun onReverifyClosed(): Outcome = Outcome(disarmSnapshot = true, appendLine = false)

    /**
     * The id of the product the flow created, or null when there is nothing to
     * append.
     *
     * Identified by DIFFERENCE against the snapshot because the create callback
     * reports only success, not the row it made. Deliberately not by name — two
     * registrations routinely share one, and the wrong product would be added —
     * and deliberately not "the first/newest chemical in the store", which
     * appends something the operator never chose.
     *
     * A null snapshot means no run is armed, so nothing is appended however
     * many chemicals appear.
     */
    fun createdId(idsBeforeAdd: Set<String>?, currentIds: List<String>): String? {
        if (idsBeforeAdd == null) return null
        return currentIds.firstOrNull { it !in idsBeforeAdd }
    }
}
