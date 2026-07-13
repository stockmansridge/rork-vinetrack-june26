import Foundation
import Observation

/// Local-first store for the Fertiliser Calculator (in development — System
/// Admin only). Persists to UserDefaults as JSON; model shapes mirror the
/// planned `fertiliser_products` / `fertiliser_applications` sync tables so
/// cloud sync can be added later without a data migration.
@Observable
final class FertiliserStore {
    private(set) var products: [FertiliserProduct] = []
    private(set) var records: [FertiliserRecord] = []

    private static let productsKey = "vinetrack_fertiliser_products"
    private static let recordsKey = "vinetrack_fertiliser_records"

    init() {
        load()
    }

    // MARK: Products

    func products(forVineyard vineyardId: UUID?) -> [FertiliserProduct] {
        let list = vineyardId.map { id in products.filter { $0.vineyardId == id } } ?? products
        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func upsertProduct(_ product: FertiliserProduct) {
        if let index = products.firstIndex(where: { $0.id == product.id }) {
            products[index] = product
        } else {
            products.append(product)
        }
        persistProducts()
    }

    func deleteProduct(id: UUID) {
        products.removeAll { $0.id == id }
        persistProducts()
    }

    // MARK: Records

    func records(forVineyard vineyardId: UUID?) -> [FertiliserRecord] {
        let list = vineyardId.map { id in records.filter { $0.vineyardId == id } } ?? records
        return list.sorted { $0.date > $1.date }
    }

    func addRecord(_ record: FertiliserRecord) {
        records.append(record)
        persistRecords()
    }

    /// Converts a planned task into a completed application record.
    func markCompleted(id: UUID, on date: Date = Date()) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].status = .completed
        records[index].date = date
        persistRecords()
    }

    func deleteRecord(id: UUID) {
        records.removeAll { $0.id == id }
        persistRecords()
    }

    // MARK: Persistence

    private func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.productsKey),
           let decoded = try? JSONDecoder().decode([FertiliserProduct].self, from: data) {
            products = decoded
        }
        if let data = defaults.data(forKey: Self.recordsKey),
           let decoded = try? JSONDecoder().decode([FertiliserRecord].self, from: data) {
            records = decoded
        }
    }

    private func persistProducts() {
        if let data = try? JSONEncoder().encode(products) {
            UserDefaults.standard.set(data, forKey: Self.productsKey)
        }
    }

    private func persistRecords() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.recordsKey)
        }
    }
}
