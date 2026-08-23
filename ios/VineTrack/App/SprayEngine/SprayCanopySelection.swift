import Foundation

/// The canopy the operator has actually chosen — and whether they chose it.
///
/// # Why a default is not an answer
///
/// `canopySize = .medium` and `canopyDensity = .low` were plain Swift defaults
/// on the Spray Calculator's state. Every segmented picker therefore opened
/// already showing Medium and Low, and the carrier step counted as complete
/// without the operator ever looking at it. A canopy nobody chose then set the
/// dilute / runoff rate, which set the concentration factor, which multiplied
/// every per-100 L product in the tank. The number was a placeholder; the
/// spray record it produced was not.
///
/// A default is a starting position for a control. It is not a statement about
/// this vineyard on this day, and the two must be distinguishable — so this
/// type carries the pair together with the one fact that makes them
/// actionable: whether a person confirmed them.
///
/// # What counts as confirmation
///
/// Touching either picker, or pressing Confirm when the defaults are already
/// right. Both are deliberate acts. A prefill from a Program Step or a repeated
/// job also counts (`prefilled`), because someone chose those values when they
/// composed the program — the operator is not being asked to re-answer a
/// question their own configuration already answered.
nonisolated struct SprayCanopySelection: Sendable, Hashable, Codable {
    /// The training system. `nil` until the operator picks one.
    ///
    /// Deliberately optional rather than defaulting to VSP. Every canopy
    /// control in VineTrack was headed "VSP Canopy Size" and read the VSP
    /// table, so VSP was the answer to a question nobody was asked. Now that
    /// Sprawl exists and demands materially more water at the wires-up sizes,
    /// silently assuming VSP would under-water a sprawl block by up to a third
    /// — and under-dose every per-100 L product measured against it.
    private(set) var type: CanopyType?
    private(set) var size: CanopySize
    private(set) var density: CanopyDensity
    /// True once size and density represent a decision rather than a starting
    /// position.
    private(set) var isSizeAndDensityConfirmed: Bool

    private init(
        type: CanopyType?,
        size: CanopySize,
        density: CanopyDensity,
        isSizeAndDensityConfirmed: Bool
    ) {
        self.type = type
        self.size = size
        self.density = density
        self.isSizeAndDensityConfirmed = isSizeAndDensityConfirmed
    }

    /// True once the WHOLE canopy is an answer: a training system was chosen
    /// and the size/density were confirmed.
    ///
    /// Both halves are required. A confirmed Medium/Low with no training system
    /// cannot produce a rate, because the table is indexed by all three.
    var isConfirmed: Bool { type != nil && isSizeAndDensityConfirmed }

    /// The controls' opening position. Deliberately NOT an answer.
    ///
    /// Medium / Low is retained as the starting position because it is the
    /// middle of the table and the least surprising thing to show — changing
    /// it would move every existing operator's habitual first tap for no gain.
    /// What changed is that it no longer counts.
    static let unconfirmed = SprayCanopySelection(
        type: nil,
        size: .medium,
        density: .low,
        isSizeAndDensityConfirmed: false
    )

    /// Values carried in from a Program Step or a repeated job.
    ///
    /// Confirmed on arrival: a program's canopy was chosen by a person when the
    /// program was written, and making the operator re-tap it would train them
    /// to dismiss the prompt rather than read it.
    /// Values carried in from a Program Step or a repeated job.
    ///
    /// # Backwards compatibility
    ///
    /// A historical canopy selection carries no training system, because the
    /// control that captured it was a VSP control reading the VSP table. Such a
    /// value therefore WAS a VSP canopy, and defaulting `type` to `.vsp` here
    /// reproduces the calculation that was originally performed rather than
    /// guessing. That is the only place VSP is assumed, and it is assumed about
    /// the past, never about a new spray.
    static func prefilled(
        type: CanopyType = .vsp,
        size: CanopySize,
        density: CanopyDensity
    ) -> SprayCanopySelection {
        SprayCanopySelection(
            type: type,
            size: size,
            density: density,
            isSizeAndDensityConfirmed: true
        )
    }

    /// Choosing the training system. Never implies the size was confirmed.
    mutating func choose(type newType: CanopyType) {
        type = newType
    }

    /// Choosing a size IS confirming the size/density pair.
    mutating func choose(size newSize: CanopySize) {
        size = newSize
        isSizeAndDensityConfirmed = true
    }

    mutating func choose(density newDensity: CanopyDensity) {
        density = newDensity
        isSizeAndDensityConfirmed = true
    }

    /// Accepts the size/density on screen unchanged. The operator whose canopy
    /// really is Medium / Low needs a way to say so.
    mutating func confirm() {
        isSizeAndDensityConfirmed = true
    }

    /// The dilute / runoff reference this canopy establishes, in L/100 m.
    ///
    /// Reads the SAME `CanopyWaterRate` table every carrier basis uses — there
    /// is one canopy model and this is not a second one. Returns 0 while no
    /// training system has been chosen, because the table cannot be indexed
    /// without one; callers gate on `isConfirmed` rather than on this value.
    func litresPer100m(settings: CanopyWaterRateEntry = .defaults) -> Double {
        guard let type else { return 0 }
        return CanopyWaterRate.litresPer100m(
            type: type,
            size: size,
            density: density,
            settings: settings
        )
    }

    /// Decodes a historical selection that predates the training-system
    /// question, reading it as the VSP canopy it was.
    nonisolated enum CodingKeys: String, CodingKey {
        case type, size, density, isSizeAndDensityConfirmed
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = (try? c.decodeIfPresent(CanopySize.self, forKey: .size)) as? CanopySize ?? .medium
        density = (try? c.decodeIfPresent(CanopyDensity.self, forKey: .density)) as? CanopyDensity ?? .low
        isSizeAndDensityConfirmed =
            (try? c.decodeIfPresent(Bool.self, forKey: .isSizeAndDensityConfirmed)) as? Bool ?? true
        // A stored canopy came from the VSP control and produced a VSP rate.
        type = ((try? c.decodeIfPresent(CanopyType.self, forKey: .type)) as? CanopyType) ?? .vsp
    }
}
