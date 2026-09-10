import Foundation
import Testing

/// Guards the Pins-map Follow Me source contract without changing location services.
struct PinsMapFollowMeContractTests {
    private func source(relativeToIOS path: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let iosDirectory = testsDirectory.deletingLastPathComponent()
        return try String(contentsOf: iosDirectory.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func onlineFollowPreservesCameraAndLifecycle() throws {
        let source = try source(relativeToIOS: "VineTrack/LegacyImported/Views/Pins/PinsView.swift")
        let follow = source.components(separatedBy: "private func followFreshLocationIfAvailable()").last ?? ""

        #expect(source.contains("Text(\"Follow Me\")"))
        #expect(follow.contains("distance: camera?.distance"))
        #expect(follow.contains("heading: camera?.heading"))
        #expect(source.contains("scenePhase == .active"))
        #expect(source.contains("isFollowingUser = false\n            isFollowWaiting = false"))
    }

    @Test func offlineFollowPreservesZoomAndPanCancels() throws {
        let source = try source(relativeToIOS: "VineTrack/LegacyImported/Views/Components/OfflineVineyardMapView.swift")
        let follow = source.components(separatedBy: "private func centreOnUser(maximumZoom: Bool)").last ?? ""

        #expect(source.contains("var isFollowingUser: Bool = false"))
        #expect(source.contains("if isFollowingUser { centreOnUser(maximumZoom: false) }"))
        #expect(follow.contains("let targetScale = maximumZoom ? Self.maximumScale : committedScale"))
        #expect(source.contains("onManualPan()"))
    }

    @Test func refreshAndCurrentLocationContractsRemainOwned() throws {
        let source = try source(relativeToIOS: "VineTrack/LegacyImported/Views/Pins/PinsView.swift")

        #expect(source.contains("!isFollowingUser,\n              !hasSetInitialPosition"))
        #expect(source.contains("!isFollowingUser,\n                  newCount > 0"))
        #expect(source.contains("distance: Self.closestOnlineCameraDistance"))
    }
}
