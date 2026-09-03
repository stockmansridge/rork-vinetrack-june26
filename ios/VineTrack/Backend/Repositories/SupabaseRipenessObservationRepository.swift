import Foundation
import Supabase

/// One row of `v_growth_stage_observations`.
///
/// Every field is optional and every timestamp is decoded as a **String**.
/// That is deliberate: the contract slices the first ten characters of the
/// stored ISO text with no timezone conversion, so parsing into `Date` and
/// re-formatting would silently shift observations across the day boundary for
/// any vineyard that is not in UTC.
nonisolated struct RipenessObservationRow: Decodable, Sendable, Equatable {
    let id: String
    let vineyardId: String?
    let paddockId: String?
    let stageCode: String?
    let stageLabel: String?
    let variety: String?
    let varietyId: String?
    let observedAt: String?
    let latitude: Double?
    let longitude: Double?
    let rowNumber: Int?
    let side: String?
    let notes: String?
    let photoPaths: [String]?
    let recordedByName: String?
    let createdBy: String?
    let updatedBy: String?
    let createdAt: String?
    let updatedAt: String?
    let source: String?
    /// Present when the view exposes the originating pin. Optional because the
    /// column is not guaranteed — decoding must never fail on its absence.
    let pinId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case pinId = "pin_id"
        case stageCode = "stage_code"
        case stageLabel = "stage_label"
        case variety
        case varietyId = "variety_id"
        case observedAt = "observed_at"
        case latitude
        case longitude
        case rowNumber = "row_number"
        case side
        case notes
        case photoPaths = "photo_paths"
        case recordedByName = "recorded_by_name"
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case source
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The view's own primary key is the only required column.
        if let stringId = try? c.decode(String.self, forKey: .id) {
            id = stringId
        } else {
            id = try c.decode(UUID.self, forKey: .id).uuidString.lowercased()
        }
        vineyardId = try Self.decodeIdentifier(c, .vineyardId)
        paddockId = try Self.decodeIdentifier(c, .paddockId)
        pinId = try Self.decodeIdentifier(c, .pinId)
        stageCode = try c.decodeIfPresent(String.self, forKey: .stageCode)
        stageLabel = try c.decodeIfPresent(String.self, forKey: .stageLabel)
        variety = try c.decodeIfPresent(String.self, forKey: .variety)
        varietyId = try Self.decodeIdentifier(c, .varietyId)
        observedAt = try c.decodeIfPresent(String.self, forKey: .observedAt)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        rowNumber = try c.decodeIfPresent(Int.self, forKey: .rowNumber)
        side = try c.decodeIfPresent(String.self, forKey: .side)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        photoPaths = try c.decodeIfPresent([String].self, forKey: .photoPaths)
        recordedByName = try c.decodeIfPresent(String.self, forKey: .recordedByName)
        createdBy = try Self.decodeIdentifier(c, .createdBy)
        updatedBy = try Self.decodeIdentifier(c, .updatedBy)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }

    private static func decodeIdentifier(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) throws -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return value.lowercased()
        }
        if let value = try? container.decodeIfPresent(UUID.self, forKey: key) {
            return value.uuidString.lowercased()
        }
        return nil
    }

    var sourceRecord: ELRipenessObservationAdapter.SourceRecord {
        ELRipenessObservationAdapter.SourceRecord(
            record: ELRipeness.RawRecord(
                id: id,
                vineyardId: vineyardId,
                paddockId: paddockId,
                stageCode: stageCode,
                latitude: latitude,
                longitude: longitude,
                observedAt: observedAt,
                createdAt: createdAt
            ),
            origin: .remote,
            placementAssigned: nil,
            pinId: pinId
        )
    }
}

nonisolated enum RipenessObservationRepositoryError: LocalizedError, Sendable {
    case permission
    case decoding
    case query

    var errorDescription: String? {
        switch self {
        case .permission: return "You do not have permission to read growth-stage observations."
        case .decoding: return "Growth-stage observations could not be decoded."
        case .query: return "Growth-stage observations could not be fetched."
        }
    }
}

protocol RipenessObservationRepositoryProtocol: Sendable {
    /// Canonical observations for a vineyard. The whole vineyard is fetched in
    /// one request so every Vintage is cached together and the timeline can be
    /// scrubbed without touching the network again.
    func fetchObservations(vineyardId: UUID) async throws -> [RipenessObservationRow]
}

final class SupabaseRipenessObservationRepository: RipenessObservationRepositoryProtocol {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func fetchObservations(vineyardId: UUID) async throws -> [RipenessObservationRow] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        do {
            return try await provider.client
                .from("v_growth_stage_observations")
                .select()
                .eq("vineyard_id", value: vineyardId.uuidString)
                .execute()
                .value
        } catch is DecodingError {
            throw RipenessObservationRepositoryError.decoding
        } catch {
            let description = error.localizedDescription.lowercased()
            if description.contains("401") || description.contains("403") ||
                description.contains("permission") || description.contains("jwt") {
                throw RipenessObservationRepositoryError.permission
            }
            throw RipenessObservationRepositoryError.query
        }
    }
}
