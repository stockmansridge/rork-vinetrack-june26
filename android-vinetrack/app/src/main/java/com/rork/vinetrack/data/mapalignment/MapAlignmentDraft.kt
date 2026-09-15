package com.rork.vinetrack.data.mapalignment

/**
 * The in-memory calibration draft for one wizard session.
 *
 * ## Deliberately not persisted
 *
 * Nothing in this type is written to SQL, Supabase, an RPC, the outbox, the
 * sync layer, SharedPreferences or the local database. It exists for the
 * lifetime of the wizard session only, and closing or discarding the wizard
 * discards the candidate. That is intentional for this phase: we want to
 * field-test the calibration process and the private before/after preview at
 * Stockman's Ridge before deciding how the production persistence and
 * application layer should work.
 *
 * The Android installation id is used to build the draft [MapAlignmentScope] so
 * the scope is realistic, but the resulting alignment must not survive an app
 * restart — and cannot, because this is held in memory by the wizard only.
 *
 * ## Canonical data is never touched
 *
 * The draft accumulates NEW reference points. It never reads-modify-writes a
 * vineyard coordinate, block boundary, row, pin, route or GPS fix. Each
 * reference point pairs a canonical fix (recorded by the existing location
 * pipeline, unchanged) with a display coordinate the operator tapped on the
 * satellite image.
 */
data class MapAlignmentDraft(
    /** The scope being calibrated. Vineyard-level unless a block override was chosen. */
    val scope: MapAlignmentScope,
    val vineyardName: String,
    /** Set only for a block-override calibration. */
    val blockName: String? = null,
    val referencePoints: List<MapAlignmentReferencePoint> = emptyList(),
    /** The candidate derived from [referencePoints], once calculated. */
    val solution: MapAlignmentSolver.Solution? = null,
) {
    val isBlockOverride: Boolean get() = scope.isBlockOverride

    val pointCount: Int get() = referencePoints.size

    /** Whether enough distinct evidence exists to calculate. */
    val readiness: MapAlignmentSolver.Readiness
        get() = MapAlignmentSolver.readiness(referencePoints)

    /** Widest separation across the collected evidence, in metres. Diagnostic only. */
    val widestSpanMetres: Double get() = MapAlignmentSolver.widestSpan(referencePoints)

    /**
     * Whether [coordinate] would land on top of an existing reference.
     *
     * @param excludingId the reference being retaken, so a point can never
     *   collide with its own previous position.
     */
    fun isNearDuplicate(coordinate: CanonicalCoordinate, excludingId: String? = null): Boolean =
        MapAlignmentSolver.isNearDuplicate(coordinate, referencePoints, excludingId)

    /** The candidate alignment, or null before calculation. */
    val candidate: MapAlignment? get() = solution?.alignment

    /**
     * The alignment to use for the private before/after preview.
     *
     * "Before" is always [MapAlignment.none] for this scope — exactly current
     * production rendering — and "after" is the candidate. Until a candidate
     * exists both are identity, so the preview cannot imply a correction that
     * has not been calculated.
     */
    val previewBefore: MapAlignment get() = MapAlignment.none(scope)

    val previewAfter: MapAlignment get() = candidate ?: previewBefore

    /**
     * Add one reference point.
     *
     * The point must belong to [scope]; the draft stamps the scope itself when
     * capturing, so a mismatch indicates a caller bug and is rejected rather
     * than silently dropped. Adding evidence invalidates any existing
     * [solution], because a candidate must never be presented as though it were
     * derived from points it never saw.
     */
    fun withReferencePoint(point: MapAlignmentReferencePoint): MapAlignmentDraft {
        require(point.scope == scope) {
            "Reference point ${point.id} belongs to ${point.scope}, not the draft scope $scope"
        }
        return copy(referencePoints = referencePoints + point, solution = null)
    }

    /** Remove one reference point, invalidating any existing solution. */
    fun withoutReferencePoint(pointId: String): MapAlignmentDraft =
        copy(referencePoints = referencePoints.filterNot { it.id == pointId }, solution = null)

    /**
     * Replace one reference point in place, keeping its position in the list.
     *
     * Used by Retake GPS and Re-mark image point. Like any other change to the
     * evidence this invalidates the candidate: a displayed alignment must never
     * outlive the points it was derived from.
     */
    fun withUpdatedReferencePoint(point: MapAlignmentReferencePoint): MapAlignmentDraft {
        require(point.scope == scope) {
            "Reference point ${point.id} belongs to ${point.scope}, not the draft scope $scope"
        }
        require(referencePoints.any { it.id == point.id }) {
            "Reference point ${point.id} is not part of this draft"
        }
        return copy(
            referencePoints = referencePoints.map { if (it.id == point.id) point else it },
            solution = null,
        )
    }

    /**
     * Replace only the canonical GPS evidence of an existing reference,
     * preserving the operator's marked image point and its metadata.
     */
    fun withRetakenGps(
        pointId: String,
        canonicalCoordinate: CanonicalCoordinate,
        gpsAccuracyMetres: Double?,
        gpsEvidence: MapAlignmentGpsEvidence?,
        capturedAtEpochMillis: Long,
    ): MapAlignmentDraft {
        val existing = referencePoints.firstOrNull { it.id == pointId } ?: return this
        return withUpdatedReferencePoint(
            existing.copy(
                canonicalCoordinate = canonicalCoordinate,
                gpsAccuracyMetres = gpsAccuracyMetres,
                gpsEvidence = gpsEvidence,
                capturedAtEpochMillis = capturedAtEpochMillis,
                alignmentId = null,
            ),
        )
    }

    /**
     * Replace only the marked image point of an existing reference, preserving
     * its canonical GPS evidence entirely.
     */
    fun withRemarkedImagePoint(
        pointId: String,
        selectedMapCoordinate: AndroidDisplayCoordinate,
    ): MapAlignmentDraft {
        val existing = referencePoints.firstOrNull { it.id == pointId } ?: return this
        return withUpdatedReferencePoint(
            existing.copy(
                selectedMapCoordinate = selectedMapCoordinate,
                alignmentId = null,
            ),
        )
    }

    /** Discard every point and any candidate, keeping the chosen scope. */
    fun cleared(): MapAlignmentDraft = copy(referencePoints = emptyList(), solution = null)

    /**
     * Derive the candidate alignment from the current evidence.
     *
     * Returns the draft unchanged when [readiness] is not ready, so a caller
     * cannot accidentally produce a candidate from insufficient or clustered
     * evidence.
     */
    fun solved(alignmentId: String, nowEpochMillis: Long?): MapAlignmentDraft {
        val solved = MapAlignmentSolver.solve(
            points = referencePoints,
            scope = scope,
            alignmentId = alignmentId,
            nowEpochMillis = nowEpochMillis,
        ) ?: return this
        return copy(solution = solved)
    }
}

/** The wizard's linear step sequence. */
enum class MapAlignmentWizardStep {
    /** Choose vineyard, and optionally a block override. */
    Scope,

    /** The explanatory introduction shown before any capture. */
    Introduction,

    /** Sample GPS, mark the imagery with the crosshair, and manage references. */
    Capture,

    /** Review the derived candidate, residuals and the before/after preview. */
    Review,

    /** Final state making the session-only, nothing-changed outcome explicit. */
    Complete,
}
