import Foundation

/// DEBUG-only trace of the unit boundary a product quantity crosses.
///
/// # Why this exists
///
/// A 1000× dosing error was reported from a device and could not be reproduced
/// from the calculation layer alone, because the arithmetic there is correct:
/// the fault was a VIEW binding a base-unit number into a field labelled with
/// the display unit. That class of defect is invisible to a unit test of the
/// engine and invisible in a screenshot of a single number — you need the
/// value at each hop to see where the thousand appears.
///
/// This records those hops, and nothing else.
///
/// # What it deliberately does not do
///
/// It is compiled out of release builds entirely. It records numbers, units and
/// a product name — no vineyard, no block, no operator, no location, no
/// identifiers. A dosing trace is a maths problem, not a user record.
nonisolated enum SprayDoseTrace {

    /// One product line's journey from label rate to tank.
    nonisolated struct Entry: Sendable {
        let productName: String
        /// The rate exactly as the label states it, e.g. `"2.2 kg/ha"`.
        let sourceRateText: String
        /// The label's own unit token, e.g. `"kg"`.
        let sourceRateUnit: String
        /// `perHectare` / `per100Litres`.
        let sourceBasis: String
        /// The rate after conversion into base units (g / mL).
        let baseRate: Double
        let areaHectares: Double
        /// The total the engine produced, in base units.
        let baseRequired: Double
        /// The product's display unit, e.g. `Kg`.
        let displayUnit: String
        /// `baseRequired` passed back through `fromBase`.
        let displayRequired: Double
        /// What the tank workflow received, in base units.
        let handedToTankBase: Double
    }

    /// Emit a trace for one product line.
    ///
    /// A no-op in release. The `#if DEBUG` is inside the function so call sites
    /// stay readable and cannot drift out of sync with it.
    static func record(_ entry: Entry) {
        #if DEBUG
        let ratio = entry.displayRequired == 0
            ? 0
            : entry.baseRequired / entry.displayRequired
        print("""
        [SprayDose] \(entry.productName)
          label rate      : \(entry.sourceRateText) (unit=\(entry.sourceRateUnit), \
        basis=\(entry.sourceBasis))
          base rate       : \(entry.baseRate)
          area (ha)       : \(entry.areaHectares)
          base required   : \(entry.baseRequired)
          display unit    : \(entry.displayUnit)
          display required: \(entry.displayRequired)
          handed to tank  : \(entry.handedToTankBase) (base)
          base/display    : \(ratio)  <- expect 1 for L/mL-free units, 1000 for kg/g
        """)
        #endif
    }
}
