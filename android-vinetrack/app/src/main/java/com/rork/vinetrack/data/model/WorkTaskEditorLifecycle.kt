package com.rork.vinetrack.data.model

/**
 * Two-stage Work Task editor state. The client-generated parent id becomes
 * authoritative as soon as the optimistic create is accepted locally, so child
 * records can safely use the same id online or offline.
 */
enum class WorkTaskEditorSaveOperation { CREATE, UPDATE }

data class WorkTaskEditorLifecycle(
    val persistedTaskId: String? = null,
) {
    val hasPersistedTask: Boolean get() = persistedTaskId != null
    val saveOperation: WorkTaskEditorSaveOperation
        get() = if (hasPersistedTask) WorkTaskEditorSaveOperation.UPDATE else WorkTaskEditorSaveOperation.CREATE
    val saveTitle: String get() = if (hasPersistedTask) "Save & Close" else "Save"
    val childControlsEnabled: Boolean get() = hasPersistedTask

    /** First save retains the minted id and keeps the editor open. */
    fun acceptingFirstSave(taskId: String): WorkTaskEditorLifecycle = copy(persistedTaskId = taskId)

    /** A rejected optimistic create returns the editor to its unsaved state. */
    fun rejectingFirstSave(): WorkTaskEditorLifecycle = copy(persistedTaskId = null)

    /** Only a save that began with an existing local parent closes the editor. */
    fun shouldCloseAfterAcceptedSave(): Boolean = hasPersistedTask
}
