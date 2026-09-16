package com.rork.vinetrack.data.mapalignment

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * The versioned on-device representation of Map Alignment state, and the codec
 * that reads and writes it.
 *
 * ## Local only — read this before adding anything
 *
 * Everything here is written to THIS Android installation and nowhere else. It
 * is deliberately not a SQL table, Supabase table, RPC, API endpoint, sync
 * entity, outbox payload, Portal record or iOS file. It must work with no
 * network at all, and it may legitimately be lost on uninstall — a field-test
 * calibration is reproducible by walking the vineyard again, so durability
 * beyond the installation is not worth a backend.
 *
 * Nothing stored here is applied to a normal VineTrack map in this phase.
 *
 * ## Why an explicit [STORAGE_VERSION], and not a serialized object graph
 *
 * Persisting a language-level object graph couples the file format to class
 * names, field order and nullability, so a later refactor silently produces a
 * file the app can no longer read — and typically discovers that by throwing
 * during startup, on the device, in a vineyard. This uses a flat, named,
 * explicitly versioned document instead.
 *
 * The version is checked BEFORE the payload is interpreted. A document from a
 * future or unknown version is never coerced, never partially adopted and never
 * becomes active; it is reported as unusable so the operator can remove it. See
 * [Decoded].
 *
 * ## The two stored concepts are kept separate
 *
 * * [StoredDraft] — an UNFINISHED calibration the operator can resume.
 * * [StoredCalibration] — a COMPLETED calibration that was reviewed and
 *   deliberately saved.
 *
 * They are distinct records under distinct keys because they answer distinct
 * questions. Collapsing them into one "calibration with a status flag" would
 * make it possible for an abandoned half-finished draft to be mistaken for a
 * reviewed result, which is exactly the confusion this separation prevents.
 *
 * ## Derived values are not stored
 *
 * The solved candidate is NOT persisted as offsets. Only the id it was given is
 * kept, and the candidate is re-derived from the stored reference points on
 * load. Storing derived numbers alongside the evidence invites a file whose
 * alignment disagrees with the points it claims to come from — after a restore
 * the operator would be shown a candidate no longer supported by the evidence
 * on screen. Re-deriving is cheap and cannot drift.
 */
object MapAlignmentStorage {

    /**
     * The local storage format version.
     *
     * Increment ONLY with a matching read path. An unknown version is refused,
     * never guessed at.
     */
    const val STORAGE_VERSION: Int = 1

    /** Result of reading a stored document. Never throws at the call site. */
    sealed interface Decoded<out T> {
        /** A readable document of a supported version. */
        data class Restored<T>(val value: T) : Decoded<T>

        /** Nothing stored. The normal first-run state. */
        data object Empty : Decoded<Nothing>

