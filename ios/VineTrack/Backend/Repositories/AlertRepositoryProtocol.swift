import Foundation

protocol AlertRepositoryProtocol: Sendable {
    func fetchAlerts(vineyardId: UUID) async throws -> [BackendAlert]
    func fetchUserStatus(alertIds: [UUID]) async throws -> [BackendAlertUserStatus]
    func upsertAlerts(_ alerts: [BackendAlertUpsert]) async throws
    func deleteAlert(id: UUID) async throws
    func markStatus(alertId: UUID, read: Bool?, dismissed: Bool?) async throws

    func fetchPreferences(vineyardId: UUID) async throws -> BackendAlertPreferences?
    func upsertPreferences(_ preferences: BackendAlertPreferences) async throws
}
