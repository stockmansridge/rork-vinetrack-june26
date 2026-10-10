import Foundation

/// Numeric operation evidence; no contents, identities, filenames or errors.
nonisolated struct PersistenceMeasurement: Sendable {
    enum Operation: String, Sendable { case read, save, durableSave, prepare }
    let dataset: PersistenceDataset
    let operation: Operation
    var readMilliseconds: Double = 0
    var codecMilliseconds: Double = 0
    var writeMilliseconds: Double = 0
    var bytes: Int = 0
    var records: Int? = nil
    var reusedDecode: Bool = false
    var reusedEncode: Bool = false
    var changed: Bool? = nil
    var succeeded: Bool = false
    var offMain: Bool = false
}