        /**
         * Present but unreadable: a future/unknown version, malformed JSON, or
         * a payload that fails its own invariants.
         *
         * This is deliberately its own outcome rather than being folded into
         * [Empty]. The bytes still exist on the device, so the operator must be
         * offered a way to remove them; silently reporting "no draft" would
         * leave an unremovable file behind and make the state look clean when
         * it is not.
         */
        data class Unusable(val reason: String) : Decoded<Nothing>
    }

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    }

    // --- Draft ------------------------------------------------------------

    fun encodeDraft(draft: MapAlignmentStoredDraft): String =
        json.encodeToString(DraftDocument.serializer(), DraftDocument.from(draft))

    /**
     * Read a stored draft.
     *
     * @param installationId the CURRENT installation. A draft belonging to a
     *   different installation is refused rather than adopted: the scope is the
     *   identity of the calibration, and silently re-homing evidence recorded
     *   on another installation would produce an alignment nobody measured.
     */
    fun decodeDraft(raw: String?, installationId: String): Decoded<MapAlignmentStoredDraft> {
        val document = decodeDocument(raw, DraftDocument.serializer())
            ?: return if (raw.isNullOrBlank()) Decoded.Empty else malformed()
        if (document.storageVersion != STORAGE_VERSION) {
            return Decoded.Unusable(
                "Saved with an unsupported storage version (${document.storageVersion}).",
            )
        }
        val restored = runCatching { document.toDomain() }.getOrNull()
            ?: return malformed()
        if (restored.draft.scope.androidInstallationId != installationId) {
            return Decoded.Unusable("Saved by a different Android installation.")
        }
        return Decoded.Restored(restored)
    }

    // --- Completed calibrations -------------------------------------------

    fun encodeCalibrations(saved: List<MapAlignmentSavedCalibration>): String =
        json.encodeToString(
            CalibrationListDocument.serializer(),
            CalibrationListDocument(
                storageVersion = STORAGE_VERSION,
                calibrations = saved.map(CalibrationDocument::from),
            ),
        )

    fun decodeCalibrations(
        raw: String?,
        installationId: String,
    ): Decoded<List<MapAlignmentSavedCalibration>> {
        val document = decodeDocument(raw, CalibrationListDocument.serializer())
            ?: return if (raw.isNullOrBlank()) Decoded.Empty else malformed()
        if (document.storageVersion != STORAGE_VERSION) {
            return Decoded.Unusable(
                "Saved with an unsupported storage version (${document.storageVersion}).",
            )
        }
        // One unreadable entry must not cost the operator the others: each is
        // decoded independently and a failure drops only itself.
        val restored = document.calibrations.mapNotNull { entry ->
            runCatching { entry.toDomain() }.getOrNull()
        }.filter { it.calibration.alignment.androidInstallationId == installationId }
        return Decoded.Restored(restored)
    }

    private fun <T> decodeDocument(
        raw: String?,
        serializer: kotlinx.serialization.KSerializer<T>,
    ): T? {
        if (raw.isNullOrBlank()) return null
        return runCatching { json.decodeFromString(serializer, raw) }.getOrNull()
    }

    private fun <T> malformed(): Decoded<T> =
        Decoded.Unusable("The saved calibration data could not be read.")

    // --- Documents --------------------------------------------------------

    @Serializable
    private data class DraftDocument(
        @SerialName("storage_version") val storageVersion: Int,
        val scope: ScopeDocument,
        @SerialName("vineyard_name") val vineyardName: String,
        @SerialName("block_name") val blockName: String? = null,
        val points: List<PointDocument> = emptyList(),
        val step: String,
        val pending: PendingDocument? = null,
        @SerialName("solved_alignment_id") val solvedAlignmentId: String? = null,
        @SerialName("updated_at") val updatedAtEpochMillis: Long,
    ) {
        fun toDomain(): MapAlignmentStoredDraft {
            val scope = scope.toDomain()
            return MapAlignmentStoredDraft(
                draft = MapAlignmentDraft(
                    scope = scope,
                    vineyardName = vineyardName,
                    blockName = blockName,
                    referencePoints = points.map { it.toDomain(scope) },
                ),
                step = step.toStep(),
                pending = pending?.toDomain(),
                solvedAlignmentId = solvedAlignmentId,
                updatedAtEpochMillis = updatedAtEpochMillis,
            )
        }

        companion object {
            fun from(stored: MapAlignmentStoredDraft): DraftDocument = DraftDocument(
                storageVersion = STORAGE_VERSION,
                scope = ScopeDocument.from(stored.draft.scope),
                vineyardName = stored.draft.vineyardName,
                blockName = stored.draft.blockName,
                points = stored.draft.referencePoints.map(PointDocument::from),
                step = stored.step.name,
                pending = stored.pending?.let(PendingDocument::from),
                solvedAlignmentId = stored.solvedAlignmentId,
                updatedAtEpochMillis = stored.updatedAtEpochMillis,
            )
        }
    }

    @Serializable
    private data class CalibrationListDocument(
        @SerialName("storage_version") val storageVersion: Int,
        val calibrations: List<CalibrationDocument> = emptyList(),
    )

    @Serializable
    private data class CalibrationDocument(
        val id: String,
        val scope: ScopeDocument,
        @SerialName("vineyard_name") val vineyardName: String,
        @SerialName("block_name") val blockName: String? = null,
        @SerialName("east_metres") val eastOffsetMetres: Double,
        @SerialName("north_metres") val northOffsetMetres: Double,
        val points: List<PointDocument> = emptyList(),
        @SerialName("saved_at") val savedAtEpochMillis: Long,
    ) {
        fun toDomain(): MapAlignmentSavedCalibration {
            val scope = scope.toDomain()
            val alignment = MapAlignment(
                id = id,
                scope = scope,
                eastOffsetMetres = eastOffsetMetres,
                northOffsetMetres = northOffsetMetres,
                // Enabled describes the candidate itself, NOT production use.
                // No production map consults a stored field-test calibration in
                // this phase; see MapAlignmentResolver.
                isEnabled = true,
                createdAtEpochMillis = savedAtEpochMillis,
                updatedAtEpochMillis = savedAtEpochMillis,
            )
            return MapAlignmentSavedCalibration(
                calibration = MapAlignmentCalibration(
                    alignment = alignment,
                    referencePoints = points.map { it.toDomain(scope) },
                ),
                vineyardName = vineyardName,
                blockName = blockName,
                savedAtEpochMillis = savedAtEpochMillis,
            )
        }

        companion object {
            fun from(stored: MapAlignmentSavedCalibration): CalibrationDocument {
                val alignment = stored.calibration.alignment
                return CalibrationDocument(
                    id = alignment.id,
                    scope = ScopeDocument.from(alignment.scope),
                    vineyardName = stored.vineyardName,
                    blockName = stored.blockName,
                    eastOffsetMetres = alignment.eastOffsetMetres,
                    northOffsetMetres = alignment.northOffsetMetres,
                    points = stored.calibration.referencePoints.map(PointDocument::from),
                    savedAtEpochMillis = stored.savedAtEpochMillis,
                )
            }
        }
    }

    @Serializable
    private data class ScopeDocument(
        @SerialName("installation_id") val androidInstallationId: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("block_id") val blockId: String? = null,
    ) {
        fun toDomain(): MapAlignmentScope {
            require(androidInstallationId.isNotBlank()) { "Stored scope has no installation id" }
            require(vineyardId.isNotBlank()) { "Stored scope has no vineyard id" }
            return MapAlignmentScope(
                androidInstallationId = androidInstallationId,
                vineyardId = vineyardId,
                blockId = blockId,
            )
        }

        companion object {
            fun from(scope: MapAlignmentScope): ScopeDocument = ScopeDocument(
                androidInstallationId = scope.androidInstallationId,
                vineyardId = scope.vineyardId,
                blockId = scope.blockId,
            )
        }
    }

    @Serializable
    private data class PointDocument(
        val id: String,
        @SerialName("canonical_lat") val canonicalLatitude: Double,
        @SerialName("canonical_lng") val canonicalLongitude: Double,
        @SerialName("marked_lat") val markedLatitude: Double,
        @SerialName("marked_lng") val markedLongitude: Double,
        @SerialName("gps_accuracy_metres") val gpsAccuracyMetres: Double? = null,
        val evidence: EvidenceDocument? = null,
        @SerialName("captured_at") val capturedAtEpochMillis: Long,
        @SerialName("alignment_id") val alignmentId: String? = null,
        @SerialName("reference_type") val referenceType: String? = null,
        val description: String? = null,
        @SerialName("row_number") val rowNumber: Int? = null,
        @SerialName("row_position") val rowPosition: String? = null,
    ) {
        fun toDomain(scope: MapAlignmentScope): MapAlignmentReferencePoint {
            require(id.isNotBlank()) { "Stored reference point has no id" }
            return MapAlignmentReferencePoint(
                id = id,
                // The scope always comes from the owning document, never from
                // the point: evidence cannot re-home itself on restore.
                scope = scope,
                canonicalCoordinate = CanonicalCoordinate(canonicalLatitude, canonicalLongitude),
                selectedMapCoordinate = AndroidDisplayCoordinate(markedLatitude, markedLongitude),
                gpsAccuracyMetres = gpsAccuracyMetres,
                gpsEvidence = evidence?.toDomain(),
                capturedAtEpochMillis = capturedAtEpochMillis,
                alignmentId = alignmentId,
                // An unrecognised enum name degrades to "not recorded" rather
                // than failing the whole restore: optional metadata is never
                // worth losing four walked reference points over.
                referenceType = referenceType?.let { name ->
                    MapAlignmentReferenceType.entries.firstOrNull { it.name == name }
                },
                description = description,
                rowNumber = rowNumber,
                rowPosition = rowPosition?.let { name ->
                    MapAlignmentRowPosition.entries.firstOrNull { it.name == name }
                },
            )
        }

        companion object {
            fun from(point: MapAlignmentReferencePoint): PointDocument = PointDocument(
                id = point.id,
                canonicalLatitude = point.canonicalCoordinate.latitude,
                canonicalLongitude = point.canonicalCoordinate.longitude,
                markedLatitude = point.selectedMapCoordinate.latitude,
                markedLongitude = point.selectedMapCoordinate.longitude,
                gpsAccuracyMetres = point.gpsAccuracyMetres,
                evidence = point.gpsEvidence?.let(EvidenceDocument::from),
                capturedAtEpochMillis = point.capturedAtEpochMillis,
                alignmentId = point.alignmentId,
                referenceType = point.referenceType?.name,
                description = point.description,
                rowNumber = point.rowNumber,
                rowPosition = point.rowPosition?.name,
            )
        }
    }

    @Serializable
    private data class EvidenceDocument(
        @SerialName("sample_count") val sampleCount: Int,
        @SerialName("duration_millis") val samplingDurationMillis: Long,
        @SerialName("representative_accuracy_metres") val representativeAccuracyMetres: Double,
        @SerialName("worst_accuracy_metres") val worstAccuracyMetres: Double,
        @SerialName("stability_radius_metres") val stabilityRadiusMetres: Double,
    ) {
        fun toDomain(): MapAlignmentGpsEvidence = MapAlignmentGpsEvidence(
            sampleCount = sampleCount,
            samplingDurationMillis = samplingDurationMillis,
            representativeAccuracyMetres = representativeAccuracyMetres,
            worstAccuracyMetres = worstAccuracyMetres,
            stabilityRadiusMetres = stabilityRadiusMetres,
        )

        companion object {
            fun from(evidence: MapAlignmentGpsEvidence): EvidenceDocument = EvidenceDocument(
                sampleCount = evidence.sampleCount,
                samplingDurationMillis = evidence.samplingDurationMillis,
                representativeAccuracyMetres = evidence.representativeAccuracyMetres,
                worstAccuracyMetres = evidence.worstAccuracyMetres,
                stabilityRadiusMetres = evidence.stabilityRadiusMetres,
            )
        }
    }

    @Serializable
    private data class PendingDocument(
        @SerialName("editing_id") val editingId: String? = null,
        @SerialName("canonical_lat") val canonicalLatitude: Double,
        @SerialName("canonical_lng") val canonicalLongitude: Double,
        val evidence: EvidenceDocument? = null,
        @SerialName("captured_at") val capturedAtEpochMillis: Long,
        @SerialName("existing_mark_lat") val existingMarkLatitude: Double? = null,
        @SerialName("existing_mark_lng") val existingMarkLongitude: Double? = null,
        @SerialName("remark_only") val remarkOnly: Boolean = false,
    ) {
        fun toDomain(): MapAlignmentPendingReference = MapAlignmentPendingReference(
            editingId = editingId,
            canonicalCoordinate = CanonicalCoordinate(canonicalLatitude, canonicalLongitude),
            gpsEvidence = evidence?.toDomain(),
            capturedAtEpochMillis = capturedAtEpochMillis,
            existingMark = if (existingMarkLatitude != null && existingMarkLongitude != null) {
                AndroidDisplayCoordinate(existingMarkLatitude, existingMarkLongitude)
            } else {
                null
            },
            remarkOnly = remarkOnly,
        )

        companion object {
            fun from(pending: MapAlignmentPendingReference): PendingDocument = PendingDocument(
                editingId = pending.editingId,
                canonicalLatitude = pending.canonicalCoordinate.latitude,
                canonicalLongitude = pending.canonicalCoordinate.longitude,
                evidence = pending.gpsEvidence?.let(EvidenceDocument::from),
                capturedAtEpochMillis = pending.capturedAtEpochMillis,
                existingMarkLatitude = pending.existingMark?.latitude,
                existingMarkLongitude = pending.existingMark?.longitude,
                remarkOnly = pending.remarkOnly,
            )
        }
    }

    /** Unknown or renamed steps resume at capture, which is always safe. */
    private fun String.toStep(): MapAlignmentWizardStep =
        MapAlignmentWizardStep.entries.firstOrNull { it.name == this }
            ?: MapAlignmentWizardStep.Capture
}

