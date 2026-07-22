import Foundation

/// Owns persistence and merge/replace logic for the spray domain:
/// SprayRecord, SavedChemical, SavedSprayPreset, SavedEquipmentOption, SprayEquipmentItem.
@MainActor
final class SprayRepository {

    static let recordsKey = "vinetrack_spray_records"
    static let savedChemicalsKey = "vinetrack_saved_chemicals"
    static let savedPresetsKey = "vinetrack_saved_spray_presets"
    static let savedEquipmentOptionsKey = "vinetrack_saved_equipment_options"
    static let equipmentKey = "vinetrack_spray_equipment"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
    }

    // MARK: - SprayRecord

    func loadAllRecords() -> [SprayRecord] {
        persistence.load(key: Self.recordsKey) ?? []
    }

    func loadRecords(for vineyardId: UUID) -> [SprayRecord] {
        loadAllRecords().filter { $0.vineyardId == vineyardId }
    }

    func saveRecordsSlice(_ items: [SprayRecord], for vineyardId: UUID) {
        var all = loadAllRecords()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.recordsKey)
    }

    func replaceRecords(_ remote: [SprayRecord], for vineyardId: UUID) {
        var all = loadAllRecords()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.recordsKey)
    }

    func mergeRecords(_ remote: [SprayRecord], for vineyardId: UUID) -> [SprayRecord] {
        var all = loadAllRecords()
        for item in remote {
            if !all.contains(where: { $0.id == item.id }) {
                all.append(item)
            }
        }
        persistence.save(all, key: Self.recordsKey)
        return all.filter { $0.vineyardId == vineyardId }
    }

    // MARK: - SavedChemical

    func loadAllChemicals() -> [SavedChemical] {
        persistence.load(key: Self.savedChemicalsKey) ?? []
    }

    func loadChemicals(for vineyardId: UUID) -> [SavedChemical] {
        loadAllChemicals().filter { $0.vineyardId == vineyardId }
    }

    func saveChemicalsSlice(_ items: [SavedChemical], for vineyardId: UUID) {
        var all = loadAllChemicals()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.savedChemicalsKey)
    }

    func replaceChemicals(_ remote: [SavedChemical], for vineyardId: UUID) {
        var all = loadAllChemicals()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.savedChemicalsKey)
    }

    func mergeChemicals(_ remote: [SavedChemical], for vineyardId: UUID) -> [SavedChemical] {
        var all = loadAllChemicals()
        for item in remote {
            if !all.contains(where: { $0.id == item.id }) {
                all.append(item)
            }
        }
        persistence.save(all, key: Self.savedChemicalsKey)
        return all.filter { $0.vineyardId == vineyardId }
    }

    // MARK: - SavedSprayPreset

    func loadAllPresets() -> [SavedSprayPreset] {
        persistence.load(key: Self.savedPresetsKey) ?? []
    }

    func loadPresets(for vineyardId: UUID) -> [SavedSprayPreset] {
        loadAllPresets().filter { $0.vineyardId == vineyardId }
    }

    func savePresetsSlice(_ items: [SavedSprayPreset], for vineyardId: UUID) {
        var all = loadAllPresets()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.savedPresetsKey)
    }

    func replacePresets(_ remote: [SavedSprayPreset], for vineyardId: UUID) {
        var all = loadAllPresets()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.savedPresetsKey)
    }

    func mergePresets(_ remote: [SavedSprayPreset], for vineyardId: UUID) -> [SavedSprayPreset] {
        var all = loadAllPresets()
        for item in remote {
            if !all.contains(where: { $0.id == item.id }) {
                all.append(item)
            }
        }
        persistence.save(all, key: Self.savedPresetsKey)
        return all.filter { $0.vineyardId == vineyardId }
    }

    // MARK: - SavedEquipmentOption

    func loadAllEquipmentOptions() -> [SavedEquipmentOption] {
        persistence.load(key: Self.savedEquipmentOptionsKey) ?? []
    }

    func loadEquipmentOptions(for vineyardId: UUID) -> [SavedEquipmentOption] {
        loadAllEquipmentOptions().filter { $0.vineyardId == vineyardId }
    }

    func saveEquipmentOptionsSlice(_ items: [SavedEquipmentOption], for vineyardId: UUID) {
        var all = loadAllEquipmentOptions()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.savedEquipmentOptionsKey)
    }

    func replaceEquipmentOptions(_ remote: [SavedEquipmentOption], for vineyardId: UUID) {
        var all = loadAllEquipmentOptions()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.savedEquipmentOptionsKey)
    }

    func mergeEquipmentOptions(_ remote: [SavedEquipmentOption], for vineyardId: UUID) -> [SavedEquipmentOption] {
        var all = loadAllEquipmentOptions()
        for item in remote {
            if !all.contains(where: { $0.id == item.id }) {
                all.append(item)
            }
        }
        persistence.save(all, key: Self.savedEquipmentOptionsKey)
        return all.filter { $0.vineyardId == vineyardId }
    }

    // MARK: - SprayEquipmentItem

    func loadAllEquipment() -> [SprayEquipmentItem] {
        persistence.load(key: Self.equipmentKey) ?? []
    }

    func loadEquipment(for vineyardId: UUID) -> [SprayEquipmentItem] {
        loadAllEquipment().filter { $0.vineyardId == vineyardId }
    }

    func saveEquipmentSlice(_ items: [SprayEquipmentItem], for vineyardId: UUID) {
        var all = loadAllEquipment()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.equipmentKey)
    }

    func replaceEquipment(_ remote: [SprayEquipmentItem], for vineyardId: UUID) {
        var all = loadAllEquipment()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.equipmentKey)
    }

    func mergeEquipment(_ remote: [SprayEquipmentItem], for vineyardId: UUID) -> [SprayEquipmentItem] {
        var all = loadAllEquipment()
        for item in remote {
            if !all.contains(where: { $0.id == item.id }) {
                all.append(item)
            }
        }
        persistence.save(all, key: Self.equipmentKey)
        return all.filter { $0.vineyardId == vineyardId }
    }
}
