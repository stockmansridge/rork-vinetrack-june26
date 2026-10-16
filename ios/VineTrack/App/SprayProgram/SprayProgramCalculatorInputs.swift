import Foundation

/// Explicit Program Step inputs only. No inferred water, canopy confirmation or product arithmetic.
nonisolated struct SprayProgramCalculatorInputs: Codable, Hashable, Sendable {
    var canopySize: String? = nil
    var canopyDensity: String? = nil
    var carrierBasis: String? = nil
    var diluteLitresPer100m: Double? = nil
    var appliedLitresPer100m: Double? = nil
    var bandWidthTotalMetres: Double? = nil
    var rowSpacingMetres: Double? = nil

    enum CodingKeys: String, CodingKey {
        case canopySize = "vsp_canopy_size", canopyDensity = "vsp_canopy_density"
        case carrierBasis = "carrier_volume_basis"
        case diluteLitresPer100m = "dilute_litres_per_100m", appliedLitresPer100m = "applied_litres_per_100m"
        case bandWidthTotalMetres = "band_width_total_metres", rowSpacingMetres = "row_spacing_metres"
    }

    /// A configured canopy is a suggestion for today's conditions, not today's confirmation.
    var canopy: SprayCanopySelection? {
        let size = CanopySize.allCases.first { $0.rawValue.caseInsensitiveCompare(canopySize ?? "") == .orderedSame }
        let density = CanopyDensity.allCases.first { $0.rawValue.caseInsensitiveCompare(canopyDensity ?? "") == .orderedSame }
        guard size != nil || density != nil else { return nil }
        return .programSuggested(size: size, density: density)
    }
}

extension SprayProgramCalculatorInputs {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func number(_ key: CodingKeys) -> Double? {
            if let value = try? c.decodeIfPresent(Double.self, forKey: key) { return value }
            return (try? c.decodeIfPresent(String.self, forKey: key)).flatMap(Double.init)
        }
        canopySize = try? c.decodeIfPresent(String.self, forKey: .canopySize)
        canopyDensity = try? c.decodeIfPresent(String.self, forKey: .canopyDensity)
        carrierBasis = try? c.decodeIfPresent(String.self, forKey: .carrierBasis)
        diluteLitresPer100m = number(.diluteLitresPer100m)
        appliedLitresPer100m = number(.appliedLitresPer100m)
        bandWidthTotalMetres = number(.bandWidthTotalMetres)
        rowSpacingMetres = number(.rowSpacingMetres)
    }
}
