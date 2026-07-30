import Foundation
import UIKit
import Supabase

/// Best-effort, throttled client telemetry heartbeat (SQL 154).
///
/// Reports safe, installation-scoped device/app metadata to
/// `record_my_client_activity` so the System Admin User Activity page can
/// show real usage (App / Platform / Device / OS) instead of "Unknown".
///
/// Privacy rules:
/// * `client_instance_id` is a random UUID generated once per installation
///   and stored in `UserDefaults`. It is NOT a hardware identifier and is
///   never derived from IMEI/serial/MAC/advertising ID.
/// * Only bundle version/build, model identifier, iOS version and device
///   family are reported. No location, no IP, no personal device name.
/// * Telemetry is best-effort: failures are swallowed and never block
///   login or normal app use. Throttled to once per 15 minutes unless the
///   metadata signature (version, vineyard, OS) materially changes.
final class ClientTelemetryService {
    static let shared = ClientTelemetryService()

    private let provider = SupabaseClientProvider.shared
    private var isSending = false

    private static let clientIdKey = "vinetrack.telemetry.clientInstanceId"
    private static let lastSentAtKey = "vinetrack.telemetry.lastSentAt"
    private static let lastSignatureKey = "vinetrack.telemetry.lastSignature"
    private static let minInterval: TimeInterval = 15 * 60

    private init() {}

    /// Random per-installation identifier. Survives sign-out (the same
    /// installation used by a new account creates a separate user/client
    /// association server-side); reset only on reinstall.
    private var clientInstanceId: UUID {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.clientIdKey), let id = UUID(uuidString: raw) {
            return id
        }
        let id = UUID()
        defaults.set(id.uuidString, forKey: Self.clientIdKey)
        return id
    }

    /// Send a heartbeat if due. Safe to call from any auth/foreground/
    /// vineyard-change hook — internal throttling prevents over-reporting.
    /// Never throws; never blocks the caller's flow.
    func reportActivity(vineyardId: UUID?) async {
        guard provider.isConfigured else { return }
        guard provider.client.auth.currentSession != nil else { return }
        guard !isSending else { return }

        let family = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let signature = [
            AppBuildInfo.version,
            AppBuildInfo.buildNumber,
            AppBuildInfo.iosVersion,
            vineyardId?.uuidString ?? "-"
        ].joined(separator: "|")

        let defaults = UserDefaults.standard
        let lastSignature = defaults.string(forKey: Self.lastSignatureKey)
        let lastSentAt = defaults.object(forKey: Self.lastSentAtKey) as? Date
        if signature == lastSignature,
           let lastSentAt,
           Date().timeIntervalSince(lastSentAt) < Self.minInterval {
            return
        }

        isSending = true
        defer { isSending = false }

        let params = ClientActivityParams(
            clientInstanceId: clientInstanceId,
            appType: "ios",
            platform: "ios",
            deviceFamily: family,
            deviceModel: AppBuildInfo.deviceModel,
            osName: UIDevice.current.systemName,
            osVersion: AppBuildInfo.iosVersion,
            appVersion: AppBuildInfo.version,
            appBuild: AppBuildInfo.buildNumber,
            vineyardId: vineyardId
        )

        do {
            _ = try await provider.client
                .rpc("record_my_client_activity", params: params)
                .execute()
            defaults.set(Date(), forKey: Self.lastSentAtKey)
            defaults.set(signature, forKey: Self.lastSignatureKey)
        } catch {
            // Best-effort: leave the throttle state untouched so the next
            // trigger retries. Never surface telemetry errors to the user.
            #if DEBUG
            print("[telemetry] heartbeat failed: \(error.localizedDescription)")
            #endif
        }
    }

    /// Clears user-linked throttle state on sign-out so the next account's
    /// first heartbeat is sent immediately. The installation ID is kept.
    func clearUserCache() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.lastSentAtKey)
        defaults.removeObject(forKey: Self.lastSignatureKey)
    }
}

nonisolated private struct ClientActivityParams: Encodable, Sendable {
    let clientInstanceId: UUID
    let appType: String
    let platform: String
    let deviceFamily: String
    let deviceModel: String
    let osName: String
    let osVersion: String
    let appVersion: String
    let appBuild: String
    let vineyardId: UUID?

    enum CodingKeys: String, CodingKey {
        case clientInstanceId = "p_client_instance_id"
        case appType          = "p_app_type"
        case platform         = "p_platform"
        case deviceFamily     = "p_device_family"
        case deviceModel      = "p_device_model"
        case osName           = "p_os_name"
        case osVersion        = "p_os_version"
        case appVersion       = "p_app_version"
        case appBuild         = "p_app_build"
        case vineyardId       = "p_vineyard_id"
    }
}
