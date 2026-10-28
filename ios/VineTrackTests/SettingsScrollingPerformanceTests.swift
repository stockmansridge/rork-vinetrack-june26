import XCTest
import SwiftUI
import UIKit
@testable import VineTrack

final class SettingsScrollingPerformanceTests: XCTestCase {
    @MainActor func testMountedSettingsInvalidationsAndLogoConstruction() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: dir))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 3000))
        let data = renderer.jpegData(withCompressionQuality: 0.9) { ctx in
            UIColor.green.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 3000))
        }
        let vineyard = Vineyard(name: "Synthetic Settings vineyard", logoData: data)
        store.vineyards = [vineyard]; store.selectedVineyardId = vineyard.id
        let auth = NewBackendAuthService()
        let subscription = SubscriptionService()
        let pin = PinSyncService()
        let home = BackendSettingsView().environment(store).environment(auth)
            .environment(BiometricAuthService()).environment(BackendAccessControl())
            .environment(subscription).environment(pin).environment(PaddockSyncService())
            .environment(TripSyncService()).environment(SprayRecordSyncService())
            .environment(ButtonConfigSyncService()).environment(SystemAdminService())
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        SettingsRenderProbe.reset()
        window.rootViewController = UIHostingController(rootView: home); window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(200))
        let initial = SettingsRenderProbe.rootBodies
        let initialImages = SettingsRenderProbe.imageConstructions
        for _ in 0..<8 {
            pin.lastSyncDate = Date()
            try await Task.sleep(for: .milliseconds(20))
        }
        let syncBodies = SettingsRenderProbe.rootBodies - initial
        for index in 0..<8 {
            auth.userName = "Synthetic operator \(index)"
            try await Task.sleep(for: .milliseconds(20))
        }
        let authBodies = SettingsRenderProbe.rootBodies - initial - syncBodies
        let report = "Settings baseline/current: initialBodies=\(initial) initialImageConstructions=\(initialImages) syncRootInvalidations=\(syncBodies) authRootInvalidations=\(authBodies) imageConstructions=\(SettingsRenderProbe.imageConstructions)"
        print(report)
        let attachment = XCTAttachment(string: report); attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertGreaterThan(initial, 0)
        XCTAssertEqual(syncBodies, 0, "Unrelated sync publications must not invalidate Settings root")
        XCTAssertEqual(authBodies, 0, report)
        XCTAssertEqual(SettingsRenderProbe.imageConstructions, 1, report)

        var updated = vineyard
        updated.logoData = renderer.jpegData(withCompressionQuality: 0.9) { ctx in
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 3000))
        }
        store.vineyards = [updated]
        for _ in 0..<40 where SettingsRenderProbe.imageConstructions < 2 { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(SettingsRenderProbe.imageConstructions, 2, "New logo bytes must prepare a new thumbnail")
        let other = Vineyard(name: "Other synthetic vineyard", logoData: data)
        store.vineyards = [updated, other]; store.selectedVineyardId = other.id
        for _ in 0..<40 where SettingsRenderProbe.imageConstructions < 3 { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(SettingsRenderProbe.imageConstructions, 3, "Vineyard switch must not retain the preceding thumbnail")
    }

    @MainActor func testThumbnailDownsamplesAndRejectsInvalidData() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 1500))
        let data = renderer.jpegData(withCompressionQuality: 0.9) { ctx in
            UIColor.green.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 1500))
        }
        let thumbnail = try XCTUnwrap(SettingsVineyardThumbnail.prepare(data))
        XCTAssertEqual(thumbnail.width, 120)
        XCTAssertEqual(thumbnail.height, 60)
        XCTAssertNil(SettingsVineyardThumbnail.prepare(Data("invalid image".utf8)))
    }
}
