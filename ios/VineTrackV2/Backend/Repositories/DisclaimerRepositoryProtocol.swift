import Foundation

protocol DisclaimerRepositoryProtocol: Sendable {
    func hasAcceptedCurrentDisclaimer() async throws -> Bool
    func acceptCurrentDisclaimer(version: String, displayName: String?, email: String?) async throws
}
