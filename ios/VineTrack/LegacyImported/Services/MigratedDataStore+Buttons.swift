import Foundation
import CoreLocation

extension MigratedDataStore {

    private var btnPersistence: PersistenceStore { .shared }

    // MARK: - Per-vineyard storage keys

    static func repairButtonsKey(for vineyardId: UUID) -> String {
        "vinetrack_repair_buttons_v_\(vineyardId.uuidString)"
    }

    static func growthButtonsKey(for vineyardId: UUID) -> String {
        "vinetrack_growth_buttons_v_\(vineyardId.uuidString)"
    }

    // MARK: - Loading per-vineyard buttons

    /// Load repair/growth buttons for the currently selected vineyard. If no
    /// configuration exists for this vineyard, generate and persist defaults
    /// (with a very old `clientUpdatedAt` so a real remote configuration wins
    /// once the device syncs).
    func loadButtonsForCurrentVineyard() {
        guard let vineyardId = selectedVineyardId else {
            repairButtons = []
            growthButtons = []
            return
        }
        if let stored: [ButtonConfig] = btnPersistence.load(key: Self.repairButtonsKey(for: vineyardId)),
           !stored.isEmpty {
            repairButtons = stored
        } else {
            let defaults = ButtonConfig.defaultRepairButtons(for: vineyardId)
            repairButtons = defaults
            btnPersistence.save(defaults, key: Self.repairButtonsKey(for: vineyardId))
            // Mark dirty using the distant past so any real remote config wins.
            onRepairButtonsChanged?(.distantPast)
        }

        if let stored: [ButtonConfig] = btnPersistence.load(key: Self.growthButtonsKey(for: vineyardId)),
           !stored.isEmpty {
            growthButtons = stored
        } else {
            let defaults = ButtonConfig.defaultGrowthButtons(for: vineyardId)
            growthButtons = defaults
            btnPersistence.save(defaults, key: Self.growthButtonsKey(for: vineyardId))
            onGrowthButtonsChanged?(.distantPast)
        }
    }

    // MARK: - Active button sets

    func updateRepairButtons(_ buttons: [ButtonConfig]) {
        guard let vineyardId = selectedVineyardId else { return }
        let scoped = buttons.map { config -> ButtonConfig in
            var c = config
            c.vineyardId = vineyardId
            return c
        }
        repairButtons = scoped
        btnPersistence.save(scoped, key: Self.repairButtonsKey(for: vineyardId))
        onRepairButtonsChanged?(Date())
    }

    func updateGrowthButtons(_ buttons: [ButtonConfig]) {
        guard let vineyardId = selectedVineyardId else { return }
        let scoped = buttons.map { config -> ButtonConfig in
            var c = config
            c.vineyardId = vineyardId
            return c
        }
        growthButtons = scoped
        btnPersistence.save(scoped, key: Self.growthButtonsKey(for: vineyardId))
        onGrowthButtonsChanged?(Date())
    }

    func resetRepairButtonsToDefault() {
        guard let vineyardId = selectedVineyardId else { return }
        let defaults = ButtonConfig.defaultRepairButtons(for: vineyardId)
        updateRepairButtons(defaults)
    }

    func resetGrowthButtonsToDefault() {
        guard let vineyardId = selectedVineyardId else { return }
        let defaults = ButtonConfig.defaultGrowthButtons(for: vineyardId)
        updateGrowthButtons(defaults)
    }

    // MARK: - Remote-apply (sync pull)

    /// Apply a remote repair-button configuration without re-marking it dirty.
    func applyRemoteRepairButtons(_ buttons: [ButtonConfig], vineyardId: UUID) {
        let scoped = buttons.map { config -> ButtonConfig in
            var c = config
            c.vineyardId = vineyardId
            return c
        }
        btnPersistence.save(scoped, key: Self.repairButtonsKey(for: vineyardId))
        if selectedVineyardId == vineyardId {
            repairButtons = scoped
        }
    }

    /// Apply a remote growth-button configuration without re-marking it dirty.
    func applyRemoteGrowthButtons(_ buttons: [ButtonConfig], vineyardId: UUID) {
        let scoped = buttons.map { config -> ButtonConfig in
            var c = config
            c.vineyardId = vineyardId
            return c
        }
        btnPersistence.save(scoped, key: Self.growthButtonsKey(for: vineyardId))
        if selectedVineyardId == vineyardId {
            growthButtons = scoped
        }
    }

    // MARK: - Quick pin creation from a button

