import Foundation

/// Heatmap-specific normalisation layer over `v_growth_stage_observations`.
///
/// This adapter exists so the Ripeness Heatmap can merge three different
/// sources of the same growth-stage observation — canonical remote rows, the
/// offline cache, and pins the operator has just dropped but not yet synced —
/// into the single ordered `RawRecord` list the contract core expects.
///
/// It deliberately does **not** touch the Growth Stage Summary store. The
/// Summary report keeps reading `store.pins` exactly as it always has; this is
/// a parallel read path with its own cache.
///
/// Rules it enforces (contract v1.1.0):
/// * Dedupe by stable record ID — never by coordinate, date or block.
/// * A pending local edit outranks a remote row, which outranks a cached row.
/// * Assignment is revoke-only over `paddock_id`, resolved through
///   `PinPlacementContract`. Block identity is never inferred from GPS.
/// * The field-capture date is preserved by formatting local timestamps in the
///   vineyard's own timezone, so the contract's day-key slice yields the day
///   the observation was actually recorded.
nonisolated enum ELRipenessObservationAdapter {

    /// Where a raw record came from. Drives dedupe precedence.
    nonisolated enum Origin: String, Sendable, Equatable, Codable {
        /// Freshly fetched from `v_growth_stage_observations`.
        case remote
        /// Replayed from the on-disk offline cache.
        case cached
        /// A local growth-stage pin that has not yet round-tripped to the server.
        case pendingLocal
    }

    /// A raw record tagged with its origin and placement signal.
    nonisolated struct SourceRecord: Sendable, Equatable {
        let record: ELRipeness.RawRecord
        let origin: Origin
        /// The resolved `pin_placements` signal, or `nil` when the source
        /// carries no placement row at all. `nil` means "no signal", which the
        /// contract treats as *not revoked* — it is not the same as `false`.
        let placementAssigned: Bool?

        init(record: ELRipeness.RawRecord, origin: Origin, placementAssigned: Bool? = nil) {
            self.record = record
            self.origin = origin
            self.placementAssigned = placementAssigned
        }
    }

    /// Higher wins a dedupe collision.
    static func precedence(_ origin: Origin) -> Int {
        switch origin {
        case .cached: return 0
        case .remote: return 1
        case .pendingLocal: return 2
        }
    }

    /// Deduplicates by stable record ID, keeping the highest-precedence copy.
    ///
    /// First-seen order is preserved so the IDW zero-distance tie-break stays
    /// deterministic: a later, higher-precedence duplicate replaces the earlier
    /// entry **in place** rather than moving to the end of the list.
    static func merge(_ sources: [SourceRecord]) -> [SourceRecord] {
        var order: [String] = []
        var byId: [String: SourceRecord] = [:]
        order.reserveCapacity(sources.count)
        byId.reserveCapacity(sources.count)

        for source in sources {
            let id = source.record.id
            if let existing = byId[id] {
                if precedence(source.origin) > precedence(existing.origin) {
                    byId[id] = source
                }
            } else {
                byId[id] = source
                order.append(id)
            }
        }
        return order.compactMap { byId[$0] }
    }

    /// Full pipeline: merge, then run the contract normalisation.
    static func observations(
        from sources: [SourceRecord],
        selectedVineyardId: String?
    ) -> [ELRipeness.Observation] {
        let merged = merge(sources)
        var assignedById: [String: Bool] = [:]
        for source in merged {
            if let assigned = source.placementAssigned {
                assignedById[source.record.id] = assigned
            }
        }
        return ELRipeness.toObservations(
            merged.map(\.record),
            assignedById: assignedById,
            selectedVineyardId: selectedVineyardId
        )
    }

    // MARK: - Local pins

    /// ISO-8601 in a fixed timezone. The contract slices the first 10
    /// characters without any conversion, so the string must already carry the
    /// vineyard-local calendar day.
    static func isoString(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return formatter.string(from: date)
    }

    /// Converts a locally-held growth-stage pin into a pending raw record.
    ///
    /// Returns `nil` for anything that is not a growth-stage observation — the
    /// caller should not have to pre-filter, but pre-filtering is cheaper.
    ///
    /// The coordinate deliberately uses the pin's **saved** location, not its
    /// snapped location, because that is the column that syncs to
    /// `v_growth_stage_observations`. Using the snapped point here would make a
    /// pin jump the moment it synced.
    static func pendingRecord(for pin: VinePin, timeZone: TimeZone) -> SourceRecord? {
        guard pin.mode == .growth, let code = pin.growthStageCode, !code.isEmpty else { return nil }
        let placement = PinPlacementContract.placement(for: pin)
        let record = ELRipeness.RawRecord(
            id: pin.id.uuidString.lowercased(),
            vineyardId: pin.vineyardId.uuidString.lowercased(),
            paddockId: pin.paddockId?.uuidString.lowercased(),
            stageCode: code,
            latitude: pin.latitude,
            longitude: pin.longitude,
            date: isoString(pin.timestamp, in: timeZone),
            completedAt: pin.completedAt.map { isoString($0, in: timeZone) },
            createdAt: nil,
            deletedAt: nil
        )
        return SourceRecord(
            record: record,
            origin: .pendingLocal,
            placementAssigned: placement.isAssigned
        )
    }

    /// All pending local growth-stage observations for a vineyard.
    static func pendingRecords(
        pins: [VinePin],
        vineyardId: UUID?,
        timeZone: TimeZone
    ) -> [SourceRecord] {
        pins
            .filter { pin in
                guard let vineyardId else { return true }
                return pin.vineyardId == vineyardId
            }
            .compactMap { pendingRecord(for: $0, timeZone: timeZone) }
    }

    // MARK: - Blocks

    /// Block polygons for the heat surface. Blocks with fewer than three points
    /// are still returned — the contract renders them in `no_polygon` mode
    /// rather than hiding them, so the operator can see the block exists but
    /// has no boundary.
    static func blockInputs(_ paddocks: [Paddock]) -> [ELRipeness.BlockInput] {
        paddocks.map { paddock in
            ELRipeness.BlockInput(
                id: paddock.id.uuidString.lowercased(),
                name: paddock.name,
                polygon: paddock.polygonPoints.map {
                    ELRipeness.LatLng(lat: $0.latitude, lng: $0.longitude)
                }
            )
        }
    }
}
