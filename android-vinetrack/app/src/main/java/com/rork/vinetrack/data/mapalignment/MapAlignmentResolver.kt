package com.rork.vinetrack.data.mapalignment

/**
 * The single, pure implementation of V1 alignment scope precedence.
 *
 * ## The rule
 *
 * ```
 * Enabled Block  >  Enabled Vineyard  >  None
 * ```
 *
 * 1. a matching **enabled block** alignment for THIS Android installation;
 * 2. otherwise the matching **enabled vineyard** alignment for THIS Android
 *    installation;
 * 3. otherwise **no alignment**.
 *
 * ## Why enablement is part of candidate selection
 *
 * A disabled alignment is not an active candidate: it falls THROUGH to the next
 * applicable scope. If a disabled block alignment could win, it would behave as
 * an identity transform and silently suppress an enabled vineyard alignment
 * underneath it — the operator would switch a block override off and see the
 * vineyard correction disappear too.
 *
 * ```
 * disabled block          + enabled vineyard -> vineyard wins
 * enabled zero-offset blk + enabled vineyard -> block wins (identity for that block)
 * ```
 *
 * Those two cases are deliberately different, and the difference is what lets us
 * later express two distinct operator intents:
 *
 * * **"Use the vineyard alignment"** = no *active* block override.
 * * **"This block intentionally needs no correction"** = an *enabled*
 *   zero-offset block override, which wins and transforms as identity.
 *
 * So enablement is an ACTIVE-CANDIDATE question, whereas
 * [MapAlignment.isIdentity] is a TRANSFORMATION question ("can this move
 * anything?"). `isIdentity` is intentionally left unchanged and must not be used
 * for candidate selection: an enabled zero-offset alignment is identity but is
 * still a winning candidate.
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
     * Only **enabled** alignments are candidates; a disabled one falls through
     * to the next applicable scope.
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
        // Candidate = right installation, right vineyard, AND enabled. Disabled
        // alignments are excluded here so they fall through to the next scope
        // instead of winning and suppressing it. Note this is `isEnabled`, NOT
        // `!isIdentity`: an enabled zero-offset override is a real, winning
        // override that happens to transform as identity.
        val candidates = alignments.filter {
            it.scope.androidInstallationId == installationId &&
                it.scope.vineyardId == vineyardId &&
                it.isEnabled
        }

        // 1. An enabled block override, but only for the block actually in context.
        if (blockId != null) {
            candidates.firstOrNull { it.scope.blockId == blockId }?.let { return it }
        }

        // 2. The enabled vineyard-level alignment for this installation.
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
