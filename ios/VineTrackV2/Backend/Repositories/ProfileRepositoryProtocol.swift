import Foundation

protocol ProfileRepositoryProtocol: Sendable {
    func getMyProfile() async throws -> BackendProfile?
    func upsertMyProfile(fullName: String?, email: String?) async throws
    func updateDefaultVineyard(vineyardId: UUID?) async throws
}
