package com.rork.vinetrack.data.spray

/** Never present a local draft or unverified pending request as a server-confirmed save/start. */
enum class SprayPlanningPresentation(val title: String) {
    DRAFT("Local draft — not server saved"), SAVE_REQUESTED("Save requested — confirmation pending"),
    SAVE_CONFIRMED("Save receipt confirmed"), SAVED_UNBOUND("Saved — work area not selected"),
    BINDING_REQUESTED("Route selected — binding confirmation pending"), BOUND("Route binding confirmed"),
    READY("Ready to Start"), ACTIVE("Active spray operation"),
    HELD("Reconciliation required — original evidence retained"), REPAIR_REQUIRED("Receipt verified — local repair required");
    companion object {
        fun state(a: SprayPlanningAttemptJournal.Attempt?): SprayPlanningPresentation {
            if (a == null) return DRAFT
            if (a.stage in listOf(SprayPlanningAttemptJournal.Stage.HELD, SprayPlanningAttemptJournal.Stage.QUARANTINED)) return HELD
            val receipt = a.receipt ?: return if (a.request.kind == SprayPlanningProtocol.Kind.BIND) BINDING_REQUESTED else SAVE_REQUESTED
            if (a.stage != SprayPlanningAttemptJournal.Stage.COMPLETE) return REPAIR_REQUIRED
            return when (receipt.result.phase) {
                SprayPlanningProtocol.Phase.SAVED_UNBOUND -> SAVED_UNBOUND
                SprayPlanningProtocol.Phase.BOUND -> BOUND
                SprayPlanningProtocol.Phase.READY -> if (receipt.result.routeRevisionId == null) HELD else READY
                SprayPlanningProtocol.Phase.ACTIVE -> if (receipt.result.routeRevisionId == null) HELD else ACTIVE
            }
        }
    }
}
