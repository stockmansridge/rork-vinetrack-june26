import Foundation

/// Stable source identity for an item rendered on the combined Pins surface.
nonisolated struct PinPresentationTarget: Equatable, Sendable {
    nonisolated enum Kind: Sendable {
        case pin
        case linkedGrowth
        case standaloneGrowth
    }

    let vineyardId: UUID
    let pinId: UUID?
    let growthRecordId: UUID?
    let kind: Kind

    static func resolve(
        displayId: UUID,
        pins: [VinePin],
        growthRecords: [GrowthStageRecord]
    ) -> PinPresentationTarget? {
        let pin = pins.first { $0.id == displayId }
        let growth = growthRecords.first {
            $0.pinId == displayId || ($0.pinId == nil && $0.id == displayId)
        }
        switch (pin, growth) {
        case let (pin?, growth?):
            return PinPresentationTarget(
                vineyardId: pin.vineyardId,
                pinId: pin.id,
                growthRecordId: growth.id,
                kind: .linkedGrowth
            )
        case let (pin?, nil):
            return PinPresentationTarget(vineyardId: pin.vineyardId, pinId: pin.id, growthRecordId: nil, kind: .pin)
        case let (nil, growth?) where growth.pinId != nil:
            return PinPresentationTarget(
                vineyardId: growth.vineyardId,
                pinId: growth.pinId,
                growthRecordId: growth.id,
                kind: .linkedGrowth
            )
        case let (nil, growth?):
            return PinPresentationTarget(
                vineyardId: growth.vineyardId,
                pinId: nil,
                growthRecordId: growth.id,
                kind: .standaloneGrowth
            )
        default:
            return nil
        }
    }
}
