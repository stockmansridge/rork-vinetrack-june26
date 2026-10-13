import Foundation
import Testing
import Supabase
@testable import VineTrack

private final class ChemicalAcceptanceBundle {}

/// Full captured REST row shape and evidence; only scope/audit identities redacted. No live writes.
@Suite @MainActor
struct ProductionChemicalStructureTests {
    private func chemicals() throws -> [SavedChemical] {
        let url = try #require(Bundle(for: ChemicalAcceptanceBundle.self).url(forResource: "production_chemical_registered_uses", withExtension: "json"))
        return try PostgrestClient.Configuration.jsonDecoder.decode([BackendSavedChemical].self, from: Data(contentsOf: url)).map { $0.toSavedChemical() }
    }

    @Test func unresolvedConcentrationUnitsSurviveWithoutInterpretation() throws {
        let cropSil = try chemicals()[0]
        let actives = try #require(cropSil.chemicalIntelligence?.activeIngredients)
        #expect(actives[0].concentrationUnit == nil && actives[1].concentrationUnit == nil)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(actives)) as? [[String: Any]])
        #expect(encoded[0]["concentration_unit"] as? String == "% (±1%)")
        #expect(encoded[1]["concentration_unit"] as? String == "%")
    }

    @Test func competingFixedRatesRequireExplicitChoice() throws {
        let revus = try chemicals()[1]
        let rates = SprayRegisteredUseRates.vineyardRates(for: revus)
        #expect(rates.map(\.displayText) == ["40 mL/100 L", "60 mL/100 L"])
        #expect(rates.map { $0.seed.seedableValue } == [40, 60])
        #expect(Set(rates.map(\.id)).count == 2)
        #expect(rates.allSatisfy { $0.menuText.contains($0.registeredRate!.condition!) })
        #expect(SprayRegisteredUseRates.defaultSelection(for: revus, preferring: .per100Litres) == nil)
        let line = SprayConfirmedRateSeeding.seededLine(for: revus, preferring: [.per100Litres], fallbackBasis: .per100Litres)
        #expect(SprayRegisteredUseRates.seedValue(for: revus, rateId: line.selectedRateId, basis: line.basis) == nil)
    }

    @Test func incompatibleProductUnitRequiresReviewWithoutConversion() throws {
        let dipel = try chemicals()[2]
        #expect(dipel.unit == .litres)
        let original = try #require(dipel.chemicalIntelligence?.registeredUses.first)
        #expect(original.rates.map(\.unit) == ["kg/ha", "g/100 L", "g/100L"])
        #expect(original.rates.map(\.condition) == [nil, "Dilute Spraying (to the point of run-off)", "Concentrate Spraying"])
        let rates = SprayRegisteredUseRates.vineyardRates(for: dipel)
        #expect(rates.count == 3)
        #expect(rates.map(\.displayText) == ["0.5–2 kg/ha", "25–100 g/100 L", "100–1000 g/100 L"])
        #expect(rates.allSatisfy { !$0.isSelectable && $0.seed.seedableValue == nil })
        #expect(SprayRegisteredUseRates.hasInvalidStructuredRates(dipel))
        #expect(SprayRegisteredUseRates.productUnitReviewMessage(dipel)?.contains("Independent review required") == true)
        #expect(SprayRegisteredUseRates.productUnitReviewMessage(dipel)?.contains("Litres") == true)
    }