/**
 * A reference whose GPS is finished but whose image point has not been marked.
 *
 * ## Why this is persisted separately from the reference points
 *
 * Reaching Stable costs the operator a walk to the point plus a stationary wait
 * for at least five agreeing samples. If they then leave — a phone call, an
 * accidental Back, Android reclaiming the app — that work is gone unless it was
 * checkpointed, and the only way back is to walk to the same spot and stand
 * still again. So the completed GPS half is saved the moment it qualifies, and
 * resuming returns the operator to "Mark the image point" with the same
 * canonical coordinate and the same evidence.
 *
 * It is NOT a reference point: it has no marked image coordinate yet, so it
 * cannot contribute to a calibration, cannot appear in the reference list and
 * cannot participate in the solve. It is a checkpoint, and it disappears the
 * moment the operator either completes or cancels the marking step.
 *
 * ## What is deliberately not checkpointed
 *
 * An actively-running, incomplete sample group is never persisted. A partial
 * group is not evidence — the five-sample, five-second, stability and settling
 * rules exist precisely because a partial group cannot be trusted — and
 * restoring one would let samples taken before the interruption merge with
 * samples taken after it, possibly at a different place or a different time of
 * day. That single unfinished attempt restarts on resume; every previously
 * COMPLETED reference point survives.
 */
