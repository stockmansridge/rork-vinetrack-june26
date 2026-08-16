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

    // MARK: Block attribution (sql/195)

    /// WHICH blocks this application actually treated, in selection order.
    ///
    /// The per-block breakdown of the aggregate geometry above: these blocks'
    /// gross areas sum to `grossAreaHa` and their row lengths to
    /// `canonicalRowLengthMetres`, because both are projected from the same
    /// resolved geometry array. That is what makes "calculated from A+C but
    /// recorded as A+B" unrepresentable rather than merely tested for.
    ///
    /// `nil` means BLOCKS NOT RECORDED — a record written before sql/195. It
    /// never means all blocks, no blocks, the vineyard's current blocks, or the
    /// block containing matching row numbers. `[]` is not a valid state and is
    /// normalised to `nil` on every path, mirroring the sql/195 constraint.
    let blocks: [SprayApplicationBlockSnapshot]?

    // MARK: Application intent (sql/193)
    //
    // Unlike every field above these are not calculated outputs — they are what
    // the operator declared this spray was FOR. They live here rather than in a
    // separate carrier because they share the record's persistence, offline
    // replay and reload path, and because a compliance document has to state
    // intent as well as arithmetic.

    /// What the spray targeted, as stable identifiers.
    ///
    /// `nil` means never recorded (a pre-sql/193 record); `[]` means recorded as
    /// explicitly none. That distinction is load-bearing for the future
    /// Resistance Planner, which must not treat silence as "nothing targeted".
    /// NEVER inferred from the products in the tank.
    let targets: [SprayTarget]?

    /// Where the spray head was aimed. Foliar applications only — a banded or
    /// spreader pass legitimately carries `nil`.
    let sprayHeadTarget: SprayHeadTarget?

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
            && targets == nil && sprayHeadTarget == nil
            && blocks == nil
    }

    /// The treated blocks' stable ids, in selection order. Empty when the
    /// record predates block attribution — test `hasRecordedBlocks` to tell
    /// "unknown" apart from anything else.
    var treatedBlockIds: [String] { blocks?.blockIds ?? [] }

    /// True when this application's treated blocks were genuinely recorded.
    ///
    /// False means unknown, and the UI must say "Blocks not recorded" rather
    /// than showing the vineyard's current blocks as if they were historical.
    var hasRecordedBlocks: Bool { blocks?.isEmpty == false }

    /// True when the operator's target selection was genuinely recorded, so the
    /// UI can distinguish "unknown (historical)" from "none selected".
    var hasRecordedTargets: Bool { (targets?.isEmpty == false) }

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
            // Targets and spray head target are reusable INPUT intent, not
            // geometry-dependent output, so a template keeps them: "my powdery
            // mildew bunch-line spray" is exactly what a template is for.
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
            concentrationFactor: concentrationFactor,
            targets: targets,
            sprayHeadTarget: sprayHeadTarget,
            // Block IDENTITY is reusable intent — "my powdery spray on the home
            // blocks" is exactly what a template is for — but the per-block
            // AREAS and ROW LENGTHS are outputs and must be recalculated, for
            // the same reason the aggregates above are cleared. The operator can
            // still change the selection in the Blocks step, and the new spray
            // freezes whatever they finally chose.
            blocks: blocks?.map(\.identityOnly)
        )
        return configuration.isEmpty ? nil : configuration
    }

    /// This snapshot with its block attribution replaced, every calculated value
    /// left untouched.
    ///
    /// The one supported way to record or CORRECT which blocks an application
    /// treated without disturbing the arithmetic. Used by the manual Spray Record
    /// form, where the operator states the blocks directly and there is no guided
    /// calculation to project from.
    ///
    /// Returns `nil` when the result carries nothing at all, so "never recorded"
    /// keeps its single representation.
    func withBlocks(_ blocks: [SprayApplicationBlockSnapshot]?) -> SprayApplicationSnapshot? {
        let updated = SprayApplicationSnapshot(
            grossAreaHa: grossAreaHa,
            treatedAreaHa: treatedAreaHa,
            applicationMode: applicationMode,
            treatedAreaMethod: treatedAreaMethod,
            bandWidthTotalMetres: bandWidthTotalMetres,
            bandWidthLeftMetres: bandWidthLeftMetres,
            bandWidthRightMetres: bandWidthRightMetres,
            canonicalRowLengthMetres: canonicalRowLengthMetres,
            rowSpacingMetres: rowSpacingMetres,
            geometrySource: geometrySource,
            geometryQuality: geometryQuality,
            carrierVolumeBasis: carrierVolumeBasis,
            totalCarrierLitres: totalCarrierLitres,
            carrierLitresPerHectare: carrierLitresPerHectare,
            diluteLitresPer100m: diluteLitresPer100m,
            appliedLitresPer100m: appliedLitresPer100m,
            concentrationFactor: concentrationFactor,
            targets: targets,
            sprayHeadTarget: sprayHeadTarget,
            blocks: blocks
        )
        return updated.isEmpty ? nil : updated
    }

    // MARK: - Projection from the canonical engine result

    /// Project a finished plan onto the storage columns.
    ///
    /// This is the ONLY way to build a populated snapshot from a calculation.
    /// Calculated values are copied, never recomputed.
    ///
    /// `targets` and `sprayHeadTarget` are passed alongside because they are
    /// operator intent rather than engine output — the planner has no opinion on
    /// them, and putting them INTO the plan would imply they affect the
    /// arithmetic. They are still funnelled through this one initialiser so the
    /// record continues to have exactly one persistence face.
    init(
        plan: SprayApplicationPlan,
        targets: [SprayTarget]? = nil,
        sprayHeadTarget: SprayHeadTarget? = nil
    ) {
        self.targets = targets.map(Self.normalisedTargets)
        self.sprayHeadTarget = sprayHeadTarget
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

        // Attribution is projected from the SAME resolved geometry array the
        // aggregates above were summed from. There is no separate list of
        // selected blocks to fall out of step with the calculation.
        self.blocks = SprayApplicationBlockSnapshot.project(plan.geometry.blocks)

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
        concentrationFactor: Double? = nil,
        targets: [SprayTarget]? = nil,
        sprayHeadTarget: SprayHeadTarget? = nil,
        blocks: [SprayApplicationBlockSnapshot]? = nil
    ) {
        self.targets = targets.map(Self.normalisedTargets)
        self.sprayHeadTarget = sprayHeadTarget
        self.blocks = SprayApplicationBlockSnapshot.normalised(blocks)
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

    /// De-duplicate and order targets so two sprays with the same selection
    /// always serialise to the same array, whatever order the operator tapped.
    private static func normalisedTargets(_ targets: [SprayTarget]) -> [SprayTarget] {
        let selected = Set(targets)
        return SprayTarget.presentationOrder.filter(selected.contains)
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case grossAreaHa, treatedAreaHa, applicationMode, treatedAreaMethod
        case bandWidthTotalMetres, bandWidthLeftMetres, bandWidthRightMetres
        case canonicalRowLengthMetres, rowSpacingMetres, geometrySource, geometryQuality
        case carrierVolumeBasis, totalCarrierLitres, carrierLitresPerHectare
        case diluteLitresPer100m, appliedLitresPer100m, concentrationFactor
        case targets, sprayHeadTarget
        case blocks
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

        // sql/193 deliberately puts NO value CHECK on `targets`, so the vocabulary
        // can expand without a migration. The cost is that this client can meet an
        // identifier a newer build wrote: decode as text and drop what we don't
        // recognise rather than failing the whole spray record. An array that is
        // present but entirely unrecognised stays `[]` (recorded) — not `nil`
        // (never recorded).
        if let rawTargets = try? container.decodeIfPresent([String].self, forKey: .targets) {
            targets = Self.normalisedTargets(rawTargets.compactMap(SprayTarget.from))
        } else {
            targets = nil
        }
        sprayHeadTarget = SprayHeadTarget.from(
            try? container.decodeIfPresent(String.self, forKey: .sprayHeadTarget)
        )

        // Block attribution (sql/195). Absent ⇒ nil ⇒ "blocks not recorded",
        // which is exactly what every pre-195 record must keep reading as. A
        // present-but-malformed array is also treated as unknown rather than
        // partially trusted: attributing a spray to SOME of the blocks it
        // treated would understate a per-block resistance history, and an
        // honest "not recorded" is the safer of the two wrong answers.
        blocks = SprayApplicationBlockSnapshot.normalised(
            try? container.decodeIfPresent([SprayApplicationBlockSnapshot].self, forKey: .blocks)
        )
    }
}
