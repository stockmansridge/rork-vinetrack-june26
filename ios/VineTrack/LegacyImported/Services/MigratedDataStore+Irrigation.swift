import Foundation

extension MigratedDataStore {
    var paddockCentroidLongitude: Double? {
        let coords = paddocks.flatMap { $0.polygonPoints }
        guard !coords.isEmpty else { return nil }
        let sum = coords.reduce(0.0) { $0 + $1.longitude }
        return sum / Double(coords.count)
    }
}
