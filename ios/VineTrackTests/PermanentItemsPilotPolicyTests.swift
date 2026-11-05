import Foundation
import Testing
@testable import VineTrack

/// Issue #53: System Admin-only fixture pilot, isolated from ordinary Pins.
struct PermanentItemsPilotPolicyTests {
    /// Reproduces iOS cold-start regression: server permission lookup must
    /// be eligible immediately after auth+vineyard restore, even while the
    /// independent BackendAccessControl role cache is still loading.
    @Test func permanentItemLookupDoesNotRequireLocalRoleCache() {
        let actor = UUID()
        let vineyard = UUID()
        #expect(PermanentItemsPilotPolicy.mayCheckVineyardAccess(
            isSignedIn: true, userId: actor, vineyardId: vineyard))
        #expect(!PermanentItemsPilotPolicy.mayCheckVineyardAccess(
            isSignedIn: false, userId: actor, vineyardId: vineyard))
        #expect(!PermanentItemsPilotPolicy.mayCheckVineyardAccess(
            isSignedIn: true, userId: nil, vineyardId: vineyard))
        #expect(!PermanentItemsPilotPolicy.mayCheckVineyardAccess(
            isSignedIn: true, userId: actor, vineyardId: nil))
    }

    @Test func validatesFixtureNameTypeAndCoordinates() {
        #expect(PermanentItemsPilotPolicy.valid(name: "North Flush Valve", type: "flush_valve", latitude: -34, longitude: 138))
        #expect(!PermanentItemsPilotPolicy.valid(name: "  ", type: "pump", latitude: -34, longitude: 138))
        #expect(!PermanentItemsPilotPolicy.valid(name: "Valve", type: "repair", latitude: -34, longitude: 138))
        #expect(!PermanentItemsPilotPolicy.valid(name: "Valve", type: "pump", latitude: 91, longitude: 138))
        #expect(!PermanentItemsPilotPolicy.valid(name: "Valve", type: "pump", latitude: -34, longitude: 181))
        #expect(!PermanentItemsPilotPolicy.valid(name: "Valve", type: "pump", latitude: .nan, longitude: 138))
        #expect(PermanentItemsPilotPolicy.valid(name: "New Valve", type: "custom_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", latitude: -34, longitude: 138))
        #expect(!PermanentItemsPilotPolicy.valid(name: "Valve", type: "custom_invalid", latitude: -34, longitude: 138))
    }

    @Test func hardDeleteIsLimitedToVineyardSupervisorsManagersAndOwners() {
        #expect(PermanentItemsPilotPolicy.roleMayHardDelete(.owner))
        #expect(PermanentItemsPilotPolicy.roleMayHardDelete(.manager))
        #expect(PermanentItemsPilotPolicy.roleMayHardDelete(.supervisor))
        #expect(!PermanentItemsPilotPolicy.roleMayHardDelete(.operator))
        #expect(!PermanentItemsPilotPolicy.roleMayHardDelete(nil))
    }

    @Test func typeChoicesAreSeparateFromRepairAndYieldRecords() {
        let ids = PermanentItemsPilotPolicy.types.map { $0.id }
        #expect(ids.contains("irrigation_valve"))
        #expect(ids.contains("water_point"))
        #expect(!ids.contains("repair"))
        #expect(!ids.contains("yield_sample"))
        #expect(Set(PermanentItemsPilotPolicy.types.map { $0.hex }).count == ids.count)
        #expect(PermanentItemsPilotPolicy.hex("gate") == "#D97706")
        #expect(PermanentItemsPilotPolicy.label("water_point") == "Water Point")
    }
}
