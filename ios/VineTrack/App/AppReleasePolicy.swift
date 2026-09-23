import Foundation

/// Public, read-only release policy returned by get_app_release_policy.
nonisolated struct AppReleasePolicy: Decodable, Sendable {
    let platform: String
    let latestVersion: String
    let latestBuild: Int64
    let minimumSupportedVersion: String
    let minimumSupportedBuild: Int64
    let updateTitle: String
    let updateMessage: String
    let storeURL: String
    let active: Bool
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case platform, active
        case latestVersion = "latest_version"
        case latestBuild = "latest_build"
        case minimumSupportedVersion = "minimum_supported_version"
        case minimumSupportedBuild = "minimum_supported_build"
        case updateTitle = "update_title"
        case updateMessage = "update_message"
        case storeURL = "store_url"
        case updatedAt = "updated_at"
    }

    enum Decision: Equatable {
        case none, optional, required
    }

    func decision(installedBuild: Int64) -> Decision {
        guard active, platform == "ios", latestBuild >= minimumSupportedBuild,
              installedBuild >= 0, installedBuild < latestBuild else { return .none }
        return installedBuild < minimumSupportedBuild ? .required : .optional
    }

    var officialStoreURL: URL? {
        guard let url = URL(string: storeURL), url.scheme == "https",
              url.host == "apps.apple.com", url.path.contains("id6761143377") else { return nil }
        return url
    }
}
