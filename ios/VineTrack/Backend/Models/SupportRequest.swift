import Foundation

/// Category for an in-app support / feedback / feature request.
nonisolated enum SupportRequestCategory: String, CaseIterable, Sendable, Identifiable {
    case general
    case bug
    case feature
    case account
    case billing
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General"
        case .bug: return "Bug / Issue"
        case .feature: return "Feature Request"
        case .account: return "Account"
        case .billing: return "Billing"
        case .other: return "Other"
        }
    }
}

/// Outcome of submitting a support request. The DB insert is the durable path,
/// so `stored` is always true on success; `emailStatus` reflects best-effort
/// email delivery to the support inbox.
nonisolated struct SupportSubmissionResult: Sendable {
    /// Email delivery status reported by the edge function:
    /// "sent" | "failed" | "unconfigured" | "unknown".
    let emailStatus: String
    let attachmentCount: Int

    var emailDelivered: Bool { emailStatus == "sent" }
}

/// Snapshot of the device / app for diagnostics attached to a support request.
nonisolated struct SupportDiagnostics: Sendable {
    let appPlatform: String
    let appVersion: String
    let appBuild: String
    let deviceModel: String
    let osVersion: String
}

/// Insert payload encoded into the `support_requests` table.
nonisolated struct SupportRequestInsert: Encodable, Sendable {
    let id: String
    let userId: String
    let submitterName: String?
    let submitterEmail: String?
    let vineyardId: String?
    let vineyardName: String?
    let category: String
    let subject: String
    let message: String
    let attachmentPaths: [String]
    let attachmentCount: Int
    let appPlatform: String?
    let appVersion: String?
    let appBuild: String?
    let deviceModel: String?
    let osVersion: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case submitterName = "submitter_name"
        case submitterEmail = "submitter_email"
        case vineyardId = "vineyard_id"
        case vineyardName = "vineyard_name"
        case category
        case subject
        case message
        case attachmentPaths = "attachment_paths"
        case attachmentCount = "attachment_count"
        case appPlatform = "app_platform"
        case appVersion = "app_version"
        case appBuild = "app_build"
        case deviceModel = "device_model"
        case osVersion = "os_version"
    }
}
