package com.rork.vinetrack.data

import kotlinx.coroutines.ensureActive

/** Replays frozen evidence identities; rejected uploads remain pending for the next attempt. */
internal suspend fun replayPinCaptureEvidence(
    pending: List<PinCaptureEvidenceStore.Evidence>,
    upload: suspend (PinCaptureEvidenceStore.Evidence) -> Unit,
    markUploaded: (String, Int) -> Boolean,
    isAuthorityCurrent: (PinCaptureEvidenceStore.Evidence) -> Boolean = { true },
) {
    pending.forEach { evidence ->
        kotlinx.coroutines.currentCoroutineContext().ensureActive()
        if (!isAuthorityCurrent(evidence)) return@forEach
        try {
            upload(evidence)
            kotlinx.coroutines.currentCoroutineContext().ensureActive()
            // A rejected/throwing durable acknowledgement remains pending. It
            // must not abort unrelated observations or fabricate upload success.
            if (isAuthorityCurrent(evidence)) markUploaded(evidence.pinId, evidence.evidenceRevision)
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            // The immutable original remains in its own evidence outbox.
        }
    }
}