    @Test(arguments: [0, 1, 2]) func capturedUsesSurviveCacheEditorAndWire(_ index: Int) throws {
        let chemical = try chemicals()[index]
        let uses = try #require(chemical.chemicalIntelligence?.registeredUses)
        #expect(uses[0].unknownFields["method"] != nil)
        #expect(uses[0].unknownFields["targets"] != nil)
        #expect(uses[0].unknownFields["withholding_statement"] != nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        SprayRepository(persistence: PersistenceStore(directory: directory)).saveChemicalsSlice([chemical], for: chemical.vineyardId)
        var reopened = try #require(SprayRepository(persistence: PersistenceStore(directory: directory)).loadChemicals(for: chemical.vineyardId).first)
        #expect(reopened.chemicalIntelligence?.registeredUses == uses)
        let before = SprayRegisteredUseRates.vineyardRates(for: chemical)
        #expect(SprayRegisteredUseRates.vineyardRates(for: reopened) == before)
        var draft = ChemicalManualEntry.draft(from: reopened, fallbackCountry: "AU")
        draft.productName = "Unrelated display edit"
        reopened.chemicalIntelligence = ChemicalManualEntry.proposedIntelligence(from: draft, existing: reopened.chemicalIntelligence)
        #expect(reopened.chemicalIntelligence?.registeredUses == uses)
        #expect(reopened.unit == chemical.unit)
        if index == 0 {
            #expect(reopened.chemicalIntelligence?.activeIngredients.map(\.unresolvedConcentrationUnit) == ["% (±1%)", "%", nil, nil])
            #expect(SprayRegisteredUseRates.concentrationUnitReviewMessage(reopened) != nil)
        }
        let body = try JSONEncoder().encode(BackendSavedChemical.upsert(from: reopened, createdBy: nil, clientUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let transmitted = try JSONDecoder().decode([ChemicalRegisteredUse].self, from: JSONSerialization.data(withJSONObject: try #require(object["registered_uses"])))
        #expect(transmitted == uses)
        #expect(object["unit"] as? String == "Litres")
        if index == 0 {
            #expect(before.count == 8)
            #expect(before.filter { !$0.isRangePreset }.map(\.condition) == ["Monthly as required", "If using high volumes of water for foliar sprays"])
            #expect(before.filter { !$0.isRangePreset }.map { $0.registeredRate?.rawText } == ["3-5L", "500-1000mls/100L water"])
        }
    }

    @Test(arguments: [0, 1]) func diskRecreationAndOfflineReplayRetainFrozenChoices(_ index: Int) async throws {
        let chemical = try chemicals()[index]
        let choices = SprayRegisteredUseRates.vineyardRates(for: chemical).filter {
            $0.seed.seedableValue != nil && ($0.preset == .midpoint || $0.preset == nil)
        }
        #expect(choices.count == 2)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var tanks: [SprayTank] = []
        for chosen in choices {
            let value = try #require(chosen.seed.seedableValue)
            let basis: SprayProductRateBasis = chosen.basis == .perHectare ? .wholeBlockArea : .per100Litres
            let context = SprayQuantityContext(grossAreaHectares: 6, treatedAreaHectares: nil, carrierLitres: 1200, concentrationFactor: 1, rowLengthMetres: nil)
            let total = try #require(SprayProductQuantityCalculator.totalQuantity(rate: value, basis: basis, context: context))
            let line = ChemicalLine(chemicalId: chemical.id, selectedRateId: chosen.id, basis: try #require(chosen.basis))
            let plan = SprayProductLineResult(productId: chemical.id.uuidString, name: chemical.name, unit: "mL", basis: basis, rate: value,
                totalQuantity: total, quantityPerFullTank: total, quantityInLastTank: total, costPerUnit: nil, basisInput: chosen.basis == .perHectare ? 6 : 1200)
            let frozen = try #require(SprayConfirmedRateSeeding.snapshot(base: nil, chemical: chemical, line: line, planLine: plan, at: date))
            #expect(frozen.registeredRate == chosen.registeredRate && frozen.registeredUse == chosen.registeredUse)
            tanks.append(SprayTank(waterVolume: 1200, concentrationFactor: 1, chemicals: [SprayChemical(name: chemical.name,
                volumePerTank: total, unit: .litres, rateBasis: basis, savedChemicalId: chemical.id, chemicalSnapshot: frozen)]))
        }
        var record = SprayRecord(date: date, startTime: date, tanks: tanks)
        record.vineyardId = chemical.vineyardId
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let originalStore = MigratedDataStore(persistence: persistence)
        originalStore.selectedVineyardId = record.vineyardId
        originalStore.applyRemoteSprayRecordUpsert(record)
        let metadata = SprayRecordSyncMetadata(persistence: persistence)
        metadata.markDirty(record.id, at: date)
        let transport = ChemicalEvidenceReplayRepository()
        let auth = NewBackendAuthService()
        let first = SprayRecordSyncService(repository: transport, metadata: metadata)
        first.configure(store: originalStore, auth: auth)
        do { try await first.pushLocalSprayRecords(vineyardId: record.vineyardId); Issue.record("Offline replay reported success") }
        catch let error as URLError { #expect(error.code == .notConnectedToInternet) }
        let reopenedPersistence = PersistenceStore(directory: directory)
        #expect(SprayRepository(persistence: reopenedPersistence).loadRecords(for: record.vineyardId).first == record)
        let retained = SprayRecordSyncMetadata(persistence: reopenedPersistence)
        #expect(retained.pendingUpserts[record.id] == date && retained.isUpsertFailed(record.id))
        let reopenedStore = MigratedDataStore(persistence: reopenedPersistence)
        reopenedStore.selectedVineyardId = record.vineyardId
        reopenedStore.applyRemoteSprayRecordUpsert(try #require(SprayRepository(persistence: reopenedPersistence).loadRecords(for: record.vineyardId).first))
        transport.isOffline = false
        let replay = SprayRecordSyncService(repository: transport, metadata: retained)
        replay.configure(store: reopenedStore, auth: auth)
        try await replay.pushLocalSprayRecords(vineyardId: record.vineyardId)
        #expect(transport.deliveries.count == 1)
        #expect(transport.deliveries.first?.tanks == record.tanks)
        #expect(SprayRecordSyncMetadata(persistence: reopenedPersistence).pendingUpserts.isEmpty)
        try await replay.pushLocalSprayRecords(vineyardId: record.vineyardId)
        #expect(transport.deliveries.count == 1)
    }

    @Test(arguments: [40.0, 60.0]) func explicitRevusChoiceFreezesOriginalEvidence(_ value: Double) throws {
        let revus = try chemicals()[1]
        let chosen = try #require(SprayRegisteredUseRates.vineyardRates(for: revus).first { $0.seed.seedableValue == value })
        let line = ChemicalLine(chemicalId: revus.id, selectedRateId: chosen.id, basis: .per100Litres)
        #expect(SprayRegisteredUseRates.seedValue(for: revus, rateId: line.selectedRateId, basis: line.basis) == value)
        let result = SprayProductLineResult(productId: revus.id.uuidString, name: revus.name, unit: "mL", basis: .per100Litres, rate: value, totalQuantity: value * 12, quantityPerFullTank: value * 12, quantityInLastTank: value * 12, costPerUnit: nil, basisInput: 1200)
        let frozen = try #require(SprayConfirmedRateSeeding.snapshot(base: nil, chemical: revus, line: line, planLine: result, at: Date(timeIntervalSince1970: 1_800_000_000)))
        let record = SprayRecord(tanks: [SprayTank(waterVolume: 1200, concentrationFactor: 1, chemicals: [SprayChemical(name: revus.name, volumePerTank: value * 12, unit: .litres, rateBasis: .per100Litres, savedChemicalId: revus.id, chemicalSnapshot: frozen)])])
        let reopened = try JSONDecoder().decode(SprayRecord.self, from: JSONEncoder().encode(record))
        #expect(reopened.tanks[0].chemicals[0].chemicalSnapshot == frozen)
        #expect(frozen.registeredRate == chosen.registeredRate)
        #expect(frozen.registeredUse == chosen.registeredUse)
        #expect(frozen.rateCondition == chosen.condition)
        #expect(reopened.tanks[0].chemicals[0].volumePerTank == value * 12)
    }
}

@MainActor private final class ChemicalEvidenceReplayRepository: SprayRecordSyncRepositoryProtocol {
    var isOffline: Bool = true
    var deliveries: [BackendSprayRecordUpsert] = []
    func fetchAllSprayRecords(vineyardId: UUID) async throws -> [BackendSprayRecord] { [] }
    func fetchSprayRecords(vineyardId: UUID, since: Date?) async throws -> [BackendSprayRecord] { [] }
    func upsertSprayRecord(_ record: BackendSprayRecordUpsert) async throws { try await upsertSprayRecords([record]) }
    func upsertSprayRecords(_ records: [BackendSprayRecordUpsert]) async throws {
        if isOffline { throw URLError(.notConnectedToInternet) }
        deliveries.append(contentsOf: records)
    }
    func softDeleteSprayRecord(id: UUID) async throws { throw URLError(.unsupportedURL) }
}
