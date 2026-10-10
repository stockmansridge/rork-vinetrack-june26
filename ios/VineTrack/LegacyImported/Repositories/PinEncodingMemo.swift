import Foundation

/// One immutable encoding result, not a persisted-state or acknowledgement cache.
/// VinePin's synthesized equality covers all stored fields, including photos,
/// versions and attachment metadata. Supplement it for the two equivalences
/// Swift equality permits but JSON encoding does not: Unicode spelling and -0.
nonisolated struct PinEncodingMemo: Sendable {
    let pins: [VinePin]
    let bytes: Data

    func matches(_ candidate: [VinePin]) -> Bool {
        guard pins == candidate else { return false }
        return zip(pins, candidate).allSatisfy { a, b in
            a.latitude.bitPattern == b.latitude.bitPattern
                && a.longitude.bitPattern == b.longitude.bitPattern
                && a.heading?.bitPattern == b.heading?.bitPattern
                && a.drivingRowNumber?.bitPattern == b.drivingRowNumber?.bitPattern
                && a.alongRowDistanceM?.bitPattern == b.alongRowDistanceM?.bitPattern
                && a.snappedLatitude?.bitPattern == b.snappedLatitude?.bitPattern
                && a.snappedLongitude?.bitPattern == b.snappedLongitude?.bitPattern
                && exact(a.buttonName, b.buttonName)
                && exact(a.buttonColor, b.buttonColor)
                && exact(a.createdBy, b.createdBy)
                && exact(a.completedBy, b.completedBy)
                && exact(a.photoPath, b.photoPath)
                && exact(a.growthStageCode, b.growthStageCode)
                && exact(a.notes, b.notes)
                && exact(a.locationScope, b.locationScope)
        }
    }

    private func exact(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (.none, .none): return true
        case let (.some(a), .some(b)): return a.utf8.elementsEqual(b.utf8)
        default: return false
        }
    }
}
