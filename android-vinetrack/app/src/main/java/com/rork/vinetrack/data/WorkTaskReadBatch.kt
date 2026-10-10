package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.data.model.TripCostAllocation
import com.rork.vinetrack.data.model.WorkTaskPaddock
import com.rork.vinetrack.data.model.WorkTaskLabourLine
import com.rork.vinetrack.data.model.WorkTaskMachineLine
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope

/** Read-only parallel preparation; no caches, write/replay calls, retained results or skipped requests. */
internal object WorkTaskReadBatch {
    data class Result(
        val headers: List<WorkTask>,
        val paddocks: List<WorkTaskPaddock>?,
        val labour: List<WorkTaskLabourLine>?,
        val machines: List<WorkTaskMachineLine>?,
        val allocations: List<TripCostAllocation>?,
    )

    suspend fun read(
        isCurrent: () -> Boolean,
        headers: suspend () -> List<WorkTask>,
        paddocks: suspend () -> List<WorkTaskPaddock>,
        labour: suspend () -> List<WorkTaskLabourLine>,
        machines: suspend () -> List<WorkTaskMachineLine>,
        allocations: suspend () -> List<TripCostAllocation> = { emptyList() },
    ): Result = coroutineScope {
        if (!isCurrent()) throw BackendError.Unauthorized
        val headerRead = async { headers() }
        val paddockRead = async { optional(paddocks) }
        val labourRead = async { optional(labour) }
        val machineRead = async { optional(machines) }
        val allocationRead = async { optional(allocations) }
        val result = Result(headerRead.await(), paddockRead.await(), labourRead.await(), machineRead.await(), allocationRead.await())
        if (!isCurrent()) throw BackendError.Unauthorized
        result
    }

    private suspend fun <T> optional(read: suspend () -> T): T? = try {
        read()
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        null
    }
}
