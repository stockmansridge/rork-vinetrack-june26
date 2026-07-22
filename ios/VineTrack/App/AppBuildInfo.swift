import Foundation
import UIKit

/// Single source of truth for the installed app's version, build and device
/// diagnostics. Always reads from the iOS bundle (`CFBundleShortVersionString`
/// = marketing version, `CFBundleVersion` = build number) so the values track
/// whatever Xcode injected from `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`
/// at build time. Never hardcode a version string — read it from here.
nonisolated enum AppBuildInfo {
    /// Display name (`CFBundleDisplayName`, falling back to `CFBundleName`).
    static var appName: String {
        infoValue("CFBundleDisplayName")
            ?? infoValue("CFBundleName")
            ?? "VineTrack"
    }

    /// Marketing version, e.g. "1.4.2". Driven by `MARKETING_VERSION`.
    static var version: String {
        infoValue("CFBundleShortVersionString") ?? "0.0"
    }

    /// Build number, e.g. "87". Driven by `CURRENT_PROJECT_VERSION`.
    static var buildNumber: String {
        infoValue("CFBundleVersion") ?? "0"
    }

    /// Human-readable version + build, e.g. "1.4.2 (87)".
    static var displayVersion: String {
        "\(version) (\(buildNumber))"
    }

    /// Full label including the app name, e.g. "VineTrack 1.4.2 (87)".
    static var fullDisplay: String {
        "\(appName) \(displayVersion)"
    }

    /// Bundle identifier, e.g. "app.rork.…vinetrack".
    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "unknown"
    }

    /// iOS version string, e.g. "18.2".
    static var iosVersion: String {
        UIDevice.current.systemVersion
    }

    /// Hardware model identifier, e.g. "iPhone16,2". Falls back to the generic
    /// `UIDevice` model name if the identifier can't be read.
    static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce("") { partial, element in
            guard let value = element.value as? Int8, value != 0 else { return partial }
            return partial + String(UnicodeScalar(UInt8(value)))
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }

    /// Best-effort build channel. Reliable only for Debug (compile flag) and
    /// TestFlight (sandbox receipt); otherwise reported as "App Store".
    static var buildChannel: String {
        #if DEBUG
        return "Debug"
        #else
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
            return "TestFlight"
        }
        return "App Store"
        #endif
    }

    private static func infoValue(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}
