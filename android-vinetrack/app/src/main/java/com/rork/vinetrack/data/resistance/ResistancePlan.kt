package com.rork.vinetrack.data.resistance

import com.rork.vinetrack.data.chemical.ChemicalIntelligenceAvailability
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.UUID

/**
 * Where a planned position's chemistry identity came from.
 *
 * The distinction matters for honesty, not for arithmetic. A stipulated group is
 * something the operator asserted for planning purposes; a saved chemical is a real
 * product whose group identity carries Chemical Intelligence evidence (or does not).
 */
@Serializable
enum class ResistancePlannedChemistrySource(val raw: String) {
    /** The operator chose FRAC group(s) directly — group-first planning. */
    @SerialName("group")
    GROUP("group"),

    /** The operator chose a product from the vineyard's Chemical Store. */
    @SerialName("saved_chemical")
    SAVED_CHEMICAL("saved_chemical"),
}

/**
 * One product line within a planned position.
 *
 * A position holds a LIST of these rather than a single group signature, because
 * `FRAC 11 + 3` is genuinely two different things: one co-formulated product carrying
 * both codes, or two products tank-mixed. The engine treats those differently
 * (`coformulationSignatures` vs `componentGroups`), and flattening them here would make
 * the Planner unable to express a co-formulation rule at all.
 *
 * Groups are stored as raw codes rather than as a [ResistanceGroupSignature] because
 * the signature type is not serializable; [groups] normalises them on read, so the
 * stored order can never change the evaluation.
 */
@Serializable
data class ResistancePlannedProduct(
    val id: String = UUID.randomUUID().toString(),
    @SerialName("group_codes") val groupCodes: List<String> = emptyList(),
    val source: ResistancePlannedChemistrySource,
    @SerialName("saved_chemical_id") val savedChemicalId: String? = null,
    @SerialName("product_name") val productName: String? = null,
    /** Chemical Intelligence availability. Meaningful only for [SAVED_CHEMICAL]. */
    @SerialName("chemical_availability") val chemicalAvailability: ChemicalIntelligenceAvailability? = null,
    /**
     * Whether structured Chemical Intelligence records a registered use against the
     * disease being planned.
     *
     * Null means UNKNOWN and is the default. Never inferred from group membership: a
     * Group 7 product is not thereby registered for powdery mildew on grapes, and
     * presenting FRAC membership as evidence of efficacy is the exact overstatement
     * this field exists to prevent.
     */
    @SerialName("registered_for_planned_disease") val registeredForPlannedDisease: Boolean? = null,
) {
    val groups: ResistanceGroupSignature get() = ResistanceGroupSignature.of(groupCodes)

    /**
     * The availability the engine should reason from.
     *
     * A STIPULATED GROUP IS TREATED AS DEPENDABLE, and that deserves justification:
     * there is no product identity to verify. The operator has declared "position 4
     * will be a Group 7 spray", and for the purpose of arithmetic on the planned
     * sequence that group is a premise, not an observation that could be wrong.
     * Downgrading it would make every group-first plan report "unable to fully assess",
     * which would defeat the entire point of planning by group — and would wrongly
     * imply the doubt lies in the plan when it actually lies in the history.
     *
     * A chosen PRODUCT is different: its group identity is a claim about a real label,
     * so its recorded availability is carried through unchanged, and an unverified or
     * conflicting product keeps its caveat all the way into the evaluation.
     */
    val effectiveAvailability: ChemicalIntelligenceAvailability
        get() = when (source) {
            ResistancePlannedChemistrySource.GROUP -> ChemicalIntelligenceAvailability.AVAILABLE_VERIFIED
            ResistancePlannedChemistrySource.SAVED_CHEMICAL ->
                chemicalAvailability ?: ChemicalIntelligenceAvailability.UNAVAILABLE
        }

    /** Display label: the product name when one was chosen, otherwise the group. */
    val displayLabel: String
        get() = productName?.takeIf { it.isNotBlank() } ?: groups.displayLabel
}

/**
 * One future spray slot in a plan.
 *
 * A planning position, NOT a spray record. It is never written to `spray_records`,
 * carries no tank or volume, and cannot be mistaken for history because the engine only
 * ever sees it as PLANNED or CANDIDATE.
 */
