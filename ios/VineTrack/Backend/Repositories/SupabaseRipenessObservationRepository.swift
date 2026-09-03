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
    let growthStageCode: String?
    let latitude: Double?
    let longitude: Double?
    let date: String?
    let completedAt: String?
    let createdAt: String?
    let deletedAt: String?
    let isLocationAssigned: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case growthStageCode = "growth_stage_code"
        case latitude
        case longitude
        case date
        case completedAt = "completed_at"
        case createdAt = "created_at"
        case deletedAt = "deleted_at"
        case isLocationAssigned = "is_location_assigned"
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
        growthStageCode = try c.decodeIfPresent(String.self, forKey: .growthStageCode)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt)
        isLocationAssigned = try c.decodeIfPresent(Bool.self, forKey: .isLocationAssigned)
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
                stageCode: growthStageCode,
                latitude: latitude,
                longitude: longitude,
                date: date,
                completedAt: completedAt,
                createdAt: createdAt,
                deletedAt: deletedAt
            ),
            origin: .remote,
            placementAssigned: isLocationAssigned
        )
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
        return try await provider.client
            .from("v_growth_stage_observations")
            .select()
            .eq("vineyard_id", value: vineyardId.uuidString)
            .execute()
            .value
    }
}
