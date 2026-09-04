package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.Trip

/** Local-first activation contract for an already-downloaded Not Started trip. */
object SavedTripActivation {
    /** Returns a fresh active snapshot, or null when this is not an unstarted placeholder. */
    fun activate(trip: Trip, operationalStart: String): Trip? {
        val isUnstarted = !trip.isActive &&
            trip.endTime == null &&
            trip.pathPoints.orEmpty().isEmpty() &&
            (trip.totalDistance ?: 0.0) == 0.0 &&
            trip.completedPaths.orEmpty().isEmpty() &&
            trip.skippedPaths.orEmpty().isEmpty() &&
            trip.tankSessions.isEmpty()
        if (!isUnstarted) return null
        return trip.copy(
            startTime = operationalStart,
            endTime = null,
            isActive = true,
            isPaused = false,
            totalDistance = 0.0,
            pathPoints = emptyList(),
            completedPaths = emptyList(),
            skippedPaths = emptyList(),
            pauseTimestamps = emptyList(),
            resumeTimestamps = emptyList(),
            tankSessions = emptyList(),
            activeTankNumber = null,
            isFillingTank = false,
            fillingTankNumber = null,
            clientUpdatedAt = operationalStart,
        )
    }

    /** Refresh only operational clocks on the existing linked spray record. */
    fun activateLinkedSpray(record: SprayRecord, tripId: String, operationalStart: String): SprayRecord? {
        if (record.isTemplate || record.tripId != tripId || record.endTime != null) return null
        return record.copy(date = operationalStart, startTime = operationalStart, endTime = null)
    }

    /** Build the existing full-record update contract without recalculating its plan. */
    fun sprayUpdateInput(record: SprayRecord): SprayRecordRepository.SprayInput =
        SprayRecordRepository.SprayInput(
            date = requireNotNull(record.date),
            startTime = requireNotNull(record.startTime),
            temperature = record.temperature,
            windSpeed = record.windSpeed,
            windDirection = record.windDirection,
            humidity = record.humidity,
            sprayReference = record.sprayReference,
            notes = record.notes,
            numberOfFansJets = record.numberOfFansJets,
            averageSpeed = record.averageSpeed,
            equipmentType = record.equipmentType,
            tractor = record.tractor,
            tractorGear = record.tractorGear,
            machineId = record.machineId,
            sprayEquipmentId = record.sprayEquipmentId,
            operationType = record.operationType,
            tripId = record.tripId,
            isTemplate = record.isTemplate,
            tanks = record.tanks.orEmpty(),
            applicationGeometry = record.applicationGeometry,
        )
}
