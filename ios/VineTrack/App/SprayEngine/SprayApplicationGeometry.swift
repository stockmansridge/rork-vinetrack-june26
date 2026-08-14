import Foundation

/// Where a block's applicable row/trellis length came from.
///
/// Recorded on every result so a spray quantity can always be traced back to
/// the geometry that produced it. This is the ONLY place spray calculations are
/// allowed to decide what "row length" means.
nonisolated enum SprayGeometrySource: String, Sendable, Codable, CaseIterable {
    /// The operator's explicit row-length correction (`rowLengthOverride`).
    /// Highest authority: a human deliberately overruled the geometry.
    case operatorOverride = "operator_override"
    /// Summed length of the block's actual mapped rows.
    case mappedRows = "mapped_rows"
    /// Deprecated SQL 191 spelling of `operatorOverride`. Never written by new
    /// code; retained so rows already persisted with it still decode.
    case storedRowLength = "stored_row_length"
    /// Derived from block area and row spacing: `areaHa × 10_000 / rowSpacing`.
    case derivedFromAreaAndSpacing = "derived_from_area_and_spacing"
    /// Nothing reliable enough to calculate a spray quantity from.
    case unavailable = "unavailable"
}

/// How much the geometry can be trusted. Drives whether the UI may present a
/// quantity plainly, must qualify it, or must refuse to calculate.
nonisolated enum SprayGeometryQuality: String, Sendable, Codable {
    /// Measured or explicitly stored by the operator.
    case authoritative
    /// Arithmetically derived from other valid stored values.
    case derived
    /// Cannot be determined — spray quantities must not be calculated.
    case incomplete
}

/// Why geometry could not be resolved. Each case names the ONE thing the
/// grower has to fix, mirroring the `PaddockRowVineCount.Unavailable` pattern.
nonisolated enum SprayGeometryUnavailable: String, Sendable, Codable {
    case missingRowSpacing = "missing_row_spacing"
    case missingArea = "missing_area"
    case missingGeometry = "missing_geometry"

    var message: String {
        switch self {
        case .missingRowSpacing:
            return "Set row spacing in block details to calculate spray volumes."
        case .missingArea:
            return "Map this block's boundary to calculate spray volumes."
        case .missingGeometry:
            return "Map this block's rows, or enter a row length in block details."
        }
    }
}

/// The raw per-block numbers the geometry engine needs.
///
/// Deliberately decoupled from `Paddock` so the contract can be tested with
/// explicit fixtures and shared with the portal without dragging in the data
/// store. Use `SprayBlockInput.from(paddock:)` for live data.
nonisolated struct SprayBlockInput: Sendable, Hashable {
    let blockId: String
    /// Gross block area in hectares. `nil`/non-positive means unmapped.
    let grossAreaHectares: Double?
    /// Summed length of mapped rows, when the block actually has rows.
    let mappedRowLengthMetres: Double?
    /// The operator's explicit row-length correction, when they entered one.
    let operatorRowLengthOverrideMetres: Double?
    /// Row spacing in metres. `nil` means genuinely unknown — NEVER defaulted.
    let rowSpacingMetres: Double?
    let rowCount: Int?

    init(
        blockId: String,
        grossAreaHectares: Double?,
        mappedRowLengthMetres: Double? = nil,
        operatorRowLengthOverrideMetres: Double? = nil,
        rowSpacingMetres: Double? = nil,
        rowCount: Int? = nil
    ) {
        self.blockId = blockId
        self.grossAreaHectares = grossAreaHectares
        self.mappedRowLengthMetres = mappedRowLengthMetres
        self.operatorRowLengthOverrideMetres = operatorRowLengthOverrideMetres
        self.rowSpacingMetres = rowSpacingMetres
        self.rowCount = rowCount
    }
}

