import XCTest
@testable import VineTrack

/// Contract tests for the SQL 154 client telemetry heartbeat:
/// canonical app/platform values, RPC parameter names, marketing device
/// names, and bundle-driven app version/build.
final class ClientTelemetryContractTests: XCTestCase {

    // MARK: - Device marketing names

    func testKnownIphoneIdentifiersMapToMarketingNames() {
        XCTAssertEqual(DeviceMarketingName.resolve("iPhone18,1"), "iPhone 17 Pro")
        XCTAssertEqual(DeviceMarketingName.resolve("iPhone18,2"), "iPhone 17 Pro Max")
        XCTAssertEqual(DeviceMarketingName.resolve("iPhone18,3"), "iPhone 17")
        XCTAssertEqual(DeviceMarketingName.resolve("iPhone18,4"), "iPhone Air")
        XCTAssertEqual(DeviceMarketingName.resolve("iPhone17,1"), "iPhone 16 Pro")
        XCTAssertEqual(DeviceMarketingName.resolve("iPhone16,2"), "iPhone 15 Pro Max")
        XCTAssertEqual(DeviceMarketingName.resolve("iPhone12,8"), "iPhone SE (2nd generation)")
    }

    func testKnownIpadIdentifiersMapToMarketingNames() {
        XCTAssertEqual(DeviceMarketingName.resolve("iPad16,3"), "iPad Pro 11-inch (M4)")
        XCTAssertEqual(DeviceMarketingName.resolve("iPad14,11"), "iPad Air 13-inch (M2)")
        XCTAssertEqual(DeviceMarketingName.resolve("iPad13,19"), "iPad (10th generation)")
        XCTAssertEqual(DeviceMarketingName.resolve("iPad16,1"), "iPad mini (A17 Pro)")
    }

    func testUnknownIdentifierFallsBackToRawIdentifier() {
        // A future device must never become "Unknown" — the raw identifier
        // is still meaningful for support.
        XCTAssertEqual(DeviceMarketingName.resolve("iPhone99,9"), "iPhone99,9")
        XCTAssertEqual(DeviceMarketingName.resolve("iPad99,9"), "iPad99,9")
    }

    func testSimulatorIdentifierResolvesViaEnvironment() {
        let env = ["SIMULATOR_MODEL_IDENTIFIER": "iPhone17,1"]
        XCTAssertEqual(
            DeviceMarketingName.resolve("arm64", environment: env),
            "iPhone 16 Pro (Simulator)"
        )
        XCTAssertEqual(
            DeviceMarketingName.resolve("x86_64", environment: [:]),
            "Simulator"
        )
    }

    func testResolveNeverReturnsEmpty() {
        XCTAssertFalse(DeviceMarketingName.resolve("").isEmpty)
        XCTAssertFalse(DeviceMarketingName.resolve("   ").isEmpty)
    }

    // MARK: - Heartbeat payload contract

    func testPayloadUsesExactRpcParameterNamesAndCanonicalValues() throws {
        let vineyard = UUID()
        let params = ClientActivityParams(
            clientInstanceId: UUID(),
            appType: "ios",
            platform: "ios",
            deviceFamily: "iPhone",
            deviceModel: "iPhone 17 Pro",
            osName: "iOS",
            osVersion: "19.1",
            appVersion: "2.8.9",
            appBuild: "35",
            vineyardId: vineyard
        )
        let data = try JSONEncoder().encode(params)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        // Exact RPC parameter names from record_my_client_activity (SQL 154).
        XCTAssertEqual(json["p_app_type"] as? String, "ios")
        XCTAssertEqual(json["p_platform"] as? String, "ios")
        XCTAssertEqual(json["p_device_family"] as? String, "iPhone")
        XCTAssertEqual(json["p_device_model"] as? String, "iPhone 17 Pro")
        XCTAssertEqual(json["p_os_name"] as? String, "iOS")
        XCTAssertEqual(json["p_os_version"] as? String, "19.1")
        XCTAssertEqual(json["p_app_version"] as? String, "2.8.9")
        XCTAssertEqual(json["p_app_build"] as? String, "35")
        XCTAssertEqual(json["p_vineyard_id"] as? String, vineyard.uuidString)
        XCTAssertNotNil(json["p_client_instance_id"])

        // Nothing beyond the documented contract — no extra identifiers.
        let allowed: Set<String> = [
            "p_client_instance_id", "p_app_type", "p_platform",
            "p_device_family", "p_device_model", "p_os_name", "p_os_version",
            "p_app_version", "p_app_build", "p_vineyard_id",
        ]
        XCTAssertTrue(Set(json.keys).isSubset(of: allowed),
                      "unexpected telemetry fields: \(Set(json.keys).subtracting(allowed))")
    }

    // MARK: - App version / build source

    func testAppVersionAndBuildComeFromBundleAndAreNonEmpty() {
        XCTAssertFalse(AppBuildInfo.version.isEmpty)
        XCTAssertFalse(AppBuildInfo.buildNumber.isEmpty)
        // Marketing version looks like "2.8.9", never a build-channel string.
        XCTAssertNotNil(AppBuildInfo.version.range(
            of: #"^\d+(\.\d+)*$"#, options: .regularExpression))
    }
}
