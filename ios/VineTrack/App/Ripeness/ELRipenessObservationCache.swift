import Foundation

/// On-disk cache of normalised ripeness observations and block polygons.
///
/// The heatmap must render a full season — polygons, pins and heat surfaces —
/// with no network at all, so everything needed to rebuild the model locally is
/// persisted per vineyard. Only the fields the contract reads are stored; this
/// is not a general-purpose mirror of the growth-stage tables.
nonisolated struct ELRipenessCachedRecord: Codable, Sendable, Equatable {
    let id: String
    let vineyardId: String?
    let paddockId: String?
    let stageCode: String?
    let latitude: Double?
    let longitude: Double?
    let date: String?
    let completedAt: String?
    let createdAt: String?
    let deletedAt: String?
    let placementAssigned: Bool?

    var rawRecord: ELRipeness.RawRecord {
        ELRipeness.RawRecord(
            id: id,
            vineyardId: vineyardId,
            paddockId: paddockId,
            stageCode: stageCode,
            latitude: latitude,
            longitude: longitude,
            date: date,
            completedAt: completedAt,
            createdAt: createdAt,
            deletedAt: deletedAt
        )
    }

    var sourceRecord: ELRipenessObservationAdapter.SourceRecord {
        ELRipenessObservationAdapter.SourceRecord(
            record: rawRecord,
            origin: .cached,
            placementAssigned: placementAssigned
        )
    }

    init(from source: ELRipenessObservationAdapter.SourceRecord) {
        let record = source.record
        self.id = record.id
        self.vineyardId = record.vineyardId
        self.paddockId = record.paddockId
        self.stageCode = record.stageCode
        self.latitude = record.latitude
        self.longitude = record.longitude
        self.date = record.date
        self.completedAt = record.completedAt
        self.createdAt = record.createdAt
        self.deletedAt = record.deletedAt
        self.placementAssigned = source.placementAssigned
    }
}

/// A block boundary captured alongside the observations so the map can draw
/// clipped heat and outlines while completely offline.
nonisolated struct ELRipenessCachedBlock: Codable, Sendable, Equatable {
    let id: String
    let name: String?
    let points: [[Double]]

    var blockInput: ELRipeness.BlockInput {
        ELRipeness.BlockInput(
            id: id,
            name: name,
            polygon: points.compactMap { pair in
                pair.count == 2 ? ELRipeness.LatLng(lat: pair[0], lng: pair[1]) : nil
            }
        )
    }

    init(from input: ELRipeness.BlockInput) {
        self.id = input.id
        self.name = input.name
        self.points = input.polygon.map { [$0.lat, $0.lng] }
    }
}

/// Everything needed to rebuild the heatmap for one vineyard with no network.
nonisolated struct ELRipenessCachePayload: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let vineyardId: String
    let cachedAt: Date
    let records: [ELRipenessCachedRecord]
    let blocks: [ELRipenessCachedBlock]
    /// Vintages this cache is known to represent completely. A Vintage outside
    /// this set has never been fetched, so while offline it must report
    /// "unavailable offline" rather than "no observations" — the difference
    /// between *we know there is nothing* and *we do not know*.
    let coveredVintages: [Int]

    var sourceRecords: [ELRipenessObservationAdapter.SourceRecord] {
        records.map(\.sourceRecord)
    }

    var blockInputs: [ELRipeness.BlockInput] {
        blocks.map(\.blockInput)
    }
}

/// Reads and writes `ELRipenessCachePayload` files, one per vineyard.
nonisolated protocol ELRipenessObservationCaching: Sendable {
    func load(vineyardId: UUID) -> ELRipenessCachePayload?
    func save(_ payload: ELRipenessCachePayload)
    func clear(vineyardId: UUID)
}

nonisolated struct ELRipenessObservationCache: ELRipenessObservationCaching {
    private let directoryName = "RipenessHeatmapCache"

    /// `FileManager` is not `Sendable`, so the shared instance is resolved at
    /// each call site rather than stored on this value type.
    private var fileManager: FileManager { .default }

    init() {}

    private var directory: URL? {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent(directoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func url(for vineyardId: UUID) -> URL? {
        directory?.appendingPathComponent("\(vineyardId.uuidString.lowercased()).json")
    }

    func load(vineyardId: UUID) -> ELRipenessCachePayload? {
        guard let url = url(for: vineyardId), fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(ELRipenessCachePayload.self, from: data)
            guard payload.schemaVersion == ELRipenessCachePayload.currentSchemaVersion else { return nil }
            return payload
        } catch {
            // A corrupt or superseded cache is not an error the operator can
            // act on — drop it and fall back to a fresh fetch.
            print("[Ripeness] cache read failed, discarding: \(error.localizedDescription)")
            try? fileManager.removeItem(at: url)
            return nil
        }
    }

    func save(_ payload: ELRipenessCachePayload) {
        guard let vineyardUUID = UUID(uuidString: payload.vineyardId),
              let url = url(for: vineyardUUID) else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[Ripeness] cache write failed: \(error.localizedDescription)")
        }
    }

    func clear(vineyardId: UUID) {
        guard let url = url(for: vineyardId) else { return }
        try? fileManager.removeItem(at: url)
    }
}
