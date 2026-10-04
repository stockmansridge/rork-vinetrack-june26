package com.rork.vinetrack.data.chemical

object CatalogueTerminalResolver {
    suspend fun result(job: CatalogueRow, fetch: suspend (String) -> CatalogueRow): CatalogueRow {
        check(job.isSuccess)
        val id = requireNotNull(job.text("revision_id"))
        val exact = fetch(id)
        check(exact.id == id && (job.text("stage") != "catalogue_match" || exact.text("review_status") == "approved"))
        return exact
    }
}
