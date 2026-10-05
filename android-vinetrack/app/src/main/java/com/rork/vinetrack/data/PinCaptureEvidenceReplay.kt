package com.rork.vinetrack.data

/** Replays frozen evidence identities; rejected uploads remain pending for the next attempt. */
internal suspend fun replayPinCaptureEvidence(
    pending: List<PinCaptureEvidenceStore.Evidence>,
    upload: suspend (PinCaptureEvidenceStore.Evidence) -> Unit,
    markUploaded: (String, Int) -> Boolean,
) {
    pending.forEach { evidence ->
        runCatching { upload(evidence) }
            .onSuccess { markUploaded(evidence.pinId, evidence.evidenceRevision) }
    }
}
