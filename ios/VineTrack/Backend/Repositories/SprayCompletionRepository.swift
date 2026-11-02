import Foundation
import Supabase

@MainActor
final class SprayCompletionRepository {
    func fetchRecord(id: UUID) async throws -> BackendSprayRecord {
        try await SupabaseClientProvider.shared.client.from("spray_records")
            .select().eq("id", value: id.uuidString).single().execute().value
    }

    func fetchLinked(tripId: UUID) async throws -> [BackendSprayRecord] {
        try await SupabaseClientProvider.shared.client.from("spray_records")
            .select().eq("trip_id", value: tripId.uuidString).is("deleted_at", value: nil).execute().value
    }

    /// Pin the authenticated owner/token for automatic replay; an account
    /// switch must not redirect a suspended request into the next user's session.
    func completeTracked(id: UUID, ownerId: UUID) async throws -> SprayCompletionResponse {
        let provider = SupabaseClientProvider.shared
        let session = try await provider.client.auth.session
        guard session.user.id == ownerId, provider.client.auth.currentUser?.id == ownerId else {
            throw TrackedSprayCompletionSync.Failure.held
        }
        var request = URLRequest(url: provider.supabaseURL.appendingPathComponent("rest/v1/rpc/complete_spray_record"))
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SprayCompletionRequest(p_spray_record_id: id, p_allow_unlinked: false))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard provider.client.auth.currentUser?.id == ownerId,
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TrackedSprayCompletionSync.Failure.held
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
                throw TrackedSprayCompletionSync.Failure.held
            }
            return date
        }
        return try decoder.decode(SprayCompletionResponse.self, from: data)
    }

    func complete(id: UUID, allowUnlinked: Bool) async throws -> SprayCompletionResponse {
        try await SupabaseClientProvider.shared.client
            .rpc("complete_spray_record", params: SprayCompletionRequest(p_spray_record_id: id, p_allow_unlinked: allowUnlinked))
            .execute().value
    }
}
