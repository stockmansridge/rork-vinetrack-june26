import Testing
@testable import VineTrack

/// Issue #53: System Admin-only fixture pilot, isolated from ordinary Pins.
struct PermanentItemsPilotPolicyTests {
    @Test func validatesFixtureNameTypeAndCoordinates() {
        #expect(PermanentItemsPilotPolicy.valid(name: "North Flush Valve", type: "flush_valve", latitude: -34, longitude: 138))
        #expect(!PermanentItemsPilotPolicy.valid(name: "  ", type: "pump", latitude: -34, longitude: 138))
        #expect(!PermanentItemsPilotPolicy.valid(name: "Valve", type: "repair", latitude: -34, longitude: 138))
        #expect(!PermanentItemsPilotPolicy.valid(name: "Valve", type: "pump", latitude: 91, longitude: 138))
        #expect(!PermanentItemsPilotPolicy.valid(name: "Valve", type: "pump", latitude: -34, longitude: 181))
        #expect(!PermanentItemsPilotPolicy.valid(name: "Valve", type: "pump", latitude: .nan, longitude: 138))
    }

    @Test func typeChoicesAreSeparateFromRepairAndYieldRecords() {
        let ids = PermanentItemsPilotPolicy.types.map { $0.id }
        #expect(ids.contains("irrigation_valve"))
        #expect(ids.contains("water_point"))
        #expect(!ids.contains("repair"))
        #expect(!ids.contains("yield_sample"))
    }
}
