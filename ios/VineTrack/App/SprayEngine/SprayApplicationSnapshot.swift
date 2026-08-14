import Foundation

/// An immutable projection of ONE canonical `SprayApplicationPlan` onto the
/// `spray_records` geometry/carrier columns added by sql/191 + sql/192.
///
/// # Why this type exists
///
/// The rule for the whole spray pipeline is:
///
/// ```text
/// Calculate once through the canonical engine → persist the resulting snapshot.
/// ```
///
/// This type is the *persistence face* of that rule. It performs **no
/// calculation of its own** — every stored property is copied straight off a
/// `SprayApplicationPlan` that the engine already produced. There is
/// deliberately no initialiser that takes loose numbers and derives anything,
/// because that would be a second calculation path and the two could drift.
///
/// # Why it is a snapshot and not a live view
///
/// A completed spray record is a compliance document: it must keep saying what
/// was actually applied even after the vineyard changes underneath it. Block
/// polygons get redrawn, row spacing gets corrected, an operator override gets
/// edited, the vineyard's carrier preference gets switched. None of that may
/// retroactively rewrite what a sprayer put through a nozzle last Tuesday.
///
/// So the values here are frozen at save time and read back verbatim. Nothing
/// downstream re-derives them from current block geometry.
///
/// # Legacy records
///
/// Every property is optional and the whole snapshot is `nil` for any record
/// written before sql/191. Absence is preserved, never guessed: a historical
/// banded spray whose treated area was never measured reads back as `nil`, not
/// as a treated area invented from today's geometry. See `isEmpty`.
nonisolated struct SprayApplicationSnapshot: Codable, Sendable, Hashable {

    // MARK: Application geometry

    /// Total GROSS area of the selected blocks. Never replaced by treated area.
    let grossAreaHa: Double?
    /// The genuinely treated area. `nil` when it was not determinable — for a
    /// banded job that means the band geometry was incomplete, and the UI must
    /// say so rather than fall back to gross.
    let treatedAreaHa: Double?
    let applicationMode: SprayApplicationMode?
    let treatedAreaMethod: SprayTreatedAreaMethod?

    // MARK: Band geometry

    let bandWidthTotalMetres: Double?
    let bandWidthLeftMetres: Double?
    let bandWidthRightMetres: Double?

    // MARK: Canonical row geometry

    /// The row length the calculation actually used, from the canonical
    /// resolver — the same metres the banded treated area and any L/100 m
    /// carrier volume were computed from, so they cannot disagree.
    let canonicalRowLengthMetres: Double?
    let rowSpacingMetres: Double?
    let geometrySource: SprayGeometrySource?
    let geometryQuality: SprayGeometryQuality?

    // MARK: Carrier volume

    let carrierVolumeBasis: SprayCarrierBasis?
    let totalCarrierLitres: Double?
    let carrierLitresPerHectare: Double?
    let diluteLitresPer100m: Double?
    let appliedLitresPer100m: Double?
    let concentrationFactor: Double?

    /// True when no field carries a value — the shape a pre-sql/191 record
    /// decodes to. Callers persist `nil` rather than a row of NULLs so
    /// "never recorded" stays distinguishable from "recorded as zero".
    var isEmpty: Bool {
        grossAreaHa == nil && treatedAreaHa == nil && applicationMode == nil
            && treatedAreaMethod == nil && bandWidthTotalMetres == nil
            && bandWidthLeftMetres == nil && bandWidthRightMetres == nil
            && canonicalRowLengthMetres == nil && rowSpacingMetres == nil
            && geometrySource == nil && geometryQuality == nil
            && carrierVolumeBasis == nil && totalCarrierLitres == nil
            && carrierLitresPerHectare == nil && diluteLitresPer100m == nil
            && appliedLitresPer100m == nil && concentrationFactor == nil
    }

    /// True when this snapshot records a banded application whose treated area
    /// is genuinely known. Lets the UI separate "banded, 2.5 ha treated" from
    /// "banded, geometry unavailable" without re-deriving anything.
    var hasGenuineTreatedArea: Bool {
        treatedAreaHa != nil && treatedAreaMethod != nil && treatedAreaMethod != .unavailable
    }

    // MARK: - Template configuration

    /// Strip this snapshot down to the operator's reusable CONFIGURATION,
    /// discarding every geometry-dependent calculated OUTPUT.
    ///
    /// A template must capture *input intent*, not *historical output*. Freezing
    /// a 31,250 m row length into a template would mean a spray created from it
    /// next season silently reuses last season's geometry — even after blocks
    /// were resurveyed or different blocks were selected. So when a template is
    /// opened for a new spray the flow is:
    ///
    /// ```text
    /// Template inputs → current canonical geometry → new calculation snapshot
    /// ```
    ///
    /// KEPT (reusable inputs the operator chose):
    /// `applicationMode`, the three band widths, `carrierVolumeBasis`,
    /// `diluteLitresPer100m`, `appliedLitresPer100m`, `concentrationFactor`,
    /// and `carrierLitresPerHectare` **only** in `l_per_ha` mode, where it is
    /// the rate the operator typed rather than a derived figure.
    ///
    /// CLEARED (recalculated per spray from current geometry):
    /// `grossAreaHa`, `treatedAreaHa`, `treatedAreaMethod`,
    /// `canonicalRowLengthMetres`, `rowSpacingMetres`, `geometrySource`,
    /// `geometryQuality`, `totalCarrierLitres`, and `carrierLitresPerHectare`
    /// in `l_per_100m` mode, where it is derived from row spacing.
    func templateConfiguration() -> SprayApplicationSnapshot? {
        // In L/ha mode the per-hectare figure IS the operator's entered rate and
        // is reusable. In L/100 m mode it was derived from row spacing, so it is
        // an output and must be recalculated against the new blocks.
        let reusableLitresPerHectare = carrierVolumeBasis == .litresPerHectare
            ? carrierLitresPerHectare
            : nil
        let configuration = SprayApplicationSnapshot(
            grossAreaHa: nil,
            treatedAreaHa: nil,
            applicationMode: applicationMode,
            treatedAreaMethod: nil,
            bandWidthTotalMetres: bandWidthTotalMetres,
            bandWidthLeftMetres: bandWidthLeftMetres,
            bandWidthRightMetres: bandWidthRightMetres,
            canonicalRowLengthMetres: nil,
            rowSpacingMetres: nil,
            geometrySource: nil,
            geometryQuality: nil,
            carrierVolumeBasis: carrierVolumeBasis,
            totalCarrierLitres: nil,
            carrierLitresPerHectare: reusableLitresPerHectare,
            diluteLitresPer100m: diluteLitresPer100m,
            appliedLitresPer100m: appliedLitresPer100m,
            concentrationFactor: concentrationFactor
        )
        return configuration.isEmpty ? nil : configuration
    }

    // MARK: - Projection from the canonical engine result

    /// Project a finished plan onto the storage columns.
    ///
    /// This is the ONLY way to build a populated snapshot from a calculation.
    /// Values are copied, never recomputed.
    init(plan: SprayApplicationPlan) {
        self.grossAreaHa = Self.nonNegative(plan.treatedArea.grossAreaHectares)
        self.treatedAreaHa = Self.nonNegative(plan.treatedArea.treatedAreaHectares)
        self.applicationMode = plan.mode
        self.treatedAreaMethod = plan.treatedArea.method

        self.bandWidthTotalMetres = Self.positive(plan.treatedArea.bandWidth?.totalMetres)
        self.bandWidthLeftMetres = Self.nonNegative(plan.treatedArea.bandWidth?.leftMetres)
        self.bandWidthRightMetres = Self.nonNegative(plan.treatedArea.bandWidth?.rightMetres)

        self.canonicalRowLengthMetres = Self.positive(plan.geometry.totalRowLengthMetres)
        self.rowSpacingMetres = Self.positive(plan.geometry.uniformRowSpacingMetres)
        self.geometrySource = plan.geometry.source
        self.geometryQuality = plan.geometry.quality

        self.carrierVolumeBasis = plan.carrier.basis
        self.totalCarrierLitres = Self.nonNegative(plan.carrier.totalLitres)
        self.carrierLitresPerHectare = Self.nonNegative(plan.carrier.litresPerHectare)
        self.diluteLitresPer100m = Self.positive(plan.carrier.diluteLitresPer100Metres)
        self.appliedLitresPer100m = Self.positive(plan.carrier.appliedLitresPer100Metres)
        self.concentrationFactor = Self.positive(plan.carrier.concentrationFactor)
    }

    /// Field-wise initialiser used by the backend decoders and by tests. Kept
    /// internal to persistence mapping — feature code builds snapshots from a
    /// plan so there is only ever one calculation path.
    init(
        grossAreaHa: Double? = nil,
        treatedAreaHa: Double? = nil,
        applicationMode: SprayApplicationMode? = nil,
        treatedAreaMethod: SprayTreatedAreaMethod? = nil,
        bandWidthTotalMetres: Double? = nil,
        bandWidthLeftMetres: Double? = nil,
        bandWidthRightMetres: Double? = nil,
        canonicalRowLengthMetres: Double? = nil,
        rowSpacingMetres: Double? = nil,
        geometrySource: SprayGeometrySource? = nil,
        geometryQuality: SprayGeometryQuality? = nil,
        carrierVolumeBasis: SprayCarrierBasis? = nil,
        totalCarrierLitres: Double? = nil,
        carrierLitresPerHectare: Double? = nil,
        diluteLitresPer100m: Double? = nil,
        appliedLitresPer100m: Double? = nil,
        concentrationFactor: Double? = nil
    ) {
        self.grossAreaHa = grossAreaHa
        self.treatedAreaHa = treatedAreaHa
        self.applicationMode = applicationMode
        self.treatedAreaMethod = treatedAreaMethod
        self.bandWidthTotalMetres = bandWidthTotalMetres
        self.bandWidthLeftMetres = bandWidthLeftMetres
        self.bandWidthRightMetres = bandWidthRightMetres
        self.canonicalRowLengthMetres = canonicalRowLengthMetres
        self.rowSpacingMetres = rowSpacingMetres
        self.geometrySource = geometrySource
        self.geometryQuality = geometryQuality
        self.carrierVolumeBasis = carrierVolumeBasis
        self.totalCarrierLitres = totalCarrierLitres
        self.carrierLitresPerHectare = carrierLitresPerHectare
        self.diluteLitresPer100m = diluteLitresPer100m
        self.appliedLitresPer100m = appliedLitresPer100m
        self.concentrationFactor = concentrationFactor
    }

    // MARK: - Column sanity
    //
    // sql/191 constrains several columns to be strictly positive, because a
    // band width or row length of 0 is not a measurement — absence must be
    // NULL so it can never dose a tank. These helpers make the client honour
    // that contract instead of relying on the database to reject the write.

    /// Strictly-positive columns: 0, negatives and non-finite values become nil.
    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Non-negative columns: negatives and non-finite values become nil.
    private static func nonNegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case grossAreaHa, treatedAreaHa, applicationMode, treatedAreaMethod
        case bandWidthTotalMetres, bandWidthLeftMetres, bandWidthRightMetres
        case canonicalRowLengthMetres, rowSpacingMetres, geometrySource, geometryQuality
        case carrierVolumeBasis, totalCarrierLitres, carrierLitresPerHectare
        case diluteLitresPer100m, appliedLitresPer100m, concentrationFactor
    }

    /// Tolerant decode: an unrecognised enum value (for example a
    /// `geometry_source` a newer build introduced) degrades that single field
    /// to `nil` instead of failing the whole spray record.
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        grossAreaHa = try container.decodeIfPresent(Double.self, forKey: .grossAreaHa)
        treatedAreaHa = try container.decodeIfPresent(Double.self, forKey: .treatedAreaHa)
        applicationMode = try? container.decodeIfPresent(SprayApplicationMode.self, forKey: .applicationMode)
        treatedAreaMethod = try? container.decodeIfPresent(SprayTreatedAreaMethod.self, forKey: .treatedAreaMethod)
        bandWidthTotalMetres = try container.decodeIfPresent(Double.self, forKey: .bandWidthTotalMetres)
        bandWidthLeftMetres = try container.decodeIfPresent(Double.self, forKey: .bandWidthLeftMetres)
        bandWidthRightMetres = try container.decodeIfPresent(Double.self, forKey: .bandWidthRightMetres)
        canonicalRowLengthMetres = try container.decodeIfPresent(Double.self, forKey: .canonicalRowLengthMetres)
        rowSpacingMetres = try container.decodeIfPresent(Double.self, forKey: .rowSpacingMetres)
        geometrySource = try? container.decodeIfPresent(SprayGeometrySource.self, forKey: .geometrySource)
        geometryQuality = try? container.decodeIfPresent(SprayGeometryQuality.self, forKey: .geometryQuality)
        carrierVolumeBasis = try? container.decodeIfPresent(SprayCarrierBasis.self, forKey: .carrierVolumeBasis)
        totalCarrierLitres = try container.decodeIfPresent(Double.self, forKey: .totalCarrierLitres)
        carrierLitresPerHectare = try container.decodeIfPresent(Double.self, forKey: .carrierLitresPerHectare)
        diluteLitresPer100m = try container.decodeIfPresent(Double.self, forKey: .diluteLitresPer100m)
        appliedLitresPer100m = try container.decodeIfPresent(Double.self, forKey: .appliedLitresPer100m)
        concentrationFactor = try container.decodeIfPresent(Double.self, forKey: .concentrationFactor)
    }
}