@Serializable
data class ResistancePlannedPosition(
    /**
     * Stable identity, generated once and preserved across reorders, edits and (later)
     * persistence.
     *
     * This is the seam for plan-vs-actual comparison. When a real spray is eventually
     * associated with a planned position, it will point at this id — which is why the
     * id must survive a reorder that changes the position's number. "Spray 4" is a
     * display ordinal, not an identity.
     */
    val id: String = UUID.randomUUID().toString(),
    val products: List<ResistancePlannedProduct> = emptyList(),
    /**
     * Optional target timing. Display metadata only — see [ResistancePlanner], which
     * derives chronology from plan ORDER so a stale date can never contradict the
     * sequence the operator is looking at.
     */
    @SerialName("target_date_epoch_ms") val targetDateEpochMs: Long? = null,
    @SerialName("growth_stage") val growthStage: String? = null,
    val note: String? = null,
) {
    /** True when no chemistry has been chosen yet. */
    val isEmpty: Boolean get() = products.none { it.groupCodes.isNotEmpty() }

    val componentGroups: Set<String> get() = products.flatMap { it.groups.codes }.toSet()

    /**
     * Operator-facing chemistry label, e.g. `"FRAC 11 + 3"`.
     *
     * Built from the position's own product signatures so a co-formulation and a tank
     * mix of the same two codes read the same way to a human while remaining distinct
     * to the engine.
     */
    val groupsLabel: String
        get() {
            val codes = ResistanceGroupSignature.of(componentGroups).codes
            return if (codes.isEmpty()) "No chemistry selected" else "FRAC " + codes.joinToString(" + ")
        }

    /**
     * The weakest availability among the chosen products, mirroring the engine's
     * weakest-wins rule: one untrustworthy product makes the position's group set
     * uncertain.
     */
    val effectiveAvailability: ChemicalIntelligenceAvailability
        get() = products.minByOrNull { availabilityOrder(it.effectiveAvailability) }
            ?.effectiveAvailability
            ?: ChemicalIntelligenceAvailability.UNAVAILABLE

    /** Products whose FRAC identity may not be relied on without saying so. */
    val productsRequiringCaveat: List<ResistancePlannedProduct>
        get() = products.filter {
            it.source == ResistancePlannedChemistrySource.SAVED_CHEMICAL &&
                it.effectiveAvailability.requiresQualification
        }

    private fun availabilityOrder(availability: ChemicalIntelligenceAvailability): Int =
        when (availability) {
            ChemicalIntelligenceAvailability.UNAVAILABLE -> 0
            ChemicalIntelligenceAvailability.CONFLICT -> 1
            ChemicalIntelligenceAvailability.AVAILABLE_UNVERIFIED -> 2
            ChemicalIntelligenceAvailability.AVAILABLE_PARTIALLY_VERIFIED -> 3
            ChemicalIntelligenceAvailability.AVAILABLE_VERIFIED -> 4
        }
}

/**
 * A season-long resistance plan for one disease across one or more blocks.
 *
 * PERSISTENCE: v1 is local to the device (see `ResistancePlanStore`). The model is
 * serializable and carries a vineyard id, stable position ids and the governing ruleset
 * version specifically so it can move to server storage without a shape change.
 *
 * Mirrors `ResistancePlan.swift` on iOS.
 */
