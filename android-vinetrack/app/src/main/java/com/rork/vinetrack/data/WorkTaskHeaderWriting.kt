package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.WorkTask

/** Header-only transport boundary for durable Work Task replay. */
interface WorkTaskHeaderWriting {
    suspend fun replayCreate(payload: WorkTaskCreateSync.Payload): WorkTask
    suspend fun replayUpdate(payload: WorkTaskUpdateSync.Payload): WorkTask
}
