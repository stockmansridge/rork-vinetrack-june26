import Foundation
import Observation

/// Offline-first store for the Fertiliser Calculator (System Admin only while
/// in development). Local cache for the shared `fertiliser_records` /
/// `fertiliser_record_allocations` Supabase tables: writes land here first and
/// fire sync hooks; remote state is applied through the `applyRemote*`
/// methods, which never re-fire the hooks.
///
/// Products are NOT stored here — the Fertiliser Calculator reads its product
/// library from the shared saved chemical database (`MigratedDataStore.savedChemicals`,
/// sql/111), which has its own sync service.
@Observable
final class FertiliserStore {
    static let shared = FertiliserStore()

    private(set) var records: [FertiliserRecord] = []

    /// Sync hooks — fired for local user edits only, never for remote applies.
    var onRecordChanged: ((UUID) -> Void)?
    var onRecordDeleted: ((UUID) -> Void)?

    private static let recordsKey = "vinetrack_fertiliser_records_v2"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
        records = persistence.load(key: Self.recordsKey) ?? []
    }

    // MARK: Records

    func records(forVineyard vineyardId: UUID?) -> [FertiliserRecord] {
        let list = vineyardId.map { id in records.filter { $0.vineyardId == id } } ?? records
        return list.sorted { $0.date > $1.date }
    }

    func addRecord(_ record: FertiliserRecord) {
        applyRecordUpsert(record)
        persistRecords()
        onRecordChanged?(record.id)
    }

    /// Converts a planned task into a completed application record.
    func markCompleted(id: UUID, on date: Date = Date()) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].status = .completed
        records[index].date = date
        persistRecords()
        onRecordChanged?(id)
    }

    func deleteRecord(id: UUID) {
        records.removeAll { $0.id == id }
        persistRecords()
        onRecordDeleted?(id)
    }

    // MARK: Remote applies (no hooks)

    func applyRemoteRecordUpsert(_ record: FertiliserRecord) {
        applyRecordUpsert(record)
        persistRecords()
    }

    func applyRemoteRecordDelete(_ id: UUID) {
        let before = records.count
        records.removeAll { $0.id == id }
        if records.count != before { persistRecords() }
    }

    // MARK: Persistence

    private func applyRecordUpsert(_ record: FertiliserRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    private func persistRecords() {
        persistence.save(records, key: Self.recordsKey)
    }
}