@Serializable
data class ResistancePlan(
    val id: String = UUID.randomUUID().toString(),
    @SerialName("vineyard_id") val vineyardId: String,
    /**
     * Season identity, e.g. `"2026/27"` — never a bare calendar year, because an
     * Australian season spans two of them.
     */
    @SerialName("season_id") val seasonId: String,
    @SerialName("season_start_year") val seasonStartYear: Int,
    val disease: ResistanceDisease,
    val jurisdiction: ResistanceJurisdiction,
    val crop: ResistanceCrop = ResistanceCrop.GRAPE,
    /**
     * Blocks this plan covers. Each is evaluated against its OWN history; they are
     * never merged.
     */
    @SerialName("block_ids") val blockIds: List<String> = emptyList(),
    /** Planned positions in sequence. List order IS the planned chronology. */
    val positions: List<ResistancePlannedPosition> = emptyList(),
    val notes: String? = null,
    /**
     * The ruleset that governed the evaluation when this plan was last saved.
     *
     * Stored as id + version rather than as rendered warning text. When the 2027
     * CropLife strategy arrives, a plan built under the 2026 one must not silently
     * re-interpret itself: comparing this against the registry's current version is
     * what allows "a newer resistance strategy is available — review this plan" instead
     * of a plan whose meaning changed while nobody was looking.
     */
    @SerialName("ruleset_id") val rulesetId: String? = null,
    @SerialName("ruleset_version") val rulesetVersion: String? = null,
    /**
     * Author, for attribution. NOT a visibility scope: plans are vineyard data and
     * every authorised member sees them (see `resistance_plans` RLS). Scoping
     * visibility to the creator would mean the manager who wrote the season plan is
     * the only person who can open it, which defeats the purpose of a shared plan.
     */
    @SerialName("created_by") val createdBy: String? = null,
    @SerialName("created_at_epoch_ms") val createdAtEpochMs: Long,
    @SerialName("updated_at_epoch_ms") val updatedAtEpochMs: Long,
    /**
     * Soft-delete tombstone. A deleted plan is retained so the delete propagates to
     * other devices instead of the row silently reappearing on their next push.
     */
    @SerialName("deleted_at_epoch_ms") val deletedAtEpochMs: Long? = null,
    /**
     * The `server_revision` (sql/198) this local copy was based on. SERVER STATE, not
     * editable plan content — no editor, screen or mutator may set it.
     *
     * NULL means "the server has never issued a revision for this plan": either it was
     * created offline and has not landed yet, or it is a cached copy from before revisions
     * existed. Null is a legitimate state and is never treated as corruption — and a fake
     * revision is NEVER manufactured to fill it, because a made-up number would be sent as
     * `base_revision` and would either be refused forever or, worse, match by luck and
     * overwrite an edit this device never saw.
     *
     * Default `null` also keeps every plan cached by an older build decodable.
     */
    @SerialName("server_revision") val serverRevision: Long? = null,
) {

    /** True when this plan has been archived/soft-deleted. */
    val isDeleted: Boolean get() = deletedAtEpochMs != null

    /**
     * True when this plan has never been accepted by the server, so a versioned write
     * must be a CREATE rather than an update of a known revision.
     */
    val isUnsynced: Boolean get() = serverRevision == null

    /**
     * Records the revision the server issued for this document.
     *
     * Separate from every content mutator on purpose: the revision is not an edit, so
     * stamping it must never touch [updatedAtEpochMs] and must never enqueue the plan.
     */
    fun stampingServerRevision(revision: Long?): ResistancePlan = copy(serverRevision = revision)

    // -----------------------------------------------------------------------
    // Editing
    //
    // Every mutator returns a new plan rather than mutating in place, so a caller
    // cannot hold a stale copy and re-evaluation is always driven by a value the UI
    // actually rendered.
    // -----------------------------------------------------------------------

    fun addingPosition(
        position: ResistancePlannedPosition = ResistancePlannedPosition(),
        nowMs: Long,
    ): ResistancePlan = copy(positions = positions + position, updatedAtEpochMs = nowMs)

    fun removingPosition(positionId: String, nowMs: Long): ResistancePlan =
        copy(positions = positions.filterNot { it.id == positionId }, updatedAtEpochMs = nowMs)

    fun replacingPosition(position: ResistancePlannedPosition, nowMs: Long): ResistancePlan {
        if (positions.none { it.id == position.id }) return this
        return copy(
            positions = positions.map { if (it.id == position.id) position else it },
            updatedAtEpochMs = nowMs,
        )
    }

    /** Moves a position one slot earlier. No-op at the start. */
    fun movingPositionUp(positionId: String, nowMs: Long): ResistancePlan {
        val index = positions.indexOfFirst { it.id == positionId }
        if (index <= 0) return this
        val reordered = positions.toMutableList()
        val moved = reordered.removeAt(index)
        reordered.add(index - 1, moved)
        return copy(positions = reordered, updatedAtEpochMs = nowMs)
    }

    /** Moves a position one slot later. No-op at the end. */
    fun movingPositionDown(positionId: String, nowMs: Long): ResistancePlan {
        val index = positions.indexOfFirst { it.id == positionId }
        if (index < 0 || index >= positions.size - 1) return this
        val reordered = positions.toMutableList()
        val moved = reordered.removeAt(index)
        reordered.add(index + 1, moved)
        return copy(positions = reordered, updatedAtEpochMs = nowMs)
    }

    fun settingBlockIds(ids: List<String>, nowMs: Long): ResistancePlan =
        copy(blockIds = ids.distinct(), updatedAtEpochMs = nowMs)

    fun settingNotes(value: String?, nowMs: Long): ResistancePlan =
        copy(notes = value, updatedAtEpochMs = nowMs)

    /**
     * Records the ruleset actually used, so the plan can later detect that the strategy
     * has moved on.
     */
    fun stampingRuleset(rulesetId: String?, rulesetVersion: String?): ResistancePlan =
        copy(rulesetId = rulesetId, rulesetVersion = rulesetVersion)

    /**
     * True when a newer strategy version is in force than the one this plan recorded.
     *
     * Deliberately a query rather than an automatic migration: an old plan keeps its
     * stamped version until a human reviews it.
     */
    fun isStrategyOutdated(registry: ResistanceRulesetRegistry): Boolean {
        val stamped = rulesetVersion ?: return false
        val current = registry.current(jurisdiction, crop, disease) ?: return false
        return current.rulesetVersion != stamped
    }

    fun position(positionId: String): ResistancePlannedPosition? =
        positions.firstOrNull { it.id == positionId }
}

/** Operator-facing label for a signature, e.g. `"FRAC 11 + 3"`. */
val ResistanceGroupSignature.displayLabel: String
    get() = if (codes.isEmpty()) "No group recorded" else "FRAC " + codes.joinToString(" + ")
