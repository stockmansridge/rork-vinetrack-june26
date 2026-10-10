import Foundation
import Testing
@testable import VineTrack

@MainActor
struct PersistencePerformanceTests {
    @Test func repeatedReadsReuseDecodeButObserveChangedAndCorruptDisk() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceStore(directory: directory)
        var measurements: [PersistenceMeasurement] = []
        store.onPersistenceMeasurementForTesting = { measurements.append($0) }
        let first = [pin(name: "First")]
        store.save(first, key: PinRepository.storageKey)
        let a: [VinePin]? = store.load(key: PinRepository.storageKey)
        let b: [VinePin]? = store.load(key: PinRepository.storageKey)
        #expect(a == first && b == first)
        #expect(measurements.last?.reusedDecode == true)
        let other = PersistenceStore(directory: directory)
        let updated = [pin(name: "Other writer")]
        other.save(updated, key: PinRepository.storageKey)
        let c: [VinePin]? = store.load(key: PinRepository.storageKey)
        #expect(c == updated)
        #expect(measurements.last?.reusedDecode == false)
        let file = directory.appendingPathComponent("\(PinRepository.storageKey).json")
        try Data("corrupt".utf8).write(to: file, options: .atomic)
        var failures: Int = 0
        store.onDecodeFailure = { _, _ in failures += 1 }
        let corrupt: PersistenceStore.LoadOutcome<[VinePin]> = store.loadOutcome(key: PinRepository.storageKey)
        guard case .failed = corrupt else { Issue.record("A warm memo must not conceal corruption"); return }
        #expect(failures == 1)
        #expect(store.quarantine(key: PinRepository.storageKey) != nil)
        let missing: PersistenceStore.LoadOutcome<[VinePin]> = store.loadOutcome(key: PinRepository.storageKey)
        guard case .missing = missing else { Issue.record("Quarantined file must remain missing"); return }
    }

    @Test func changedPendingFlagsPrecisionAndOrderArePersisted() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceStore(directory: directory)
        let vineyard = UUID()
        var chemical = SavedChemical(vineyardId: vineyard, name: "Fixture", ratePerHa: 0.12345678912345678)
        let second = SavedChemical(vineyardId: vineyard, name: "Second")
        store.save([chemical, second], key: SprayRepository.savedChemicalsKey)
        let _: [SavedChemical]? = store.load(key: SprayRepository.savedChemicalsKey)
        chemical.vineyardPreferredRatePending = true
        chemical.savedChemicalGeneralPending = true
        store.save([second, chemical], key: SprayRepository.savedChemicalsKey)
        let fresh: [SavedChemical]? = PersistenceStore(directory: directory).load(key: SprayRepository.savedChemicalsKey)
        #expect(fresh == [second, chemical])
        #expect(fresh?.last?.ratePerHa?.bitPattern == chemical.ratePerHa?.bitPattern)
        #expect(fresh?.last?.vineyardPreferredRatePending == true)
        #expect(fresh?.last?.savedChemicalGeneralPending == true)
    }

    @Test func durableIdenticalSaveStillWritesAndFailureIsNotAcknowledged() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceStore(directory: directory)
        var measurements: [PersistenceMeasurement] = []
        store.onPersistenceMeasurementForTesting = { measurements.append($0) }
        let rows = [pin(name: "Durable")]
        try store.saveOrThrow(rows, key: PinRepository.storageKey)
        try store.saveOrThrow(rows, key: PinRepository.storageKey)
        #expect(measurements.last?.changed == false)
        #expect(measurements.last?.writeMilliseconds ?? 0 > 0)
        store.durableSaveFailureForTesting = { _ in CocoaError(.fileWriteUnknown) }
        #expect(throws: (any Error).self) { try store.saveOrThrow(rows, key: PinRepository.storageKey) }
        let recovered: [VinePin]? = PersistenceStore(directory: directory).load(key: PinRepository.storageKey)
        #expect(recovered == rows)
    }

    @Test func metadataWritesNeverUseCollectionSkip() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceStore(directory: directory)
        var measurement: PersistenceMeasurement?
        store.onPersistenceMeasurementForTesting = { measurement = $0 }
        store.save(["pending": 7], key: "vinetrack_pin_sync_metadata")
        store.save(["pending": 7], key: "vinetrack_pin_sync_metadata")
        #expect(measurement?.writeMilliseconds ?? 0 > 0)
        #expect(measurement?.changed == nil)
        #expect(measurement?.dataset == .pinMetadata)
    }

    @Test func unchangedNonDurableCollectionSkipsOnlyExactBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceStore(directory: directory)
        let rows = [pin(name: "Fixture")]
        store.save(rows, key: PinRepository.storageKey)
        let file = directory.appendingPathComponent("\(PinRepository.storageKey).json")
        let original = try Data(contentsOf: file)
        var measurement: PersistenceMeasurement?
        store.onPersistenceMeasurementForTesting = { measurement = $0 }
        store.save(rows, key: PinRepository.storageKey)
        #expect(measurement?.changed == false && measurement?.writeMilliseconds == 0)
        #expect(try Data(contentsOf: file) == original)
        try FileManager.default.removeItem(at: file)
        store.save(rows, key: PinRepository.storageKey)
        #expect(measurement?.writeMilliseconds ?? 0 > 0)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func preparedDecodeRunsOffMainAndCannotOverwriteNewerRecords() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = PersistenceStore(directory: directory)
        let old = [pin(name: "Old")]
        disk.save(old, key: PinRepository.storageKey)
        let fresh = PersistenceStore(directory: directory)
        var measurement: PersistenceMeasurement?
        fresh.onPersistenceMeasurementForTesting = { measurement = $0 }
        await fresh.prepareDecode([VinePin].self, key: PinRepository.storageKey)
        #expect(measurement?.offMain == true && measurement?.succeeded == true)
        let newer = [pin(name: "Newer")]
        disk.save(newer, key: PinRepository.storageKey)
        let loaded: [VinePin]? = fresh.load(key: PinRepository.storageKey)
        #expect(loaded == newer)
        #expect(measurement?.reusedDecode == false)
        #expect(disk.load(key: PinRepository.storageKey) as [VinePin]? == newer)
    }

    @Test func goldenJSONRemainsByteIdenticalAndReturnedValuesAreIndependent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows = [pin(name: "e\u{301}", photo: Data([0, 255, 17]))]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let expected = try encoder.encode(rows)
        let store = PersistenceStore(directory: directory)
        try store.saveOrThrow(rows, key: PinRepository.storageKey)
        #expect(try Data(contentsOf: directory.appendingPathComponent("\(PinRepository.storageKey).json")) == expected)
        var edited: [VinePin] = store.load(key: PinRepository.storageKey) ?? []
        edited[0].notes = "Unsaved edit"
        edited[0].photoData?.append(12)
        let original: [VinePin]? = store.load(key: PinRepository.storageKey)
        #expect(original == rows)
    }

    @Test func boundedSyntheticReadBenchmark() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows = (0..<40).map { pin(name: "Fixture \($0)", photo: Data(repeating: UInt8($0), count: 48 * 1024)) }
        let store = PersistenceStore(directory: directory)
        store.save(rows, key: PinRepository.storageKey)
        let file = directory.appendingPathComponent("\(PinRepository.storageKey).json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let baselineStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<4 {
            let decoded = try decoder.decode([VinePin].self, from: Data(contentsOf: file))
            #expect(decoded == rows)
        }
        let baseline = (ProcessInfo.processInfo.systemUptime - baselineStart) * 1000 / 4
        let _: [VinePin]? = store.load(key: PinRepository.storageKey)
        let memoStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<4 {
            let decoded: [VinePin]? = store.load(key: PinRepository.storageKey)
            #expect(decoded == rows)
        }
        let memo = (ProcessInfo.processInfo.systemUptime - memoStart) * 1000 / 4
        print(String(format: "PERSISTENCE_BENCH syntheticPins count=40 bytes=%d baselineReadDecode=%.2fms memoRead=%.2fms", try Data(contentsOf: file).count, baseline, memo))
    }

    @Test func encodingMemoPreservesUnicodeSignedZeroPhotosAndRevision() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceStore(directory: directory)
        var measurement: PersistenceMeasurement?
        store.onPersistenceMeasurementForTesting = { measurement = $0 }
        var value = pin(name: "\u{e9}", photo: Data([0, 1, 2]))
        value.snappedLatitude = 0.0
        try store.saveOrThrow([value], key: PinRepository.storageKey)
        try store.saveOrThrow([value], key: PinRepository.storageKey)
        #expect(measurement?.reusedEncode == true)
        var changed = value
        changed.notes = "New pending notes"
        changed.syncVersion = 8
        changed.photoData = Data([0, 1, 3])
        changed.snappedLatitude = -0.0
        try store.saveOrThrow([changed], key: PinRepository.storageKey)
        #expect(measurement?.reusedEncode == false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = directory.appendingPathComponent("\(PinRepository.storageKey).json")
        #expect(try Data(contentsOf: file) == encoder.encode([changed]))
        var alternateSpelling = changed
        alternateSpelling.notes = "e\u{301}"
        changed.notes = "\u{e9}"
        #expect(changed == alternateSpelling)
        try store.saveOrThrow([changed], key: PinRepository.storageKey)
        try store.saveOrThrow([alternateSpelling], key: PinRepository.storageKey)
        #expect(measurement?.reusedEncode == false)
        #expect(try Data(contentsOf: file) == encoder.encode([alternateSpelling]))
        var negative = alternateSpelling
        negative.snappedLatitude = 0.0
        #expect(negative == alternateSpelling)
        try store.saveOrThrow([negative], key: PinRepository.storageKey)
        #expect(measurement?.reusedEncode == false)
        #expect(try Data(contentsOf: file) == encoder.encode([negative]))
    }

    @Test func encodingIdentityAuditCoversEveryStoredDoubleAndString() {
        let fields = Mirror(reflecting: pin(name: "Fixture")).children
        let doubleFields = Set(fields.filter { Swift.type(of: $0.value) == Double.self || Swift.type(of: $0.value) == Optional<Double>.self }.compactMap(\.label))
        let stringFields = Set(fields.filter { Swift.type(of: $0.value) == String.self || Swift.type(of: $0.value) == Optional<String>.self }.compactMap(\.label))
        #expect(doubleFields == Set(["latitude", "longitude", "heading", "drivingRowNumber", "alongRowDistanceM", "snappedLatitude", "snappedLongitude"]))
        #expect(stringFields == Set(["buttonName", "buttonColor", "createdBy", "completedBy", "photoPath", "growthStageCode", "notes", "locationScope"]))
    }

    @Test func offMainEncodingPreparationIsNotAWritableSnapshot() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = PersistenceStore(directory: directory)
        let original = [pin(name: "Original")]
        disk.save(original, key: PinRepository.storageKey)
        let prepared = PersistenceStore(directory: directory)
        var measurement: PersistenceMeasurement?
        prepared.onPersistenceMeasurementForTesting = { measurement = $0 }
        await prepared.prepareDecode([VinePin].self, key: PinRepository.storageKey)
        await prepared.preparePinEncoding()
        #expect(measurement?.offMain == true)
        let newer = [pin(name: "Newer")]
        try prepared.saveOrThrow(newer, key: PinRepository.storageKey)
        #expect(measurement?.reusedEncode == false)
        #expect(PersistenceStore(directory: directory).load(key: PinRepository.storageKey) as [VinePin]? == newer)
        try prepared.saveOrThrow(newer, key: PinRepository.storageKey)
        #expect(measurement?.reusedEncode == true)
    }

    @Test func legacyGeneratedIdentitiesAreNeverMemoizedOrRepaired() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceStore(directory: directory)
        var measurement: PersistenceMeasurement?
        store.onPersistenceMeasurementForTesting = { measurement = $0 }
        let id = UUID(), vineyard = UUID()
        let chemicalBytes = Data("""
        [{"id":"\(id)","vineyardId":"\(vineyard)","rates":[{"label":"legacy","value":1,"basis":"perHectare"}]}]
        """.utf8)
        try chemicalBytes.write(to: directory.appendingPathComponent("\(SprayRepository.savedChemicalsKey).json"), options: .atomic)
        let first: [SavedChemical]? = store.load(key: SprayRepository.savedChemicalsKey)
        let second: [SavedChemical]? = store.load(key: SprayRepository.savedChemicalsKey)
        #expect(first?.first?.rates.first?.id != second?.first?.rates.first?.id)
        #expect(measurement?.reusedDecode == false)
        #expect(try Data(contentsOf: directory.appendingPathComponent("\(SprayRepository.savedChemicalsKey).json")) == chemicalBytes)
        let blockBytes = Data("""
        [{"id":"\(id)","vineyardId":"\(vineyard)","name":"Legacy","polygonPoints":[{"latitude":-33,"longitude":149}],"rows":[],"rowDirection":0}]
        """.utf8)
        try blockBytes.write(to: directory.appendingPathComponent("vinetrack_paddocks.json"), options: .atomic)
        let a: [Paddock]? = store.load(key: "vinetrack_paddocks")
        let b: [Paddock]? = store.load(key: "vinetrack_paddocks")
        #expect(a?.first?.polygonPoints.first?.id != b?.first?.polygonPoints.first?.id)
        #expect(measurement?.reusedDecode == false)
        #expect(try Data(contentsOf: directory.appendingPathComponent("vinetrack_paddocks.json")) == blockBytes)
    }

    @Test func diagnosticsNeverExposeScopedKeys() {
        #expect(PersistenceDataset.classify("vinetrack_work_task_pending_ACCOUNT_SECRET_VINEYARD_SECRET") == .metadata)
        #expect(PersistenceDataset.classify("unknown_ACCOUNT_SECRET") == .other)
        #expect(PersistenceDataset.classify("vinetrack_work_task_machine_lines") == .workTaskMachines)
        #expect(PersistenceDataset.classify("vinetrack_saved_spray_presets") == .sprayPresets)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func pin(name: String, photo: Data? = nil) -> VinePin {
        VinePin(vineyardId: UUID(), latitude: -33.123456789, longitude: 149.123456789,
            heading: nil, buttonName: name, buttonColor: "red", side: nil, mode: .repairs,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), photoData: photo)
    }
}
