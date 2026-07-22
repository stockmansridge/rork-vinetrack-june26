import Foundation

extension MigratedDataStore {
    /// Look up a `GrapeVariety` by id within the currently loaded grape varieties list.
    func grapeVariety(for id: UUID) -> GrapeVariety? {
        grapeVarieties.first { $0.id == id }
    }
}