    /// Create a local VinePin from a button configuration. Persists via `addPin`.
    ///
    /// - Parameters:
    ///   - coordinate: the ORIGINAL GPS observation. It is stored verbatim as
    ///     the record's latitude/longitude and is never replaced by a snapped
    ///     point — the selected-row snap lives only in the attachment fields.
    ///   - capture: identity and time frozen at the press. When supplied, the
    ///     pin is timestamped at the press and refused outright if the operator
    ///     has since changed vineyard or started/ended a trip.
    @discardableResult
    func createPinFromButton(
        button: ButtonConfig,
        coordinate: CLLocationCoordinate2D,
        heading: Double?,
        capture: PinCaptureContext? = nil,
        // Nil for the unified composer, which has no Left/Right selection;
        // the launcher paths keep passing their explicit side.
        side: PinSide? = .right,
        paddockId: UUID? = nil,
        rowNumber: Int? = nil,
        createdBy: String? = nil,
        createdByUserId: UUID? = nil,
        growthStageCode: String? = nil,
        notes: String? = nil,
        attachment: PinAttachmentResolver.Attachment? = nil,
        locationScope: String? = nil,
        // Structured ROW selection (unified composer) so the optimistic local
        // pin resolves the same canonical placement as the synced record.
        rowSegments: [ManualIssueSegment]? = nil
    ) -> VinePin? {
        guard let vineyardId = selectedVineyardId else { return nil }
        if let capture,
           !capture.isCurrent(vineyardId: vineyardId, tripId: currentActiveTripIdProvider?()) {
            return nil
        }
        let observed = capture?.rawCoordinate ?? coordinate
        let pin = VinePin(
            id: capture?.pinId ?? UUID(),
            vineyardId: vineyardId,
            latitude: observed.latitude,
            longitude: observed.longitude,
            heading: heading,
            buttonName: button.name,
            buttonColor: button.color,
            side: side,
            mode: button.mode,
            paddockId: paddockId,
            rowNumber: rowNumber,
            timestamp: capture?.capturedAt ?? Date(),
            createdBy: createdBy,
            createdByUserId: createdByUserId,
            isCompleted: false,
            growthStageCode: growthStageCode,
            notes: notes,
            drivingRowNumber: attachment?.drivingRowNumber,
            pinRowNumber: attachment?.pinRowNumber,
            pinSide: attachment?.pinSide,
            alongRowDistanceM: attachment?.alongRowDistanceM,
            snappedLatitude: attachment?.snappedCoordinate?.latitude,
            snappedLongitude: attachment?.snappedCoordinate?.longitude,
            snappedToRow: attachment?.snappedToRow ?? false,
            locationScope: locationScope,
            rowSegments: rowSegments
        )
        do {
            return try addPinDurably(pin)
        } catch {
            return nil
        }
    }

    /// Create a local growth-stage pin (button mode `.growth` with isGrowthStageButton).
    ///
    /// `coordinate` is the ORIGINAL GPS observation and `capture` freezes the
    /// press identity/time — see `createPinFromButton` above.
    @discardableResult
    func createGrowthStagePin(
        stageCode: String,
        stageDescription: String,
        coordinate: CLLocationCoordinate2D,
        heading: Double?,
        capture: PinCaptureContext? = nil,
        side: PinSide? = .right,
        paddockId: UUID? = nil,
        rowNumber: Int? = nil,
        createdBy: String? = nil,
        createdByUserId: UUID? = nil,
        notes: String? = nil,
        attachment: PinAttachmentResolver.Attachment? = nil,
        locationScope: String? = nil,
        rowSegments: [ManualIssueSegment]? = nil
    ) -> VinePin? {
        guard let vineyardId = selectedVineyardId else { return nil }
        if let capture,
           !capture.isCurrent(vineyardId: vineyardId, tripId: currentActiveTripIdProvider?()) {
            return nil
        }
        let observed = capture?.rawCoordinate ?? coordinate
        let pin = VinePin(
            id: capture?.pinId ?? UUID(),
            vineyardId: vineyardId,
            latitude: observed.latitude,
            longitude: observed.longitude,
            heading: heading,
            buttonName: "Growth Stage \(stageCode)",
            buttonColor: "darkgreen",
            side: side,
            mode: .growth,
            paddockId: paddockId,
            rowNumber: rowNumber,
            timestamp: capture?.capturedAt ?? Date(),
            createdBy: createdBy,
            createdByUserId: createdByUserId,
            isCompleted: false,
            growthStageCode: stageCode,
            notes: notes ?? stageDescription,
            drivingRowNumber: attachment?.drivingRowNumber,
            pinRowNumber: attachment?.pinRowNumber,
            pinSide: attachment?.pinSide,
            alongRowDistanceM: attachment?.alongRowDistanceM,
            snappedLatitude: attachment?.snappedCoordinate?.latitude,
            snappedLongitude: attachment?.snappedCoordinate?.longitude,
            snappedToRow: attachment?.snappedToRow ?? false,
            locationScope: locationScope,
            rowSegments: rowSegments
        )
        do {
            return try addPinDurably(pin)
        } catch {
            return nil
        }
    }
}
