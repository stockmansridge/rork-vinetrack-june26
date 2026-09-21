import Foundation
import Supabase

/// Supabase reads and writes for Scout and Vintage Notes (SQL 236).
///
/// ## Payload shapes are deliberately explicit
///
/// Every DTO below spells out its `snake_case` keys and encodes dates as
/// strings — `date` columns as `yyyy-MM-dd` and `timestamptz` as ISO 8601. A
/// `date` column silently receiving a full timestamp is exactly how a note
/// lands on the wrong day across a timezone boundary, and the vintage is
/// derived from that date, so the error would then propagate into the season a
/// note belongs to.
///
/// ## What is NOT sent
///
/// `vintage_year` is never written by the client. SQL 236 resolves it with a
/// trigger and `resolve_vineyard_vintage_year`, and the client's local value is
/// display-only. Sending it would invite exactly the disagreement the
/// server-authoritative rule exists to prevent.
nonisolated final class VineyardInsightsSyncRepository: Sendable {

    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    static let photoBucket = "scout-photos"

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func parseDay(_ value: String) -> Date? { dayFormatter.date(from: value) }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parseTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    // MARK: - Visit DTOs

    struct VisitUpsert: Encodable, Sendable {
        let id: String
        let vineyard_id: String
        let scout_date: String
        let status: String
        let visit_summary: String?
        let weather_snapshot: WeatherPayload?
        let scout_user_id: String?
        let scout_name_snapshot: String?
        let client_updated_at: String
        let client_revision_id: String
        let deleted_at: String?
    }

    struct WeatherPayload: Codable, Sendable {
        let observed_at: String?
        let captured_at: String
        let source: String?
        let temperature_c: Double?
        let humidity_pct: Double?
        let wind_kph: Double?
        let gust_kph: Double?
        let recent_rainfall_mm: Double?
        let is_stale: Bool
        let is_unavailable: Bool
    }

    struct VisitRow: Decodable, Sendable {
        let id: UUID
        let vineyard_id: UUID
        let vintage_year: Int
        let scout_date: String
        let status: String
        let visit_summary: String?
        let weather_snapshot: WeatherPayload?
        let scout_user_id: UUID?
        let scout_name_snapshot: String?
        let updated_at: String?
        let client_updated_at: String?
        let client_revision_id: UUID?
        let sync_version: Int?
        let deleted_at: String?
    }

    struct AssessmentUpsert: Encodable, Sendable {
        let id: String
        let scout_visit_id: String
        let vineyard_id: String
        let paddock_id: String
        let status: String
        let client_updated_at: String
        let client_revision_id: String
    }

    struct AssessmentRow: Decodable, Sendable {
        let id: UUID
        let scout_visit_id: UUID
        let vineyard_id: UUID
        let paddock_id: UUID
        let status: String
        let deleted_at: String?
    }

    struct ObservationUpsert: Encodable, Sendable {
        let id: String
        let assessment_id: String
        let vineyard_id: String
        let item_kind: String
        let value_code: String?
        let value_label: String?
        let notes: String?
        let latitude: Double?
        let longitude: Double?
        let horizontal_accuracy: Double?
        let location_captured_at: String?
        let location_status: String
        let linked_pin_id: String?
        let linked_growth_record_id: String?
        let client_updated_at: String
        let client_revision_id: String

        init(
            id: String, assessment_id: String, vineyard_id: String, item_kind: String,
            value_code: String?, value_label: String?, notes: String?,
            latitude: Double? = nil, longitude: Double? = nil,
            horizontal_accuracy: Double? = nil, location_captured_at: String? = nil,
            location_status: String = PhotoLocationStatus.unavailable.code,
            linked_pin_id: String?, linked_growth_record_id: String?, client_updated_at: String,
            client_revision_id: String = UUID().uuidString
        ) {
            self.id = id
            self.assessment_id = assessment_id
            self.vineyard_id = vineyard_id
            self.item_kind = item_kind
            self.value_code = value_code
            self.value_label = value_label
            self.notes = notes
            self.latitude = latitude
            self.longitude = longitude
            self.horizontal_accuracy = horizontal_accuracy
            self.location_captured_at = location_captured_at
            self.location_status = location_status
            self.linked_pin_id = linked_pin_id
            self.linked_growth_record_id = linked_growth_record_id
            self.client_updated_at = client_updated_at
            self.client_revision_id = client_revision_id
        }

        private enum CodingKeys: String, CodingKey {
            case id, assessment_id, vineyard_id, item_kind, value_code, value_label
            case notes, latitude, longitude, horizontal_accuracy, location_captured_at, location_status
            case linked_pin_id, linked_growth_record_id, client_updated_at, client_revision_id
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(assessment_id, forKey: .assessment_id)
            try container.encode(vineyard_id, forKey: .vineyard_id)
            try container.encode(item_kind, forKey: .item_kind)
            try container.encode(value_code, forKey: .value_code)
            try container.encode(value_label, forKey: .value_label)
            try container.encode(notes, forKey: .notes)
            try container.encode(latitude, forKey: .latitude)
            try container.encode(longitude, forKey: .longitude)
            try container.encode(horizontal_accuracy, forKey: .horizontal_accuracy)
            try container.encode(location_captured_at, forKey: .location_captured_at)
            try container.encode(location_status, forKey: .location_status)
            try container.encode(linked_pin_id, forKey: .linked_pin_id)
            try container.encode(linked_growth_record_id, forKey: .linked_growth_record_id)
            try container.encode(client_updated_at, forKey: .client_updated_at)
            try container.encode(client_revision_id, forKey: .client_revision_id)
        }
    }

    struct ObservationRow: Decodable, Sendable {
        let id: UUID
        let assessment_id: UUID
        let vineyard_id: UUID
        let item_kind: String
        let value_code: String?
        let value_label: String?
        let notes: String?
        let latitude: Double?
        let longitude: Double?
        let horizontal_accuracy: Double?
        let location_captured_at: String?
        let location_status: String?
        let linked_pin_id: UUID?
        let linked_growth_record_id: UUID?
        let deleted_at: String?
    }

    struct PhotoUpsert: Encodable, Sendable {
        let id: String
        let observation_id: String
        let vineyard_id: String
        let storage_path: String
        let captured_at: String
        let latitude: Double?
        let longitude: Double?
        let horizontal_accuracy: Double?
        let location_status: String
        let captured_by: String?
        let client_updated_at: String
        let client_revision_id: String
    }

    struct PhotoRow: Decodable, Sendable {
        let id: UUID
        let observation_id: UUID
        let vineyard_id: UUID
        let storage_path: String
        let captured_at: String
        let latitude: Double?
        let longitude: Double?
        let horizontal_accuracy: Double?
        let location_status: String
        let captured_by: UUID?
        let deleted_at: String?
    }

    struct DeletionRow: Decodable, Sendable {
        let id: UUID
        let vineyard_id: UUID
        let entity_type: String
        let entity_id: UUID
        let deleted_at: String
    }

    struct PhotoCleanupRow: Decodable, Sendable {
        let id: UUID
        let vineyard_id: UUID
        let scout_visit_id: UUID
        let photo_id: UUID
        let storage_path: String
        let lease_token: UUID
    }

    struct NoteTypeRow: Decodable, Sendable {
        let id: UUID
        let vineyard_id: UUID?
        let code: String
        let group_code: String
        let label: String
        let sort_order: Int
        let is_system: Bool
        let is_active: Bool
        let deleted_at: String?
    }

    struct NoteRow: Decodable, Sendable {
        let id: UUID
        let vineyard_id: UUID
        let note_date: String
        let vintage_year: Int
        let note_type_id: UUID?
        let note_type_label: String?
        let notes: String?
        let observed_by_user_id: UUID?
        let observer_name_snapshot: String?
        let created_at: String?
        let updated_at: String?
        let client_updated_at: String?
        let sync_version: Int?
        let deleted_at: String?
    }

    // MARK: - Scout push
    //
    // Parent-first, always: visit, then assessments, then observations, then
    // photo rows. The SQL 236 foreign keys are real, so replaying a child
    // before its parent would be rejected. Ordering it here means offline
    // replay never depends on the order the operator happened to tap.

    func pushVisit(
        visit: VisitUpsert,
        assessments: [AssessmentUpsert],
        observations: [ObservationUpsert]
    ) async throws -> VisitRow {
        try requireConfigured()
        let acknowledged: VisitRow = try await provider.client
            .from("scout_visits")
            .upsert(visit, onConflict: "id")
            .select()
            .single()
            .execute()
            .value

        if !assessments.isEmpty {
            try await provider.client
                .from("scout_block_assessments")
                .upsert(assessments, onConflict: "id")
                .execute()
        }

        if !observations.isEmpty {
            try await provider.client
                .from("scout_observations")
                .upsert(observations, onConflict: "id")
                .execute()
        }
        return acknowledged
    }

    /// Insert the photo METADATA row. The bytes must already be in the bucket:
    /// a row pointing at an object that does not exist would render as a broken
    /// image on another device, which is worse than a photo still marked as
    /// pending upload.
    func pushPhotoRow(_ photo: PhotoUpsert) async throws {
        try requireConfigured()
        try await provider.client
            .from("scout_observation_photos")
            .upsert(photo, onConflict: "id")
            .execute()
    }

    /// Upload photo bytes into the private `scout-photos` bucket.
    ///
    /// The path's first folder is the vineyard id because the SQL 236 storage
    /// policies authorise on `storage_first_folder_uuid(name)`.
    func uploadPhotoBytes(path: String, data: Data) async throws -> String {
        try requireConfigured()
        _ = try await provider.client.storage
            .from(Self.photoBucket)
            .upload(
                path,
                data: data,
                options: FileOptions(
                    cacheControl: "3600",
                    contentType: "image/jpeg",
                    // Upsert so a retry after an ambiguous failure overwrites its
                    // own object rather than failing forever on a conflict.
                    upsert: true
                )
            )
        return path
    }

    func downloadPhotoBytes(path: String) async throws -> Data {
        try requireConfigured()
        return try await provider.client.storage.from(Self.photoBucket).download(path: path)
    }

    /// Remove an uploaded object that has no committed metadata row.
    func removePhotoObject(path: String) async throws {
        try requireConfigured()
        _ = try await provider.client.storage.from(Self.photoBucket).remove(paths: [path])
    }

    // MARK: - Deletion

    struct SoftDeletePatch: Encodable, Sendable {
        let deleted_at: String
        let client_updated_at: String
    }

    /// Soft-delete a visit and its children.
    ///
    /// No client hard delete exists anywhere in SQL 236 (every table has a
    /// `for delete using (false)` policy), so this is the only shape a deletion
    /// can take. Children are tombstoned explicitly rather than relying on the
    /// cascade, because the cascade only fires on a real DELETE.
    struct HardDeleteVisitParams: Encodable, Sendable {
        let p_vineyard_id: String
        let p_visit_id: String
        let p_operation_id: String
        let p_deleted_at: String
    }

    func hardDeleteVisit(
        id: UUID,
        vineyardID: UUID,
        operationID: UUID,
        at date: Date
    ) async throws {
        try requireConfigured()
        try await provider.client.rpc(
            "hard_delete_scout_visit",
            params: HardDeleteVisitParams(
                p_vineyard_id: vineyardID.uuidString,
                p_visit_id: id.uuidString,
                p_operation_id: operationID.uuidString,
                p_deleted_at: Self.timestamp(date)
            )
        ).execute()
    }

    func softDeletePhoto(id: UUID, at date: Date) async throws {
        try requireConfigured()
        try await provider.client
            .from("scout_observation_photos")
            .update(
                SoftDeletePatch(
                    deleted_at: Self.timestamp(date),
                    client_updated_at: Self.timestamp(date)
                )
            )
            .eq("id", value: id.uuidString)
            .execute()
    }

    // MARK: - Scout pull

    func fetchVisits(vineyardID: UUID, since: Date?) async throws -> [VisitRow] {
        try requireConfigured()
        let query = provider.client
            .from("scout_visits")
            .select()
            .eq("vineyard_id", value: vineyardID.uuidString)
        if let since {
            return try await query
                .gt("updated_at", value: Self.timestamp(since))
                .order("updated_at", ascending: true)
                .execute()
                .value
        }
        return try await query.order("updated_at", ascending: true).execute().value
    }

    func fetchAssessments(vineyardID: UUID, visitIDs: [UUID]) async throws -> [AssessmentRow] {
        try requireConfigured()
        guard !visitIDs.isEmpty else { return [] }
        return try await provider.client
            .from("scout_block_assessments")
            .select()
            .eq("vineyard_id", value: vineyardID.uuidString)
            .in("scout_visit_id", values: visitIDs.map { $0.uuidString })
            .execute()
            .value
    }

    func fetchObservations(vineyardID: UUID, assessmentIDs: [UUID]) async throws -> [ObservationRow] {
        try requireConfigured()
        guard !assessmentIDs.isEmpty else { return [] }
        return try await provider.client
            .from("scout_observations")
            .select()
            .eq("vineyard_id", value: vineyardID.uuidString)
            .in("assessment_id", values: assessmentIDs.map { $0.uuidString })
            .execute()
            .value
    }

    func fetchPhotos(vineyardID: UUID, observationIDs: [UUID]) async throws -> [PhotoRow] {
        try requireConfigured()
        guard !observationIDs.isEmpty else { return [] }
        return try await provider.client
            .from("scout_observation_photos")
            .select()
            .eq("vineyard_id", value: vineyardID.uuidString)
            .in("observation_id", values: observationIDs.map { $0.uuidString })
            .execute()
            .value
    }

    // MARK: - Deletion feed and cleanup queue

    func fetchDeletions(vineyardID: UUID, since: Date?) async throws -> [DeletionRow] {
        try requireConfigured()
        let query = provider.client.from("vineyard_insights_deletions")
            .select()
            .eq("vineyard_id", value: vineyardID.uuidString)
        if let since {
            return try await query.gte("deleted_at", value: Self.timestamp(since))
                .order("deleted_at", ascending: true).order("id", ascending: true)
                .execute().value
        }
        return try await query.order("deleted_at", ascending: true).order("id", ascending: true)
            .execute().value
    }

    private struct ClaimCleanupParams: Encodable, Sendable {
        let p_vineyard_id: String
        let p_limit: Int
    }

    private struct CompleteCleanupParams: Encodable, Sendable {
        let p_id: String
        let p_lease_token: String
    }

    private struct FailCleanupParams: Encodable, Sendable {
        let p_id: String
        let p_lease_token: String
        let p_error: String
    }

    func claimPhotoCleanup(vineyardID: UUID, limit: Int = 20) async throws -> [PhotoCleanupRow] {
        try requireConfigured()
        return try await provider.client.rpc(
            "claim_scout_photo_cleanup",
            params: ClaimCleanupParams(p_vineyard_id: vineyardID.uuidString, p_limit: limit)
        ).execute().value
    }

    func acknowledgePhotoCleanup(id: UUID, leaseToken: UUID) async throws {
        try requireConfigured()
        try await provider.client.rpc(
            "complete_scout_photo_cleanup",
            params: CompleteCleanupParams(p_id: id.uuidString, p_lease_token: leaseToken.uuidString)
        ).execute()
    }

    func failPhotoCleanup(id: UUID, leaseToken: UUID, error: String) async throws {
        try requireConfigured()
        try await provider.client.rpc(
            "fail_scout_photo_cleanup",
            params: FailCleanupParams(
                p_id: id.uuidString,
                p_lease_token: leaseToken.uuidString,
                p_error: String(error.prefix(500))
            )
        ).execute()
    }

    // MARK: - Vintage Notes
    //
    // Notes go through the RPC, not a table upsert, because the RPC is what
    // resolves the vintage and stamps the observer server-side. Argument names
    // and optionality below match SQL 236 exactly.

    struct UpsertNoteParams: Encodable, Sendable {
        let p_id: String
        let p_vineyard_id: String
        let p_note_date: String
        let p_note_type_id: String?
        let p_note_type_label: String?
        let p_notes: String?
        let p_observer_name: String?
        let p_client_updated_at: String?
    }

    struct HardDeleteNoteParams: Encodable, Sendable {
        let p_vineyard_id: String
        let p_note_id: String
        let p_operation_id: String
        let p_deleted_at: String
    }

    struct UpsertNoteTypeParams: Encodable, Sendable {
        let p_id: String
        let p_vineyard_id: String
        let p_code: String
        let p_group_code: String
        let p_label: String
        let p_sort_order: Int
        let p_is_active: Bool
    }

    func upsertNote(_ params: UpsertNoteParams) async throws -> NoteRow? {
        try requireConfigured()
        let rows: [NoteRow] = try await provider.client
            .rpc("upsert_vintage_note", params: params)
            .execute()
            .value
        return rows.first
    }

    func hardDeleteNote(
        id: UUID,
        vineyardID: UUID,
        operationID: UUID,
        at date: Date
    ) async throws {
        try requireConfigured()
        try await provider.client.rpc(
            "hard_delete_vintage_note",
            params: HardDeleteNoteParams(
                p_vineyard_id: vineyardID.uuidString,
                p_note_id: id.uuidString,
                p_operation_id: operationID.uuidString,
                p_deleted_at: Self.timestamp(date)
            )
        ).execute()
    }

    func upsertNoteType(_ params: UpsertNoteTypeParams) async throws {
        try requireConfigured()
        try await provider.client
            .rpc("upsert_vintage_note_type", params: params)
            .execute()
    }

    func fetchNoteTypes(vineyardID: UUID) async throws -> [NoteTypeRow] {
        try requireConfigured()
        return try await provider.client
            .from("vintage_note_types")
            .select("id,vineyard_id,code,group_code,label,sort_order,is_system,is_active,deleted_at")
            .or("vineyard_id.is.null,vineyard_id.eq.\(vineyardID.uuidString)")
            .order("group_code", ascending: true)
            .order("sort_order", ascending: true)
            .execute()
            .value
    }

    func fetchNotes(vineyardID: UUID, since: Date?) async throws -> [NoteRow] {
        try requireConfigured()
        let query = provider.client
            .from("vintage_notes")
            .select()
            .eq("vineyard_id", value: vineyardID.uuidString)
        if let since {
            return try await query
                .gt("updated_at", value: Self.timestamp(since))
                .order("updated_at", ascending: true)
                .execute()
                .value
        }
        return try await query.order("updated_at", ascending: true).execute().value
    }

    private func requireConfigured() throws {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
    }
}
