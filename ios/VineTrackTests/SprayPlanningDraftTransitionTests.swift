import Foundation
import Testing
@testable import VineTrack

struct SprayPlanningDraftTransitionTests {
    private let us = RegionFormatter(settings: OrganizationRegionSettings(countryCode: "US", areaUnit: "acres", volumeUnit: "gallons", distanceUnit: "imperial", sprayRateAreaUnit: "acre"))

    @Test func completeEntriesRoundTripWithUnchangedPhysicalQuantities() throws {
        for raw in ["25.75", "0.75", "1250.5", "25,75", "0,75", "1250,5"] {
            let number = try #require(SprayEditingNumber.completeValue(raw))
            for basis in [SprayCarrierBasis.litresPerHectare, .litresPer100Metres] {
                let converted = try #require(SprayPlanningDraftTransition.convert(tank: raw, area: raw, rate: raw, from: .australian, to: us, basis: basis))
                let restored = try #require(SprayPlanningDraftTransition.convert(tank: converted.tank, area: converted.area, rate: converted.rate, from: us, to: .australian, basis: basis))
                for text in [restored.tank, restored.area, restored.rate] {
                    #expect(abs((Double(text) ?? -1) - number) < 0.000001)
                }
            }
        }
    }

    @Test func partialAndAmbiguousGroupsAreNeverPartiallyConverted() {
        for invalid in [".", ",", "25.", "25,", "25,7.5", "NaN", "inf", "--", "0", "-2"] {
            #expect(SprayPlanningDraftTransition.convert(tank: "600", area: invalid, rate: "600", from: .australian, to: us, basis: .litresPerHectare) == nil)
        }
    }

    @Test func chemicalDraftSurvivesSerializationWithoutBecomingAuthority() throws {
        var line = ChemicalLine(chemicalId: UUID(), selectedRateId: UUID(), overrideRate: 0)
        line.applicationRateDraft = "25,7.5"
        let restored = try JSONDecoder().decode(ChemicalLine.self, from: JSONEncoder().encode(line))
        #expect(restored.applicationRateDraft == "25,7.5")
        #expect(restored.overrideRate == 0)
        #expect(restored.selectedRateId == line.selectedRateId)
    }
}
