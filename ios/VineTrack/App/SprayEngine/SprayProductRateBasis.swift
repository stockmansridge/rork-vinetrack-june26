import Foundation

/// What a product's label rate is measured AGAINST.
///
/// This belongs to each product line, NOT to the spray job: one tank mix can
/// legitimately contain a whole-block-area product, a treated-area product and
/// a per-100 L adjuvant at the same time.
///
/// This is the PRODUCT LABEL RATE BASIS and is independent of
/// `SprayCarrierBasis` (how the grower enters carrier volume).
nonisolated enum SprayProductRateBasis: String, Sendable, Codable, CaseIterable {
    /// Rate × GROSS block hectares. The legacy `per_hectare` meaning.
    case wholeBlockArea = "whole_block_area"
    /// Rate × ACTUAL TREATED hectares (banded/strip applications).
    case treatedArea = "treated_area"
    /// Rate × carrier litres ÷ 100.
    case per100Litres = "per_100_litres"
    /// Rate × row metres ÷ 100 — distance-based label rates.
    case per100Metres = "per_100_metres"

    var label: String {
        switch self {
        case .wholeBlockArea: return "Per whole block ha"
        case .treatedArea: return "Per treated ha"
        case .per100Litres: return "Per 100 L"
        case .per100Metres: return "Per 100 m"
        }
    }

    /// How the rate itself is written on the label, e.g. `2 L/ha`.
    var rateSuffix: String {
        switch self {
        case .wholeBlockArea, .treatedArea: return "/ha"
        case .per100Litres: return "/100 L"
        case .per100Metres: return "/100 m"
        }
    }

    /// What the measured half of the calculation is called, e.g. `whole block`.
    var measuredNoun: String {
        switch self {
        case .wholeBlockArea: return "whole block"
        case .treatedArea: return "treated band"
        case .per100Litres: return "carrier"
        case .per100Metres: return "row"
        }
    }

    /// The unit the measured half is expressed in.
    var measuredUnit: String {
        switch self {
        case .wholeBlockArea, .treatedArea: return "ha"
        case .per100Litres: return "L"
        case .per100Metres: return "m"
        }
    }

    /// The two bases an AREA-rated product line may legitimately choose between.
    ///
    /// Deliberately excludes the per-100 L and per-100 m bases: those come from
    /// the product's own label, are not an area question, and must never appear
    /// as a Whole Block / Treated Band choice.
    static var areaChoices: [SprayProductRateBasis] { [.wholeBlockArea, .treatedArea] }

    /// Whether this basis measures against an area (used for reporting labels).
    var isAreaBased: Bool { self == .wholeBlockArea || self == .treatedArea }

    /// Deterministic mapping from the legacy stored strings.
    ///
    /// `per_hectare` maps to `.wholeBlockArea` because that is EXACTLY what
    /// every existing record computed — including banded jobs, which multiplied
    /// the rate by gross block hectares. Mapping it to `.treatedArea` would
    /// silently restate historical quantities.
    static func legacy(_ raw: String?) -> SprayProductRateBasis? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        if let exact = SprayProductRateBasis(rawValue: raw) { return exact }
        switch raw {
        case "per_hectare", "perhectare", "per_ha", "l/ha", "per hectare":
            return .wholeBlockArea
        case "per_100_litres", "per100litres", "per_100l", "per 100l", "l/100l":
            return .per100Litres
        case "per_100_metres", "per100metres", "per_100m", "l/100m":
            return .per100Metres
        default:
            return nil
        }
    }

    /// The stored value for a legacy reader that only understands
    /// `per_hectare` / `per_100_litres`, so older clients and the portal keep
    /// working while the new basis is rolled out.
    var legacyCompatibleValue: String {
        switch self {
        case .wholeBlockArea, .treatedArea, .per100Metres: return "per_hectare"
        case .per100Litres: return "per_100_litres"
        }
    }
}