/// Resolved geometry for ONE block.
nonisolated struct SprayBlockGeometry: Sendable, Hashable {
    let blockId: String
    let grossAreaHectares: Double
    /// Applicable row/trellis length. `nil` when it could not be resolved.
    let rowLengthMetres: Double?
    let rowSpacingMetres: Double?
    let rowCount: Int?
    let source: SprayGeometrySource
    let quality: SprayGeometryQuality
    let unavailableReason: SprayGeometryUnavailable?

    var isUsable: Bool { rowLengthMetres != nil && quality != .incomplete }
}

/// Resolved geometry for the whole application (all selected blocks).
///
/// This is THE canonical geometry result. Banded treated-area and L/100 m
/// carrier-volume calculations both read `totalRowLengthMetres` from here, so
/// the two can never disagree.
nonisolated struct SprayApplicationGeometry: Sendable, Hashable {
    let blocks: [SprayBlockGeometry]

    var blockIds: [String] { blocks.map(\.blockId) }

    /// Gross (whole-block) hectares across the selection.
    var grossAreaHectares: Double { blocks.reduce(0) { $0 + $1.grossAreaHectares } }

    /// Total applicable row/trellis metres, or `nil` when ANY selected block
    /// could not be resolved. Partial totals are refused deliberately: a
    /// silently short row length under-doses the whole tank mix.
    var totalRowLengthMetres: Double? {
        guard !blocks.isEmpty, blocks.allSatisfy(\.isUsable) else { return nil }
        return blocks.reduce(0) { $0 + ($1.rowLengthMetres ?? 0) }
    }

    var rowCount: Int? {
        let counts = blocks.compactMap(\.rowCount)
        return counts.count == blocks.count && !counts.isEmpty ? counts.reduce(0, +) : nil
    }

    /// Row spacing for the selection, but ONLY when every block shares the same
    /// spacing (within 1 mm). Mixed spacings return `nil` rather than an
    /// average, because an averaged spacing produces a derived L/ha that is
    /// wrong for every block in the set.
    var uniformRowSpacingMetres: Double? {
        let spacings = blocks.compactMap(\.rowSpacingMetres)
        guard spacings.count == blocks.count, let first = spacings.first else { return nil }
        return spacings.allSatisfy { abs($0 - first) < 0.001 } ? first : nil
    }

    /// The weakest link across the selection.
    var quality: SprayGeometryQuality {
        if blocks.isEmpty { return .incomplete }
        if blocks.contains(where: { $0.quality == .incomplete }) { return .incomplete }
        return blocks.contains(where: { $0.quality == .derived }) ? .derived : .authoritative
    }

    /// The single source when all blocks agree, otherwise the weakest one.
    var source: SprayGeometrySource {
        guard let first = blocks.first?.source else { return .unavailable }
        if blocks.allSatisfy({ $0.source == first }) { return first }
        if blocks.contains(where: { $0.source == .unavailable }) { return .unavailable }
        return blocks.contains(where: { $0.source == .derivedFromAreaAndSpacing })
            ? .derivedFromAreaAndSpacing
            : .mappedRows
    }

    var isUsable: Bool { totalRowLengthMetres != nil }

    /// Blocks that stopped the selection from being calculable, with reasons.
    var unresolvedBlocks: [SprayBlockGeometry] { blocks.filter { !$0.isUsable } }

    var unavailableMessage: String? {
        guard !isUsable else { return nil }
        if blocks.isEmpty { return "Select at least one block." }
        return unresolvedBlocks.first?.unavailableReason?.message
            ?? SprayGeometryUnavailable.missingGeometry.message
    }
}

