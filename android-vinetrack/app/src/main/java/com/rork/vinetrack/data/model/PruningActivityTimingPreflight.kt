package com.rork.vinetrack.data.model

import java.time.LocalDate
import java.time.ZoneId

/** Pure preflight shared by activity saving and editor-owned task mutations. */
object PruningActivityTimingPreflight {
    fun prepare(draft: PruningActivityDraft, zone: ZoneId): PruningActivityDraft {
        require(runCatching { LocalDate.parse(draft.date) }.isSuccess) {
            "Business date unavailable. Choose the activity's actual work date before saving or changing Work Tasks."
        }
        val timing = draft.workTiming?.resolve(draft.date, draft.startTime, draft.finishTime, zone)
            ?: PruningWorkTiming.capture(draft.date, draft.startTime, draft.finishTime, zone)
        return draft.copy(workTiming = timing)
    }
}
