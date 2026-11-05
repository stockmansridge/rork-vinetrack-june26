import Foundation
import CoreLocation
import Testing
@testable import VineTrack

@MainActor
struct YieldPermanentSiteContractTests {
    @Test func geometryRejectsOutsideAndAcceptsBoundary() {
        let square = [
            CoordinatePoint(latitude: -34.0, longitude: 149.0),
            CoordinatePoint(latitude: -34.0, longitude: 149.001),
            CoordinatePoint(latitude: -34.001, longitude: 149.001),
            CoordinatePoint(latitude: -34.001, longitude: 149.0),
        ]
        #expect(YieldSamplingSiteGeometry.contains(CLLocationCoordinate2D(latitude: -34.0005, longitude: 149.0005), polygon: square))
        #expect(YieldSamplingSiteGeometry.contains(CLLocationCoordinate2D(latitude: -34.0, longitude: 149.0005), polygon: square))
        #expect(!YieldSamplingSiteGeometry.contains(CLLocationCoordinate2D(latitude: -33.999, longitude: 149.0005), polygon: square))
        #expect(!YieldSamplingSiteGeometry.contains(CLLocationCoordinate2D(latitude: -34.0005, longitude: 150.0), polygon: square))
    }

    @Test func sessionCarriesPhysicalSiteIdentityAndFrozenRevision() throws {
        let vineyard = UUID(), block = UUID(), physical = UUID(), setKey = UUID(), versionID = UUID()
        let snapshot = YieldSamplingSiteSource(setKey: setKey, siteSetId: versionID, version: 4)
        let original = YieldEstimationSession(
            vineyardId: vineyard,
            selectedPaddockIds: [block],
            sampleSites: [SampleSite(id: physical, paddockId: block, rowNumber: 12,
                                     latitude: -34.001, longitude: 149.001, siteIndex: 1)],
            siteSetVersions: [block.uuidString.lowercased(): snapshot])
        let decoded = try JSONDecoder().decode(YieldEstimationSession.self, from: JSONEncoder().encode(original))
        #expect(decoded.siteSetVersions[block.uuidString.lowercased()] == snapshot)
        #expect(decoded.sampleSites[0].id == physical)
        #expect(decoded.sampleSites[0].latitude == original.sampleSites[0].latitude)
        let legacy = YieldEstimationSession(vineyardId: vineyard)
        #expect(try JSONDecoder().decode(YieldEstimationSession.self,
                                          from: JSONEncoder().encode(legacy)).siteSetVersions.isEmpty)
    }
}
