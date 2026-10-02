import Foundation
import Testing
import PDFKit
@testable import VineTrack

@MainActor
struct SprayProgramRound2Tests {
    @Test(arguments: [0, 1, 2, 3, 4])
    func completionStatus(_ scenario: Int) {
        let end = Date(timeIntervalSince1970: 1770000000.123456)
        let trip = Trip(endTime: scenario == 2 || scenario == 3 ? end : nil,
            isActive: scenario == 1, isPaused: scenario == 3)
        let record = SprayRecord(tripId: trip.id, endTime: scenario == 0 ? end : nil)
        let expected: SprayCompletionStatus = scenario == 1 ? .inProgress : scenario == 4 ? .upcoming : .completed
        #expect(SprayCompletionResolver.status(record: record, trip: trip) == expected)
    }

    @Test(arguments: ["trip_end", "server_now"])
    func canonicalResponse(_ source: String) throws {
        let record = SprayRecord(notes: "Keep form edits")
        let end = Date(timeIntervalSince1970: 1770000000.123456)
        let response = SprayCompletionResponse(sprayRecordId: record.id, endTime: end, completionSource: source,
            serverConfirmed: true, updatedAt: end, updatedBy: UUID(), clientUpdatedAt: end, syncVersion: 8)
        let applied = try response.applying(to: record)
        #expect(applied.endTime == end)
        #expect(applied.syncVersion == 8)
        #expect(applied.notes == record.notes)
        #expect(applied.tripId == record.tripId)
    }

    @Test func completionErrors() {
        #expect(SprayCompletionFailure.message("ACTIVE_TRIP") == "This spray still has an active Trip. End the Trip to complete the spray.")
        #expect(SprayCompletionFailure.message("UNLINKED_CONFIRMATION_REQUIRED") == "No linked Trip is available. Mark this spray complete now?")
        #expect(SprayCompletionFailure.message("MANUAL_SPRAY_WORKFLOW_REQUIRED") == "Manual spray records must be managed through the manual spray workflow.")
    }

    @Test func completionReconciliationKeepsFormEditsAndWireOmitsEnd() throws {
        let local = SprayRecord(sprayReference: "Local corrected name", notes: "Legitimate queued notes", syncVersion: 3)
        var server = local
        server.notes = "Old server notes"
        server.endTime = Date(timeIntervalSince1970: 1770000000.123456)
        server.syncVersion = 8
        let merged = SprayCompletionResolver.preservingServerCompletion(local: local, server: server)
        #expect(merged.notes == local.notes)
        #expect(merged.sprayReference == local.sprayReference)
        #expect(merged.endTime == server.endTime)
        let payload = BackendSprayRecord.upsert(from: merged, createdBy: nil, clientUpdatedAt: Date())
        let fields = try SupabaseSprayRecordSyncRepository.editableFieldsPreservingCompletion(payload)
        #expect(fields["end_time"] == nil)
        #expect(fields["notes"] == .string(local.notes))
        #expect(fields["spray_reference"] == .string(local.sprayReference))
    }

