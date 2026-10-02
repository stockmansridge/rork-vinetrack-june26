package com.rork.vinetrack.data.chemical

/** Resolves only a private media path, never a replacement for the linked catalogue revision. */
internal object CatalogueFrontLabelResolver {
    suspend fun resolve(
        exactRevision: CatalogueRow,
        product: suspend (String) -> CatalogueRow,
        revision: suspend (String) -> CatalogueRow,
    ): String? {
        imagePath(exactRevision)?.let { return it }
        val productId = exactRevision.text("product_id")?.takeIf { it.isNotBlank() } ?: return null
        val catalogueProduct = product(productId)
        if (!catalogueProduct.id.equals(productId, ignoreCase = true)) return null
        val approvedId = catalogueProduct.text("approved_revision_id")?.takeIf { it.isNotBlank() } ?: return null
        if (approvedId.equals(exactRevision.id, ignoreCase = true)) return null
        val approvedRevision = revision(approvedId)
        if (!approvedRevision.id.equals(approvedId, ignoreCase = true) ||
            !approvedRevision.text("product_id").equals(productId, ignoreCase = true)) return null
        return imagePath(approvedRevision)
    }

    private fun imagePath(revision: CatalogueRow): String? =
        revision.text("front_label_image_path")?.takeIf { it.isNotBlank() }
}