/// THE canonical row/trellis-length engine for VineTrack.
///
/// Resolution hierarchy, highest first:
///  1. Explicit operator override (`rowLengthOverride`) — authoritative.
///  2. Actual mapped row geometry (`mappedRowLengthMetres`) — authoritative.
///  3. Derived from gross area × valid row spacing — derived.
///  4. Otherwise an explicit incomplete state.
///
/// PRECEDENCE RATIONALE: the operator override outranks mapped geometry
/// because VineTrack has always presented it as a deliberate correction, not
/// a cache. The block editor files it under "Calculation Overrides", badges it
/// "Manual override active", offers a Reset, and tells the grower it exists
/// for "more accurate water usage and yield calculations". It is only ever
/// written from that field.
///
/// This makes the canonical engine AGREE with the long-standing legacy
/// accessor `Paddock.effectiveTotalRowLength`
/// (`rowLengthOverride ?? totalRowLengthMetres`), so spray, irrigation, vine
/// counts and pruning all resolve the same block to the same metres. The
/// engine is a strict superset: it adds the derived and incomplete tiers that
/// the legacy accessor cannot express (it collapses both to 0).
///
/// There is no separate "stored calculated row length" in VineTrack — no such
/// column exists — so the audit's tiers 1 and 3 are the same field and
/// collapse into tier 1 here.
nonisolated enum SprayGeometryResolver {

    /// Metres of row per hectare at a given spacing: `10_000 / rowSpacing`.
    static let squareMetresPerHectare: Double = 10_000

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Resolves ONE block against the hierarchy above.
    static func resolve(_ input: SprayBlockInput) -> SprayBlockGeometry {
        let area = positive(input.grossAreaHectares) ?? 0
        let spacing = positive(input.rowSpacingMetres)

        func result(
            _ length: Double?,
            _ source: SprayGeometrySource,
            _ quality: SprayGeometryQuality,
            _ reason: SprayGeometryUnavailable? = nil
        ) -> SprayBlockGeometry {
            SprayBlockGeometry(
                blockId: input.blockId,
                grossAreaHectares: area,
                rowLengthMetres: length,
                rowSpacingMetres: spacing,
                rowCount: input.rowCount,
                source: source,
                quality: quality,
                unavailableReason: reason
            )
        }

        // 1. Explicit operator override — a human overruled the geometry.
        if let override = positive(input.operatorRowLengthOverrideMetres) {
            return result(override, .operatorOverride, .authoritative)
        }
        // 2. Mapped row geometry.
        if let mapped = positive(input.mappedRowLengthMetres) {
            return result(mapped, .mappedRows, .authoritative)
        }
        // 3. Derived from area and spacing.
        if let spacing, area > 0 {
            return result(area * squareMetresPerHectare / spacing, .derivedFromAreaAndSpacing, .derived)
        }
        // 4. Refuse to guess.
        let reason: SprayGeometryUnavailable = spacing == nil ? .missingRowSpacing : .missingArea
        return result(nil, .unavailable, .incomplete, reason)
    }

    /// Resolves the full selection.
    static func resolve(_ inputs: [SprayBlockInput]) -> SprayApplicationGeometry {
        SprayApplicationGeometry(blocks: inputs.map(resolve))
    }
}

extension SprayBlockInput {
    /// Adapts a live `Paddock` to the geometry contract.
    ///
    /// `mappedRowLengthMetres` is taken only when the block genuinely has mapped
    /// rows, so an empty `rows` array cannot masquerade as a measured zero.
    ///
    /// Row spacing comes from `authoritativeRowSpacingMetres`, so a block whose
    /// spacing was never entered resolves to `missingRowSpacing` instead of
    /// silently borrowing the 2.5 m legacy display fallback.
    static func from(paddock: Paddock) -> SprayBlockInput {
        let mapped: Double? = paddock.rows.isEmpty ? nil : paddock.totalRowLengthMetres
        return SprayBlockInput(
            blockId: paddock.id.uuidString,
            grossAreaHectares: paddock.areaHectares,
            mappedRowLengthMetres: mapped,
            operatorRowLengthOverrideMetres: paddock.rowLengthOverride,
            rowSpacingMetres: paddock.authoritativeRowSpacingMetres,
            rowCount: paddock.rows.isEmpty ? nil : paddock.rows.count
        )
    }
}
