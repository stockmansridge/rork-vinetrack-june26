package com.rork.vinetrack.data.chemical

/**
 * Drops activity-group "conflicts" that are two names for the same chemistry.
 *
 * # The false alarm this removes
 *
 * A stored record — or a server that has not yet been redeployed with the v2
 * table — can report an activity-group disagreement like:
 *
 * ```text
 * Extracted:                 HRAC 14
 * Reference classification:  HRAC E
 * ```
 *
 * Those are the SAME classification. Australia replaced the alphabetical
 * herbicide mode-of-action codes with the globally aligned numeric ones; "E"
 * was flumioxazin's legacy code for exactly the PPO chemistry that a current
 * label calls "14". Reporting them as sources that disagree marks a correctly
 * identified product as needing review, and it does so on the resistance
 * screen — the one place in the app where a false alarm costs most trust.
 *
 * # Why the fix lives on the client
 *
 * The server's own table is already v2 and agrees. But records written before
 * that, and any deployment lag, leave the stale pairing sitting in
 * `verification_conflicts` on rows already in the database. Re-deriving the
 * comparison here means a record stops crying conflict as soon as the app
 * knows better, without a migration rewriting stored evidence.
 *
 * # What is NOT dropped
 *
 * Equivalence is decided per ACTIVE, never per letter, through
 * [AuthoritativeActivityGroups.groupsAreEquivalent] — the same function the
 * server and iOS use. A source calling flumioxazin "Group 2" is a genuine
 * disagreement and survives untouched, because that is the case the check
 * exists for. Nothing is deleted from storage either: the original conflict
 * stays on the record as evidence and remains visible in Advanced/verification
 * details. Only the customer-facing verdict changes.
 */
object ChemicalConflictReconciliation {

    /** The conflict field this reconciliation applies to. */
    const val ACTIVITY_GROUP_FIELD: String = "activity_group"

    /**
     * Read a group out of a conflict's recorded value.
     *
     * Handles the shapes these strings actually arrive in — `"HRAC 14"`,
     * `"hrac E"`, `"Group 14"`, `"14"` — because the value is a human-readable
     * rendering rather than a structured field. Returns null when no scheme can
     * be established, since guessing one could equate two unrelated systems.
     */
    fun parseGroup(raw: String?, fallbackScheme: ChemicalActivityGroupScheme?): ChemicalActivityGroup? {
        val text = raw?.trim().orEmpty()
        if (text.isEmpty()) return null
        val lower = text.lowercase()
        val scheme = ChemicalActivityGroupScheme.entries.firstOrNull {
            lower.startsWith(it.raw) || lower.startsWith(it.label.lowercase())
        } ?: fallbackScheme ?: return null
        // Strip the scheme word, leaving the code for the shared normaliser.
        val code = text
            .replace(Regex("(?i)^(frac|hrac|irac)\\b"), "")
            .replace(Regex("(?i)\\bgroup\\b"), "")
            .trim()
            .ifEmpty { return null }
        val group = ChemicalActivityGroup.of(scheme, code)
        return group.takeIf { it.code.isNotEmpty() }
    }

    /**
     * Whether this conflict is two spellings of one classification.
     *
     * Requires an active name: equivalence is a fact about an ACTIVE, and the
     * legacy alphabets reuse the same characters for unrelated chemistries, so
     * a conflict that names no active can never be shown to be spurious and is
     * always kept.
     */
    fun isSpurious(conflict: ChemicalVerificationConflict): Boolean {
        if (conflict.field.trim() != ACTIVITY_GROUP_FIELD) return false
        val active = conflict.activeIngredientName?.trim().orEmpty()
        if (active.isEmpty()) return false
        val extracted = parseGroup(conflict.extractedValue, null)
        val authoritative = parseGroup(
            conflict.authoritativeValue,
            fallbackScheme = extracted?.scheme,
        )
        val resolvedExtracted = extracted
            ?: parseGroup(conflict.extractedValue, authoritative?.scheme)
            ?: return false
        if (authoritative == null) return false
        return AuthoritativeActivityGroups.groupsAreEquivalent(
            activeName = active,
            a = resolvedExtracted,
            b = authoritative,
        )
    }

    /**
     * The conflicts a CUSTOMER should be shown, and that may set the record's
     * status to "Review required".
     *
     * Everything filtered out remains on the record; it is simply not a
     * disagreement worth stopping an operator over.
     */
    fun customerVisible(
        conflicts: List<ChemicalVerificationConflict>,
    ): List<ChemicalVerificationConflict> = conflicts.filterNot { isSpurious(it) }

    /** True when every recorded conflict is a legacy-code artefact. */
    fun allSpurious(conflicts: List<ChemicalVerificationConflict>): Boolean =
        conflicts.isNotEmpty() && customerVisible(conflicts).isEmpty()
}
