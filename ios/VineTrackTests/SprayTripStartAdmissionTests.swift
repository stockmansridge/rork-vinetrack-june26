import XCTest
@testable import VineTrack

final class SprayTripStartAdmissionTests: XCTestCase {
    @MainActor func testGenericSprayWithoutRecipeIsBlocked() {
        XCTAssertNotNil(SprayTripStartAdmission.blocker(isSpray: true, vineyardId: UUID(), record: nil))
    }
    @MainActor func testNonSprayTrackingIsUnaffected() {
        XCTAssertNil(SprayTripStartAdmission.blocker(isSpray: false, vineyardId: UUID(), record: nil))
    }
    @MainActor func testValidatedLegacyRecipeIsEligibleButWrongScopeIsNot() {
        let vineyard = UUID()
        let chemical = SprayChemical(name: "Fixture", volumePerTank: 1000, ratePerHa: 1000, unit: .grams)
        let record = SprayRecord(vineyardId: vineyard, tanks: [SprayTank(tankNumber: 1, waterVolume: 420, chemicals: [chemical])])
        XCTAssertNil(SprayTripStartAdmission.blocker(isSpray: true, vineyardId: vineyard, record: record))
        XCTAssertNotNil(SprayTripStartAdmission.blocker(isSpray: true, vineyardId: UUID(), record: record))
    }
    @MainActor func testPlanningAndComplianceDenialCannotAuthoriseNewTrip() {
        let vineyard = UUID()
        var geometry = SprayApplicationSnapshot()
        geometry.planningIntent = SprayPlanningIntent(configuration: .overRow, method: .fullTank)
        let record = SprayRecord(vineyardId: vineyard, applicationGeometry: geometry)
        XCTAssertNotNil(SprayTripStartAdmission.blocker(isSpray: true, vineyardId: vineyard, record: record))
        var template = SprayRecord(vineyardId: vineyard)
        template.isTemplate = true
        XCTAssertNotNil(SprayTripStartAdmission.blocker(isSpray: true, vineyardId: vineyard, record: template))
    }
}
