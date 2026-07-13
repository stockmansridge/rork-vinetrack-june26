import Foundation
import Observation

/// Offline-first store for the Fertiliser Calculator (System Admin only while
/// in development). Local cache for the shared `fertiliser_products` /
/// `fertiliser_records` / `fertiliser_record_allocations` Supabase tables:
/// writes land here first and fire sync hooks; remote state is applied through
/// the `applyRemote*` methods, which never re-fire the hooks.
///
/// Storage note: v1 development data lived in UserDefaults and was device-only
/// test data — it is intentionally discarded by the move to the shared
/// `PersistenceStore` under new v2 keys.
@Observable
final class FertiliserStore {
    static let shared = FertiliserStore()

    private(set) var products: [FertiliserProduct] = []
    private(set) var records: [FertiliserRecord] = []

    /// Sync hooks — fired for local user edits only, never for remote applies.
    var onProductChanged: ((UUID) -> Void)?
    var onProductDeleted: ((UUID) -> Void)?
    var onRecordChanged: ((UUID) -> Void)?
    var onRecordDeleted: ((UUID) -> Void)?

    private static let productsKey = "vinetrack_fertiliser_products_v2"
    private static let recordsKey = "vinetrack_fertiliser_records_v2"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
        products = persistence.load(key: Self.productsKey) ?? []
        records = persistence.load(key: Self.recordsKey) ?? []
    }

    // MARK: Products

    func products(forVineyard vineyardId: UUID?) -> [FertiliserProduct] {
        let list = vineyardId.map { id in products.filter { $0.vineyardId == id } } ?? products
        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func upsertProduct(_ product: FertiliserProduct) {
        applyProductUpsert(product)
        persistProducts()
        onProductChanged?(product.id)
    }

    func deleteProduct(id: UUID) {
        products.removeAll { $0.id == id }
        persistProducts()
        onProductDeleted?(id)
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

    func applyRemoteProductUpsert(_ product: FertiliserProduct) {
        applyProductUpsert(product)
        persistProducts()
    }

    func applyRemoteProductDelete(_ id: UUID) {
        let before = products.count
        products.removeAll { $0.id == id }
        if products.count != before { persistProducts() }
    }

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

    private func applyProductUpsert(_ product: FertiliserProduct) {
        if let index = products.firstIndex(where: { $0.id == product.id }) {
            products[index] = product
        } else {
            products.append(product)
        }
    }

    private func applyRecordUpsert(_ record: FertiliserRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    private func persistProducts() {
        persistence.save(products, key: Self.productsKey)
    }

    private func persistRecords() {
        persistence.save(records, key: Self.recordsKey)
    }
}
