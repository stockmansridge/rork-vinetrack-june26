import Foundation
import Testing
@testable import VineTrack

@MainActor struct TargetNutrientTests {
    private func draft(_ percent: String = "16", target: String = "2") -> TargetNutrient.Draft {
        var d = TargetNutrient.Draft(); d.percent = percent; d.target = target; return d
    }
    @Test func portalSolidExamplesAndCanonicalTotals() {
        let n = TargetNutrient.calculate(draft(), liquid: false, vines: 1000, areaHa: 1)
        #expect(n.rate == 12.5); #expect(n.totalProduct == 12.5); #expect(n.totalNutrientKg == 2); #expect(n.issues.isEmpty)
        var ca = draft("20"); ca.selectNutrient("Ca"); ca.analysisBasis = "elemental"
        #expect(TargetNutrient.calculate(ca, liquid: false, vines: 1000, areaHa: 1).rate == 10)
    }
    @Test func liquidWeightVolumeNeedsNoDensity() {
        var d = draft(); d.concentrationBasis = "w/v"
        let r = TargetNutrient.calculate(d, liquid: true, vines: 1000, areaHa: 1)
        #expect(r.rate == 12.5); #expect(r.rateUnit == "mL/vine"); #expect(r.totalProduct == 12.5); #expect(r.productUnit == "L"); #expect(r.issues.isEmpty)
    }
    @Test func liquidWeightWeightRequiresDocumentedDensity() {
        var d = draft(); d.concentrationBasis = "w/w"
        let mass = TargetNutrient.calculate(d, liquid: true, vines: 1000, areaHa: 1)
        #expect(mass.rate == nil); #expect(mass.totalProduct == 12.5); #expect(mass.productUnit == "kg"); #expect(!mass.issues.isEmpty)
        d.density = "1.25"
        #expect(TargetNutrient.calculate(d, liquid: true, vines: 1000, areaHa: 1).rate == nil)
        d.densityReference = "Synthetic technical sheet"
        let volume = TargetNutrient.calculate(d, liquid: true, vines: 1000, areaHa: 1)
        #expect(volume.rate == 10); #expect(volume.totalProduct == 10); #expect(volume.productUnit == "L")
        for value in ["0", "-1", "NaN", "Infinity"] { d.density = value; #expect(TargetNutrient.calculate(d, liquid: true, vines: 1000, areaHa: 1).rate == nil) }
    }
    @Test func hectareAndRegionalManualArea() {
        var d = draft(); d.perVine = false
        let r = TargetNutrient.calculate(d, liquid: false, vines: nil, areaHa: 2.5)
        #expect(r.rate == 12.5); #expect(r.rateUnit == "kg/ha"); #expect(r.totalProduct == 31.25); #expect(r.totalNutrientKg == 5)
        let fmt = RegionFormatter(settings: OrganizationRegionSettings(areaUnit: "acres"))
        let ha = fmt.areaToCanonical(fmt.areaValue(hectares: 2.5))
        #expect(TargetNutrient.calculate(d, liquid: false, vines: nil, areaHa: ha).totalProduct == 31.25)
    }
    @Test func switchingNutrientsPreservesPercentAndTargetButNotOxideIdentity() {
        var d = draft("20,5", target: "3")
        for key in TargetNutrient.nutrients.map(\.key) {
            d.selectNutrient(key); #expect(d.percent == "20,5"); #expect(d.target == "3")
            if TargetNutrient.oxideKeys.contains(key) { #expect(d.analysisBasis == "unknown") }
        }
    }
    @Test func oxideUnknownAndSolidWeightVolumeNeverBecomeElemental() {
        for basis in ["oxide", "unknown"] {
            var d = draft(); d.analysisBasis = basis
            let r = TargetNutrient.calculate(d, liquid: false, vines: 1000, areaHa: 1)
            #expect(r.rate == nil); #expect(r.totalProduct == nil); #expect(r.totalNutrientKg == nil)
        }
        var d = draft(); d.concentrationBasis = "unknown"
        #expect(TargetNutrient.calculate(d, liquid: true, vines: 1000, areaHa: 1).totalProduct == nil)
        d.concentrationBasis = "w/v"
        #expect(TargetNutrient.calculate(d, liquid: false, vines: 1000, areaHa: 1).rate == nil)
    }
    @Test func invalidInputsAndMissingQuantity() {
        for text in ["", "0", "-1", "101", "NaN", "Infinity", "1,2.3"] {
            #expect(TargetNutrient.calculate(draft(text), liquid: false, vines: 1000, areaHa: 1).rate == nil)
        }
        let r = TargetNutrient.calculate(draft(), liquid: false, vines: nil, areaHa: nil)
        #expect(r.rate == 12.5); #expect(r.totalProduct == nil)
        var other = draft(); other.selectNutrient("other"); other.analysisBasis = "elemental"
        #expect(TargetNutrient.calculate(other, liquid: false, vines: 1000, areaHa: 1).rate == nil)
        other.otherName = "Custom nutrient"
        #expect(TargetNutrient.calculate(other, liquid: false, vines: 1000, areaHa: 1).rate == 12.5)
    }
    @Test func existingBlockVineAuthorityDrivesLiveTotals() {
        let blocks = [Paddock(name: "A", vineSpacing: 2, vineCountOverride: 4200, rowLengthOverride: 10000), Paddock(name: "B", vineSpacing: 2, vineCountOverride: 3600, rowLengthOverride: 8000)]
        let actual = TargetNutrient.calculate(draft(), liquid: false, vines: FertiliserVineCounts.total(blocks, basis: "actual"), areaHa: nil)
        let assumed = TargetNutrient.calculate(draft(), liquid: false, vines: FertiliserVineCounts.total(blocks, basis: "assumed_full"), areaHa: nil)
        #expect(actual.totalProduct == 97.5); #expect(actual.totalNutrientKg == 15.6)
        #expect(assumed.totalProduct == 112.5); #expect(assumed.totalNutrientKg == 18)
    }
    @Test func accessAndSavingAreIndependent() {
        #expect(TargetNutrient.canPreview(isSystemAdmin: true)); #expect(!TargetNutrient.canPreview(isSystemAdmin: false))
        for mode in ["nutrientTarget", "fertigation", "future", ""] { #expect(!TargetNutrient.canSave(mode: mode)) }
        #expect(TargetNutrient.canSave(mode: "perHectare")); #expect(TargetNutrient.canSave(mode: "perVine"))
    }
    @Test func existingModesStillSaveCompleteAndDeleteWithoutChangingQuantities() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fertiliser-legacy-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FertiliserStore(persistence: PersistenceStore(directory: directory))
        for mode in FertiliserCalcMode.allCases {
            let record = FertiliserRecord(vineyardId: UUID(), status: .planned, mode: mode, productName: "Legacy fixture", form: .solid, paddockIds: [], blockNames: [], areaHectares: 2, vineCount: 1000, rate: 10, totalProduct: 20)
            store.addRecord(record); #expect(store.records.first?.mode == mode)
            store.markCompleted(id: record.id)
            #expect(store.records.first?.status == .completed); #expect(store.records.first?.totalProduct == 20)
            store.deleteRecord(id: record.id); #expect(store.records.isEmpty)
        }
    }
    @Test func unsupportedLocalMutationsLeaveOriginalFileAndSyncHooksUntouched() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nutrient-store-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FertiliserStore(persistence: PersistenceStore(directory: directory))
        let timestamp = Date(timeIntervalSince1970: 1_792_281_600)
        let record = FertiliserRecord(vineyardId: UUID(), date: timestamp, status: .planned, mode: .init(rawValue: "nutrientTarget"), productName: "Synthetic retained target", form: .solid, paddockIds: [], blockNames: [], areaHectares: 1, vineCount: 1000, rate: 12.5, totalProduct: 12.5, createdAt: timestamp)
        store.applyRemoteRecordUpsert(record)
        let file = directory.appendingPathComponent("vinetrack_fertiliser_records_v2.json")
        let originalBytes = try Data(contentsOf: file)
        var hooks = 0
        store.onRecordChanged = { _ in hooks += 1 }; store.onRecordDeleted = { _ in hooks += 1 }
        store.markCompleted(id: record.id); store.deleteRecord(id: record.id)
        store.addRecord(record)
        var downgrade = record; downgrade.mode = .perHectare
        store.addRecord(downgrade)
        #expect(store.records == [record]); #expect(hooks == 0)
        #expect(try Data(contentsOf: file) == originalBytes)
        #expect(FertiliserStore(persistence: PersistenceStore(directory: directory)).records == [record])
    }
    @Test func unsupportedRemoteAndOfflineSnapshotRemainReadOnly() throws {
        for mode in ["nutrientTarget", "fertigation", "future"] {
            let raw = """
            {"id":"00000000-0000-0000-0000-000000000001","vineyard_id":"00000000-0000-0000-0000-000000000002","calculation_mode":"\(mode)","application_rate":12.5,"application_rate_unit":"g/vine","product_unit":"kg","nutrient_key":"Ca","nutrient_percent":20,"analysis_basis":"oxide","product_analysis_snapshot":{"schema_version":1,"nutrients":[{"nutrient_key":"Ca","percent":20,"analysis_basis":"oxide"}]}}
            """
            let backend = try JSONDecoder().decode(BackendFertiliserRecord.self, from: Data(raw.utf8))
            let record = backend.toFertiliserRecord(allocations: [])
            #expect(record.mode.rawValue == mode); #expect(!record.mode.isSupported); #expect(record.rateUnit == "g/vine")
            let restored = try JSONDecoder().decode(FertiliserRecord.self, from: JSONEncoder().encode(record))
            #expect(restored == record); #expect(restored.unsupportedSnapshot?.productAnalysisSnapshot == backend.productAnalysisSnapshot)
        }
    }
}
