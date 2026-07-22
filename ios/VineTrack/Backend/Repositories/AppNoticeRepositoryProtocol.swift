import Foundation

protocol AppNoticeRepositoryProtocol: Sendable {
    /// Fetches every notice — including archived/inactive — for admin lists.
    func fetchAllNotices() async throws -> [BackendAppNotice]
    /// Fetches only currently-visible notices: active, not deleted, within
    /// optional start/end windows.
    func fetchActiveNotices() async throws -> [BackendAppNotice]
    func upsertNotice(_ notice: AppNoticeUpsert) async throws
    func softDeleteNotice(id: UUID, updatedBy: UUID?) async throws
}