/// The measured application a product quantity is calculated against.
nonisolated struct SprayQuantityContext: Sendable, Hashable {
    let grossAreaHectares: Double
    /// Actual treated hectares. `nil` when not a banded job or not calculable.
    let treatedAreaHectares: Double?
    /// Total ACTUAL carrier litres.
    let carrierLitres: Double
    /// `dilute ÷ applied`. Per-100 L label rates are written against the DILUTE
    /// volume, so concentrating must not reduce the product dose.
    let concentrationFactor: Double
    let rowLengthMetres: Double?

    init(
        grossAreaHectares: Double,
        treatedAreaHectares: Double? = nil,
        carrierLitres: Double,
        concentrationFactor: Double = 1.0,
        rowLengthMetres: Double? = nil
    ) {
        self.grossAreaHectares = grossAreaHectares
        self.treatedAreaHectares = treatedAreaHectares
        self.carrierLitres = carrierLitres
        self.concentrationFactor = concentrationFactor
        self.rowLengthMetres = rowLengthMetres
    }

    /// Builds a context from canonical geometry + a resolved carrier volume, so
    /// the treated area and the carrier volume provably share one row length.
    init(
        geometry: SprayApplicationGeometry,
        carrier: SprayCarrierVolume,
        treatedAreaHectares: Double? = nil
    ) {
        self.grossAreaHectares = geometry.grossAreaHectares
        self.treatedAreaHectares = treatedAreaHectares
        self.carrierLitres = carrier.totalLitres
        self.concentrationFactor = carrier.concentrationFactor
        self.rowLengthMetres = geometry.totalRowLengthMetres
    }
}

nonisolated enum SprayProductQuantityCalculator {

    /// Total product required, expressed in the SAME unit as `rate`.
    ///
    /// ```text
    /// wholeBlockArea → rate × grossAreaHectares
    /// treatedArea    → rate × treatedAreaHectares
    /// per100Litres   → rate × carrierLitres ÷ 100 × concentrationFactor
    /// per100Metres   → rate × rowLengthMetres ÷ 100
    /// ```
    ///
    /// Returns `nil` when the input this basis depends on is unavailable —
    /// never 0, which would understate a dose.
    ///
    /// An absent rate is one of those unavailable inputs. A product with no
    /// resolvable rate is UNRESOLVED, not a product applied at zero: returning
    /// 0 here let an unrated line report itself as calculated, pass the
    /// Products step, and freeze "0 L applied" into a compliance record. The
    /// rate must therefore be strictly positive — the same standard every
    /// measured input on this type is already held to.
    static func totalQuantity(
        rate: Double,
        basis: SprayProductRateBasis,
        context: SprayQuantityContext
    ) -> Double? {
        guard rate.isFinite, rate > 0 else { return nil }
        switch basis {
        case .wholeBlockArea:
            guard context.grossAreaHectares.isFinite, context.grossAreaHectares > 0 else { return nil }
            return rate * context.grossAreaHectares
        case .treatedArea:
            guard let treated = context.treatedAreaHectares, treated.isFinite, treated > 0 else { return nil }
            return rate * treated
        case .per100Litres:
            guard context.carrierLitres.isFinite, context.carrierLitres > 0 else { return nil }
            let factor = context.concentrationFactor.isFinite && context.concentrationFactor > 0
                ? context.concentrationFactor
                : 1.0
            return rate * context.carrierLitres / 100.0 * factor
        case .per100Metres:
            guard let metres = context.rowLengthMetres, metres.isFinite, metres > 0 else { return nil }
            return rate * metres / 100.0
        }
    }

    /// The MEASURED value a basis multiplies against — the "× 10.00 ha" half of
    /// the calculation the operator sees.
    ///
    /// Returned from the engine rather than re-read from screen state so the
    /// explanation and the quantity provably describe the same arithmetic.
    /// `nil` under exactly the same conditions that make `totalQuantity` `nil`.
    static func basisInput(
        basis: SprayProductRateBasis,
        context: SprayQuantityContext
    ) -> Double? {
        switch basis {
        case .wholeBlockArea:
            guard context.grossAreaHectares.isFinite, context.grossAreaHectares > 0 else { return nil }
            return context.grossAreaHectares
        case .treatedArea:
            guard let treated = context.treatedAreaHectares, treated.isFinite, treated > 0 else { return nil }
            return treated
        case .per100Litres:
            guard context.carrierLitres.isFinite, context.carrierLitres > 0 else { return nil }
            return context.carrierLitres
        case .per100Metres:
            guard let metres = context.rowLengthMetres, metres.isFinite, metres > 0 else { return nil }
            return metres
        }
    }
}
