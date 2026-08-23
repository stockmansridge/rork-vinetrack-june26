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
    private(set) var size: CanopySize
    private(set) var density: CanopyDensity
    /// True once the values represent a decision rather than a starting
    /// position.
    private(set) var isConfirmed: Bool

    private init(size: CanopySize, density: CanopyDensity, isConfirmed: Bool) {
        self.size = size
        self.density = density
        self.isConfirmed = isConfirmed
    }

    /// The controls' opening position. Deliberately NOT an answer.
    ///
    /// Medium / Low is retained as the starting position because it is the
    /// middle of the table and the least surprising thing to show — changing
    /// it would move every existing operator's habitual first tap for no gain.
    /// What changed is that it no longer counts.
    static let unconfirmed = SprayCanopySelection(
        size: .medium,
        density: .low,
        isConfirmed: false
    )

    /// Values carried in from a Program Step or a repeated job.
    ///
    /// Confirmed on arrival: a program's canopy was chosen by a person when the
    /// program was written, and making the operator re-tap it would train them
    /// to dismiss the prompt rather than read it.
    static func prefilled(size: CanopySize, density: CanopyDensity) -> SprayCanopySelection {
        SprayCanopySelection(size: size, density: density, isConfirmed: true)
    }

    /// Choosing a size IS confirming the canopy.
    mutating func choose(size newSize: CanopySize) {
        size = newSize
        isConfirmed = true
    }

    mutating func choose(density newDensity: CanopyDensity) {
        density = newDensity
        isConfirmed = true
    }

    /// Accepts the values on screen unchanged. The operator whose canopy really
    /// is Medium / Low needs a way to say so.
    mutating func confirm() {
        isConfirmed = true
    }

    /// The dilute / runoff reference this canopy establishes, in L/100 m.
    ///
    /// Reads the SAME `CanopyWaterRate` table both carrier bases already use —
    /// there is one canopy model and this is not a second one.
    func litresPer100m(settings: CanopyWaterRateEntry = .defaults) -> Double {
        CanopyWaterRate.litresPer100m(size: size, density: density, settings: settings)
    }
}
