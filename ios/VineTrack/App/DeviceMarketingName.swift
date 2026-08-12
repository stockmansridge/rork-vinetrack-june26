import Foundation

/// Maps Apple hardware identifiers (e.g. "iPhone18,1") to their marketing
/// names ("iPhone 17 Pro") so the System Admin User Activity page shows a
/// useful device value instead of a raw identifier.
///
/// Privacy: this is a static lookup over the public model identifier that
/// `uname()` already exposes — no serial numbers, IMEI, advertising IDs or
/// any per-device identifier are read. Unknown identifiers fall back to the
/// raw identifier, which is still meaningful for support.
nonisolated enum DeviceMarketingName {
    /// Resolves a hardware identifier to a display name.
    ///
    /// On the simulator, `uname()` reports the host architecture
    /// ("arm64"/"x86_64"); the simulated device's identifier is exposed via
    /// the `SIMULATOR_MODEL_IDENTIFIER` environment variable, so the result
    /// is still a real model name, suffixed with "(Simulator)".
    static func resolve(
        _ identifier: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "arm64" || trimmed == "x86_64" || trimmed == "i386" {
            if let simulated = environment["SIMULATOR_MODEL_IDENTIFIER"],
               !simulated.isEmpty {
                return "\(name(for: simulated) ?? simulated) (Simulator)"
            }
            return "Simulator"
        }
        return name(for: trimmed) ?? (trimmed.isEmpty ? identifier : trimmed)
    }

    /// Exact catalogue lookup; nil when the identifier is not known.
    static func name(for identifier: String) -> String? {
        catalogue[identifier]
    }

    /// Bounded catalogue: iPhone XS / iPad (2018-era) onwards — everything
    /// that can realistically run VineTrack (iOS 18+). New identifiers can be
    /// appended without touching the telemetry contract; unknown models fall
    /// back to the raw identifier.
    private static let catalogue: [String: String] = [
        // iPhone
        "iPhone11,2": "iPhone XS",
        "iPhone11,4": "iPhone XS Max",
        "iPhone11,6": "iPhone XS Max",
        "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11",
        "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd generation)",
        "iPhone13,1": "iPhone 12 mini",
        "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13",
        "iPhone14,6": "iPhone SE (3rd generation)",
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17 Pro",
        "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone18,3": "iPhone 17",
        "iPhone18,4": "iPhone Air",
        "iPhone18,5": "iPhone 17e",

        // iPad Pro
        "iPad8,1": "iPad Pro 11-inch",
        "iPad8,2": "iPad Pro 11-inch",
        "iPad8,3": "iPad Pro 11-inch",
        "iPad8,4": "iPad Pro 11-inch",
        "iPad8,5": "iPad Pro 12.9-inch (3rd generation)",
        "iPad8,6": "iPad Pro 12.9-inch (3rd generation)",
        "iPad8,7": "iPad Pro 12.9-inch (3rd generation)",
        "iPad8,8": "iPad Pro 12.9-inch (3rd generation)",
        "iPad8,9": "iPad Pro 11-inch (2nd generation)",
        "iPad8,10": "iPad Pro 11-inch (2nd generation)",
        "iPad8,11": "iPad Pro 12.9-inch (4th generation)",
        "iPad8,12": "iPad Pro 12.9-inch (4th generation)",
        "iPad13,4": "iPad Pro 11-inch (3rd generation)",
        "iPad13,5": "iPad Pro 11-inch (3rd generation)",
        "iPad13,6": "iPad Pro 11-inch (3rd generation)",
        "iPad13,7": "iPad Pro 11-inch (3rd generation)",
        "iPad13,8": "iPad Pro 12.9-inch (5th generation)",
        "iPad13,9": "iPad Pro 12.9-inch (5th generation)",
        "iPad13,10": "iPad Pro 12.9-inch (5th generation)",
        "iPad13,11": "iPad Pro 12.9-inch (5th generation)",
        "iPad14,3": "iPad Pro 11-inch (4th generation)",
        "iPad14,4": "iPad Pro 11-inch (4th generation)",
        "iPad14,5": "iPad Pro 12.9-inch (6th generation)",
        "iPad14,6": "iPad Pro 12.9-inch (6th generation)",
        "iPad16,3": "iPad Pro 11-inch (M4)",
        "iPad16,4": "iPad Pro 11-inch (M4)",
        "iPad16,5": "iPad Pro 13-inch (M4)",
        "iPad16,6": "iPad Pro 13-inch (M4)",

        // iPad Air
        "iPad11,3": "iPad Air (3rd generation)",
        "iPad11,4": "iPad Air (3rd generation)",
        "iPad13,1": "iPad Air (4th generation)",
        "iPad13,2": "iPad Air (4th generation)",
        "iPad13,16": "iPad Air (5th generation)",
        "iPad13,17": "iPad Air (5th generation)",
        "iPad14,8": "iPad Air 11-inch (M2)",
        "iPad14,9": "iPad Air 11-inch (M2)",
        "iPad14,10": "iPad Air 13-inch (M2)",
        "iPad14,11": "iPad Air 13-inch (M2)",
        "iPad15,3": "iPad Air 11-inch (M3)",
        "iPad15,4": "iPad Air 11-inch (M3)",
        "iPad15,5": "iPad Air 13-inch (M3)",
        "iPad15,6": "iPad Air 13-inch (M3)",

        // iPad
        "iPad11,6": "iPad (8th generation)",
        "iPad11,7": "iPad (8th generation)",
        "iPad12,1": "iPad (9th generation)",
        "iPad12,2": "iPad (9th generation)",
        "iPad13,18": "iPad (10th generation)",
        "iPad13,19": "iPad (10th generation)",
        "iPad15,7": "iPad (A16)",
        "iPad15,8": "iPad (A16)",

        // iPad mini
        "iPad11,1": "iPad mini (5th generation)",
        "iPad11,2": "iPad mini (5th generation)",
        "iPad14,1": "iPad mini (6th generation)",
        "iPad14,2": "iPad mini (6th generation)",
        "iPad16,1": "iPad mini (A17 Pro)",
        "iPad16,2": "iPad mini (A17 Pro)",
    ]
}
