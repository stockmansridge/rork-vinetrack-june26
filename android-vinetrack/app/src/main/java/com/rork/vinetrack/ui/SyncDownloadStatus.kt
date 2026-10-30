package com.rork.vinetrack.ui

import com.rork.vinetrack.data.HomeReadKnowledge

/** Download evidence is independent of whether the upload queue is empty. */
internal enum class SyncDownloadTone { Current, Saved, Waiting, Attention }
internal data class SyncDownloadStatus(val label: String, val tone: SyncDownloadTone)

internal fun syncDownloadStatus(
    knowledge: HomeReadKnowledge?,
    hasRecordedDownload: Boolean,
    readFailed: Boolean,
    online: Boolean,
): SyncDownloadStatus {
    if (readFailed) {
        val retained = knowledge == HomeReadKnowledge.Cached || knowledge == HomeReadKnowledge.Fresh
        return SyncDownloadStatus(
            if (retained) "Refresh failed - saved data retained" else "Download failed",
            SyncDownloadTone.Attention,
        )
    }
    return when (knowledge) {
        HomeReadKnowledge.Unknown -> SyncDownloadStatus("Not downloaded", SyncDownloadTone.Waiting)
        HomeReadKnowledge.Cached -> SyncDownloadStatus(
            if (online) "Saved data - refresh needed" else "Saved data - offline",
            SyncDownloadTone.Saved,
        )
        HomeReadKnowledge.Fresh -> SyncDownloadStatus(
            if (online) "Up to date" else "Saved data - offline",
            if (online) SyncDownloadTone.Current else SyncDownloadTone.Saved,
        )
        // A cache timestamp proves a past download, not that this attempt succeeded.
        null -> SyncDownloadStatus(
            if (hasRecordedDownload) "Last download recorded" else "Not downloaded",
            if (hasRecordedDownload) SyncDownloadTone.Saved else SyncDownloadTone.Waiting,
        )
    }
}