    @Test(arguments: [false, true])
    func pendingReplayKeepsUnrelatedEditsAndCanonicalCompletion(_ fails: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let local = SprayRecord(notes: "Unrelated queued edit", syncVersion: 3)
        store.selectedVineyardId = local.vineyardId
        store.applyRemoteSprayRecordUpsert(local)
        let json = """
        {"id":"\(local.id)","vineyard_id":"\(local.vineyardId)","end_time":123456,"notes":"Old server notes","sync_version":8}
        """
        let server = try JSONDecoder().decode(BackendSprayRecord.self, from: Data(json.utf8))
        let repository = CompletionReplayRepository(server: server, fails: fails)
        let metadata = SprayRecordSyncMetadata(persistence: persistence)
        let service = SprayRecordSyncService(repository: repository, metadata: metadata)
        let auth = NewBackendAuthService()
        service.configure(store: store, auth: auth)
        service.markSprayRecordDirty(local.id)
        do { try await service.pushLocalSprayRecords(vineyardId: local.vineyardId) }
        catch { #expect(fails) }
        let payload = await repository.pushed.first
        #expect(payload?.notes == local.notes)
        #expect(payload?.endTime == server.endTime)
        #expect(store.sprayRecords.first?.endTime == server.endTime)
        #expect(store.sprayRecords.first?.notes == local.notes)
        #expect(service.isPendingUpsert(local.id) == fails)
    }

    @Test func progressionPreservesSameStageRepeatAndFutureSteps() {
        let first = SprayProgramStep(record: SprayRecord(sprayReference: "EL9 — 3-5 Leaves", isTemplate: true), source: .local)
        let repeatStep = SprayProgramStep(record: SprayRecord(sprayReference: "EL9 — Repeat 7-14 day intervals", isTemplate: true), source: .local)
        let later = SprayProgramStep(record: SprayRecord(sprayReference: "EL12 — Shoot Development", isTemplate: true), source: .local)
        let lower = SprayProgramStep(record: SprayRecord(sprayReference: "EL4 — Budburst", isTemplate: true), source: .local)
        let completed = SprayRecord(endTime: Date(), sprayReference: "3-5 Leaves / E-L Stage 9")
        #expect(SprayProgramProgression.remaining(steps: [later, lower, first, repeatStep], completed: [completed]).map(\.id) == [repeatStep.id, later.id])
        #expect(SprayProgramProgression.remaining(steps: [later, lower, first], completed: []).map(\.id) == [lower.id, first.id, later.id])
    }

    @Test func provenanceIsAuthoritativeAndNoFuzzyStepMatching() {
        let first = SprayProgramStep(record: SprayRecord(sprayReference: "EL9 — Same name", isTemplate: true), source: .local)
        let second = SprayProgramStep(record: SprayRecord(sprayReference: "EL9 — Same name", isTemplate: true), source: .local)
        let completed = SprayRecord(endTime: Date(), sprayReference: "EL9 — Same name", sprayJobId: first.id)
        #expect(SprayProgramProgression.remaining(steps: [first, second], completed: [completed]).map(\.id) == [second.id])
        let similar = SprayRecord(endTime: Date(), sprayReference: "EL9 — Same name additional")
        #expect(SprayProgramProgression.remaining(steps: [first], completed: [similar]).count == 1)
    }

    @Test func programDatasetPreservesRateDenominatorsAndExcludesOperationalData() throws {
        let products = [
            SprayChemical(name: "Area", ratePerHa: 120, unit: .millilitres, rateBasis: .wholeBlockArea),
            SprayChemical(name: "Volume", ratePer100L: 40, unit: .millilitres, rateBasis: .per100Litres)
        ]
        let record = SprayRecord(sprayReference: "EL9 — Leaves", tanks: [SprayTank(chemicals: products)], isTemplate: true)
        let step = SprayProgramStep(record: record, source: .local)
        let rows = SprayProgramReferenceDataset.rows(steps: [step], chemicals: [])
        #expect(rows.map(\.rate) == ["120.00 mL/ha", "40.00 mL/100 L"])
        let csv = SprayProgramReferenceDataset.csv(rows)
        #expect(csv.contains("Program Step"))
        #expect(!csv.contains("Operator"))
        #expect(!csv.contains("Tank"))
        #expect(rows.count == 2)
        let url = try SprayProgramReferenceExport.pdf(rows: rows, vineyard: "Synthetic Vineyard", logo: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let pdf = try #require(PDFDocument(url: url))
        #expect(pdf.pageCount > 0)
        #expect(pdf.string?.contains("40.00 mL/100 L") == true)
    }

    @Test func registeredFallbackKeepsAllMatchingRangesWithoutBorrowing() {
        let chemical = SavedChemical(name: "Product", unit: .kilograms, chemicalIntelligence: ChemicalIntelligence(registeredUses: [
            ChemicalRegisteredUse(crop: "Grapevines", targetRaw: "Downy mildew", rates: [
                ChemicalLabelRate(label: "Dilute", basis: .rangePer100Litres, minValue: 150, maxValue: 200, unit: "g"),
                ChemicalLabelRate(label: "High pressure", basis: .rangePer100Litres, minValue: 250, maxValue: 300, unit: "g")
            ]),
            ChemicalRegisteredUse(crop: "Tobacco", targetRaw: "Downy mildew", rates: [ChemicalLabelRate(basis: .perHectare, value: 999, unit: "kg")])
        ]))
        let product = SprayChemical(name: "Product", savedChemicalId: chemical.id)
        let step = SprayProgramStep(record: SprayRecord(sprayReference: "EL9 — Leaves", isTemplate: true), source: .portal, targetRaw: "Downy mildew")
        let rate = SprayProgramReferenceDataset.rate(product, step: step, chemicals: [chemical])
        #expect(rate.contains("150")); #expect(rate.contains("200"))
        #expect(rate.contains("250")); #expect(rate.contains("300"))
        #expect(!rate.contains("175")); #expect(!rate.contains("999"))
        let unmatched = SprayProgramStep(record: step.record, source: .portal, targetRaw: "Unknown target")
        #expect(SprayProgramReferenceDataset.rate(product, step: unmatched, chemicals: [chemical]).isEmpty)
    }

    @Test func exactSmallRatesAndProvenanceWithoutReferenceStage() {
        let product = SprayChemical(name: "Small", ratePerHa: 1, unit: .litres, rateBasis: .wholeBlockArea)
        let step = SprayProgramStep(record: SprayRecord(sprayReference: "Leaves", isTemplate: true), source: .portal, growthStageCode: "EL9")
        #expect(SprayProgramReferenceDataset.rate(product, step: step, chemicals: []) == "0.001 L/ha")
        let later = SprayProgramStep(record: SprayRecord(sprayReference: "EL12 — Shoot", isTemplate: true), source: .local)
        let completed = SprayRecord(endTime: Date(), sprayReference: "Leaves", sprayJobId: step.id)
        #expect(SprayProgramProgression.remaining(steps: [step, later], completed: [completed]).map(\.id) == [later.id])
    }

    @Test func undatedServerCompletionDoesNotInventCurrentVintage() throws {
        let id = UUID()
        let vineyard = UUID()
        let json = """
        {"id":"\(id)","vineyard_id":"\(vineyard)","end_time":123456,"sync_version":8}
        """
        let server = try JSONDecoder().decode(BackendSprayRecord.self, from: Data(json.utf8))
        let record = server.toSprayRecord()
        #expect(!record.hasRecordedEventDate)
        let window = SeasonWindow.window(vintage: 2027, seasonStartMonth: 7, seasonStartDay: 1, timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(SprayProgramProgression.completed(records: [record], trips: [], vineyardId: vineyard, window: window).isEmpty)
    }

    @Test func vintageDatasetUsesEventDateAndCompletedTripNotRepairDate() {
        let vineyard = UUID()
        let window = SeasonWindow.window(vintage: 2027, seasonStartMonth: 7, seasonStartDay: 1, timeZone: TimeZone(secondsFromGMT: 0)!)
        let trip = Trip(vineyardId: vineyard, endTime: window.start.addingTimeInterval(300), isActive: false, isPaused: true)
        let valid = SprayRecord(tripId: trip.id, vineyardId: vineyard, date: window.start, sprayReference: "EL9 — Leaves")
        let upcoming = SprayRecord(vineyardId: vineyard, date: window.start)
        let previous = SprayRecord(vineyardId: vineyard, date: window.start.addingTimeInterval(-1), endTime: Date())
        let boundary = SprayRecord(vineyardId: vineyard, date: window.endExclusive, endTime: Date())
        let template = SprayRecord(vineyardId: vineyard, date: window.start, endTime: Date(), isTemplate: true)
        #expect(SprayProgramProgression.completed(records: [valid, upcoming, previous, boundary, template], trips: [trip], vineyardId: vineyard, window: window).map(\.id) == [valid.id])
    }
}

private actor CompletionReplayRepository: SprayRecordSyncRepositoryProtocol {
    let server: BackendSprayRecord
    let fails: Bool
    var pushed: [BackendSprayRecordUpsert] = []
    init(server: BackendSprayRecord, fails: Bool) { self.server = server; self.fails = fails }
    func fetchAllSprayRecords(vineyardId: UUID) async throws -> [BackendSprayRecord] { [server] }
    func fetchSprayRecords(vineyardId: UUID, since: Date?) async throws -> [BackendSprayRecord] { [server] }
    func upsertSprayRecord(_ record: BackendSprayRecordUpsert) async throws { pushed.append(record) }
    func upsertSprayRecords(_ records: [BackendSprayRecordUpsert]) async throws {
        pushed.append(contentsOf: records)
        if fails { throw URLError(.notConnectedToInternet) }
    }
    func softDeleteSprayRecord(id: UUID) async throws {}
}
