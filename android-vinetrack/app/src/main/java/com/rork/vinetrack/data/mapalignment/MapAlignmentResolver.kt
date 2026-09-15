package com.rork.vinetrack.data.mapalignment

/**
 * The single, pure implementation of V1 alignment scope precedence.
 *
 * ## The rule
 *
 * ```
 * Block  >  Vineyard  >  None
 * ```
 *
 * 1. a matching **block** alignment for THIS Android installation;
 * 2. otherwise the matching **vineyard** alignment for THIS Android installation;
 * 3. otherwise **no alignment**.
 *
 * ## Why installation matching is non-negotiable
 *
 * An alignment describes what one operator observed on one device's imagery. If
 * resolution ever ignored [MapAlignmentScope.androidInstallationId], one
 * device's correction would silently become a vineyard-wide correction imposed
 * on every Android device — which is exactly what this feature must never do.
 * Installation and vineyard must therefore match *exactly*; there is no
 * fallback to "any alignment for this vineyard".
 *
 * Pure and side-effect free: no persistence, no sync, no Android types. **Not
 * wired to any live map in this pass.**
 */
object MapAlignmentResolver {

    /**
     * Resolve the alignment to apply for [installationId] / [vineyardId], and
     * optionally [blockId].
     *
     * @param blockId the block currently being rendered/considered, when known.
     *   Null means no block context, so only a vineyard alignment can apply.
     * @return the winning alignment, or null when nothing applies. Null means
     *   "render exactly as production does today".
     */
    fun resolve(
        alignments: List<MapAlignment>,
        installationId: String,
        vineyardId: String,
        blockId: String? = null,
    ): MapAlignment? {
        val candidates = alignments.filter {
            it.scope.androidInstallationId == installationId && it.scope.vineyardId == vineyardId
        }

        // 1. A block override, but only for the block actually in context.
        if (blockId != null) {
            candidates.firstOrNull { it.scope.blockId == blockId }?.let { return it }
        }

        // 2. The vineyard-level alignment for this installation.
        // A DIFFERENT block's override must never be borrowed here, hence the
        // explicit null check rather than "anything that isn't this block".
        return candidates.firstOrNull { it.scope.blockId == null }
    }

    /**
     * Same precedence, but never returns null: callers that always need
     * something to apply get an explicit, behaviourally invisible identity.
     */
    fun resolveOrNone(
        alignments: List<MapAlignment>,
        installationId: String,
        vineyardId: String,
        blockId: String? = null,
    ): MapAlignment = resolve(alignments, installationId, vineyardId, blockId)
        ?: MapAlignment.none(
            MapAlignmentScope(
                androidInstallationId = installationId,
                vineyardId = vineyardId,
                blockId = blockId,
            ),
        )
}
