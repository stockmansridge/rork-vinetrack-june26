import Foundation
import Testing
@testable import VineTrack

@Suite @MainActor struct DiseaseGrowthStagePolicyTests {
    private let vineyard = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let blockA = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let blockB = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let now = ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")!

    private func record(_ id: String, _ block: UUID, _ code: String, _ date: String, updated: String? = nil, pin: UUID? = nil) -> GrowthStageRecord {
        GrowthStageRecord(id: UUID(uuidString: id)!, vineyardId: vineyard, paddockId: block, pinId: pin,
                          stageCode: code, stageLabel: code, variety: "Shiraz",
                          observedAt: ISO8601DateFormatter().date(from: date)!,
                          updatedAt: ISO8601DateFormatter().date(from: updated ?? date)!)
    }

    private var season: SeasonWindow {
        SeasonWindow.window(containing: now, seasonStartMonth: 7, seasonStartDay: 1, timeZone: .gmt)
    }

    private func resolve(_ rows: [GrowthStageRecord]) -> [DiseaseBlockStage] {
        DiseaseGrowthStagePolicy.resolve(records: rows, vineyardId: vineyard, season: season, now: now)
    }

    private func weather(_ model: DiseaseModel = .botrytis, _ severity: AlertSeverity? = .warning) -> DiseaseRiskAssessment {
        DiseaseRiskAssessment(model: model, severity: severity, title: "Risk", summary: "24 wet hours", usedMeasuredWetness: false)
    }

    @Test func missingOrLastVintageKeepsWeather() {
        let base = weather()
        #expect(DiseaseGrowthStagePolicy.adjust(base, stages: []).severity == base.severity)
        #expect(!DiseaseGrowthStagePolicy.changed(base, DiseaseGrowthStagePolicy.adjust(base, stages: [])))
        let old = record("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", blockA, "EL19", "2025-06-30T12:00:00Z", updated: "2026-09-25T09:00:00Z")
        #expect(resolve([old]).isEmpty)
        #expect(DiseaseGrowthStagePolicy.stageText(resolve([old])) == "No current-season observation")
    }

    @Test func observationTimeWinsOverEditsAndMirrorsAreSingleObservation() {
        let old = record("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", blockA, "EL19", "2025-06-30T12:00:00Z", updated: "2026-09-25T09:00:00Z")
        let pin = UUID()
        let first = record("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", blockA, "EL12", "2026-09-10T12:00:00Z", pin: pin)
        let latest = record("cccccccc-cccc-cccc-cccc-cccccccccccc", blockA, "EL19", "2026-09-20T12:00:00Z", pin: pin)
        #expect(resolve([old, first, latest]).map(\.el) == [19])
    }

    @Test func multipleBlocksKeepRangeAndConservativeSeverity() {
        let first = record("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", blockA, "EL19", "2026-09-10T12:00:00Z")
        let second = record("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", blockB, "EL23", "2026-09-20T12:00:00Z")
        let stages = resolve([second, first])
        #expect(stages.count == 2)
        #expect(DiseaseGrowthStagePolicy.stageText(stages) == "EL19–EL23")
        #expect(DiseaseGrowthStagePolicy.adjust(weather(), stages: stages).severity == .warning)
    }

    @Test func currentAndForecastWeatherUseSameHeldStage() {
        let stages = resolve([record("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", blockA, "EL12", "2026-09-10T12:00:00Z")])
        let hours = (0..<36).map { index in
            WeatherHour(date: now.addingTimeInterval(Double(index - 35) * 3600),
                        temperatureC: 20, dewPointC: 19, humidityPercent: 95,
                        precipitationMm: 1, measuredLeafWetness: nil)
        }
        let current = DiseaseRiskCalculator.botrytis(hours: hours, now: now)
        let future = DiseaseRiskCalculator.botrytis(hours: hours, now: now.addingTimeInterval(3600))
        #expect(current.severity == .critical)
        #expect(DiseaseGrowthStagePolicy.adjust(current, stages: stages).severity == .warning)
        #expect(DiseaseGrowthStagePolicy.adjust(future, stages: stages).severity == .warning)
    }

    @Test func parityFixtureAllDiseasesAndForecastHoldStageFixed() {
        let early = resolve([record("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", blockA, "EL12", "2026-09-10T12:00:00Z")])
        let flowering = resolve([record("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", blockA, "EL19", "2026-09-20T12:00:00Z")])
        let late = resolve([record("cccccccc-cccc-cccc-cccc-cccccccccccc", blockA, "EL33", "2026-09-20T12:00:00Z")])
        #expect(DiseaseGrowthStagePolicy.adjust(weather(.botrytis), stages: early).severity == nil)
        #expect(DiseaseGrowthStagePolicy.adjust(weather(.botrytis), stages: flowering).severity == .warning)
        #expect(DiseaseGrowthStagePolicy.adjust(weather(.botrytis), stages: late).severity == .warning)
        #expect(DiseaseGrowthStagePolicy.adjust(weather(.downyMildew), stages: early).severity == .warning)
        #expect(DiseaseGrowthStagePolicy.adjust(weather(.powderyMildew), stages: late).severity == .warning)
        #expect(DiseaseGrowthStagePolicy.adjust(weather(.downyMildew, .critical), stages: flowering).severity == .critical)
        // No phenological progression is inferred from future weather dates.
        #expect(DiseaseGrowthStagePolicy.adjust(weather(), stages: early).severity == nil)
        #expect(DiseaseGrowthStagePolicy.changed(weather(), DiseaseGrowthStagePolicy.adjust(weather(), stages: early)))
    }
}