data class MapAlignmentPendingReference(
    /** Set when the pending GPS belongs to a retake of an existing reference. */
    val editingId: String? = null,
    /** The robust centre of the completed sample group. Canonical truth. */
    val canonicalCoordinate: CanonicalCoordinate,
    val gpsEvidence: MapAlignmentGpsEvidence? = null,
    val capturedAtEpochMillis: Long,
    /** The mark being replaced, for a re-mark. */
    val existingMark: AndroidDisplayCoordinate? = null,
    /** True when only the image point is being replaced; GPS must be preserved. */
    val remarkOnly: Boolean = false,
)

/**
 * An UNFINISHED calibration, saved so the operator can leave and come back.
 *
 * @property step where the operator was, so resuming does not make them repeat
 *   scope selection or the introduction.
 * @property solvedAlignmentId the id given to the last calculated candidate, if
 *   any. The candidate itself is re-derived from [draft]'s evidence rather than
 *   stored — see [MapAlignmentStorage].
 */
data class MapAlignmentStoredDraft(
    val draft: MapAlignmentDraft,
    val step: MapAlignmentWizardStep = MapAlignmentWizardStep.Capture,
    val pending: MapAlignmentPendingReference? = null,
    val solvedAlignmentId: String? = null,
    val updatedAtEpochMillis: Long,
) {
    val pointCount: Int get() = draft.referencePoints.size

    /** True when leaving would cost the operator real walking. */
    val hasProgress: Boolean get() = pointCount > 0 || pending != null

    /** e.g. "3 of 4 minimum reference points completed". */
    fun progressSummary(): String =
        "$pointCount of ${MapAlignmentSolver.MIN_POINTS} minimum reference points completed"

    /**
     * Describes a checkpointed GPS-complete reference, e.g.
     * "Point 4 GPS complete — image point still needs marking".
     */
    fun pendingSummary(): String? {
        val checkpoint = pending ?: return null
        if (checkpoint.remarkOnly) return "An image point is part-way through being re-marked"
        if (checkpoint.editingId != null) return "A GPS retake is waiting to be confirmed"
        return "Point ${pointCount + 1} GPS complete — image point still needs marking"
    }

    /** Re-derive the candidate from the stored evidence, if one was calculated. */
    fun restoredDraft(): MapAlignmentDraft {
        val alignmentId = solvedAlignmentId ?: return draft
        return draft.solved(alignmentId = alignmentId, nowEpochMillis = updatedAtEpochMillis)
    }
}

/**
 * A COMPLETED field-test calibration that was reviewed and deliberately saved.
 *
 * Survives app restart and may be reopened for review. It is still not applied
 * to any normal VineTrack map in this phase — see [MapAlignmentResolver], which
 * no production map consults for stored field-test results.
 */
data class MapAlignmentSavedCalibration(
    val calibration: MapAlignmentCalibration,
    val vineyardName: String,
    val blockName: String? = null,
    val savedAtEpochMillis: Long,
) {
    val alignment: MapAlignment get() = calibration.alignment

    val pointCount: Int get() = calibration.referencePoints.size

    val isBlockOverride: Boolean get() = alignment.scope.isBlockOverride
}
