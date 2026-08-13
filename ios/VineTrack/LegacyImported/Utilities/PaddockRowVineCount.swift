import Foundation

/// THE per-row vine-count contract (sql/188) — the Swift twin of the Kotlin
/// `PaddockRowVineCount`. Both platforms and the portal MUST produce identical
/// numbers from identical inputs.
///
/// Canonical `paddocks.rows` element:
/// ```json
/// {
///   "id": "uuid",
///   "number": 12,
///   "startPoint": { "latitude": .., "longitude": .. },
///   "endPoint":   { "latitude": .., "longitude": .. },
///   "vineCountOverride": 182
/// }
/// ```
///
/// `vineCountOverride` is OPTIONAL. Rows without it keep the calculated
/// estimate, so every row ever written stays valid.
///
/// RELATIONSHIP TO THE BLOCK-LEVEL OVERRIDE (unchanged, do not conflate):
/// * `paddocks.vine_count_override` — the BLOCK total. Still drives water,
///   spray, fertiliser and yield estimates exactly as before.
/// * `rows[].vineCountOverride` — per-ROW truth. Drives row-based work,
///   specifically the pruning piece-rate quantity.
/// Neither writes to the other.
nonisolated enum PaddockRowVineCount {

    /// A manual count above this is a typo, not a row.
    static let maxOverride: Int = 100_000

    /// Normalises a decoded/entered override to the stored contract: a whole
    /// POSITIVE number, or nil for "no override". Zero and negatives are not
    /// overrides — they are absence.
    static func sanitiseOverride(_ value: Int?) -> Int? {
        guard let value, value > 0, value <= maxOverride else { return nil }
        return value
    }

    /// Parses user input for the override field.
    /// * blank (or whitespace only) → `.cleared` (no override)
    /// * whole number 1…`maxOverride` → `.valid`
    /// * anything else (negative, zero, decimal, junk) → `.invalid`
    nonisolated enum OverrideInput: Equatable, Sendable {
        case cleared
        case valid(Int)
        case invalid(String)

        var value: Int? {
            if case let .valid(v) = self { return v }
            return nil
        }

        var isInvalid: Bool {
            if case .invalid = self { return true }
            return false
        }

        var message: String? {
            if case let .invalid(message) = self { return message }
            return nil
        }
    }

    static func parseOverride(_ text: String) -> OverrideInput {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .cleared }
        if trimmed.contains(".") || trimmed.contains(",") {
            return .invalid("Enter whole vines — part of a vine isn't a vine.")
        }
        guard let value = Int(trimmed) else {
            return .invalid("Enter a whole number of vines.")
        }
        if value <= 0 {
            return .invalid("Enter a vine count greater than zero, or leave it blank.")
        }
        if value > maxOverride {
            return .invalid("That's more than \(maxOverride.formatted()) vines — check the number.")
        }
        return .valid(value)
    }

    // MARK: - The automatic calculation

    /// Why a row has no calculated vine count. There are exactly two reasons,
    /// and each one names the single thing the grower must fix.
    nonisolated enum Unavailable: String, Equatable, Sendable {
        /// The block has no usable vine spacing.
        case missingVineSpacing
        /// The row has no usable length (unmapped or zero-length geometry).
        case invalidGeometry

        var message: String {
            switch self {
            case .missingVineSpacing:
                return "Set vine spacing in block details to calculate vines."
            case .invalidGeometry:
                return "Map this row on the block boundary to calculate vines."
            }
        }
    }

    /// The outcome of the automatic calculation. Modelled explicitly so "we
    /// cannot calculate this" can never be confused with "this row has no
    /// vines" — a `0` would be a lie about the vineyard.
    nonisolated enum Calculation: Equatable, Sendable {
        case available(Int)
        case unavailable(Unavailable)

        /// The vine count when one could be calculated, else nil.
        var value: Int? {
            if case let .available(count) = self { return count }
            return nil
        }

        /// The reason there is no number, else nil.
        var unavailable: Unavailable? {
            if case let .unavailable(reason) = self { return reason }
            return nil
        }

        /// The subtle hint to show beside a "—", else nil.
        var message: String? { unavailable?.message }
    }

    /// Rounds a raw vines-per-row quotient to whole vines, half away from zero
    /// — the SAME rule as the Kotlin twin, so the two platforms can never
    /// report a different vine.
    static func roundVines(_ raw: Double) -> Int {
        guard raw.isFinite else { return 0 }
        return Int(raw.rounded(.toNearestOrAwayFromZero))
    }

    /// THE automatic per-row estimate, with its reason when it cannot be made:
    ///
    /// ```text
    /// calculatedVineCount = round(row length in metres ÷ vine spacing in metres)
    ///     250 m ÷ 1.5 m = 166.67 → 167 vines
    /// ```
    ///
    /// Both inputs come from data the app already holds — the row's own
    /// start/end geometry and the BLOCK's vine spacing — so a grower never has
    /// to type anything to get a vine count.
    ///
    /// Note this is the ROW rule. The block-level `Paddock.estimatedVineCount`
    /// keeps its own long-standing truncation of the block's total row length;
    /// the two are deliberately independent (see sql/188).
    static func calculation(rowLengthMetres: Double, vineSpacing: Double?) -> Calculation {
        guard let vineSpacing, vineSpacing.isFinite, vineSpacing > 0 else {
            return .unavailable(.missingVineSpacing)
        }
        guard rowLengthMetres.isFinite, rowLengthMetres > 0 else {
            return .unavailable(.invalidGeometry)
        }
        return .available(roundVines(rowLengthMetres / vineSpacing))
    }

    /// The automatic per-row estimate, or nil when it genuinely cannot be
    /// calculated. NEVER returns 0 as a stand-in for "unknown".
    static func calculated(rowLengthMetres: Double, vineSpacing: Double?) -> Int? {
        calculation(rowLengthMetres: rowLengthMetres, vineSpacing: vineSpacing).value
    }

    /// THE rule: manual override wins, otherwise the calculated estimate.
    /// Nil only when there is no override AND no calculable estimate.
    static func effective(override: Int?, rowLengthMetres: Double, vineSpacing: Double?) -> Int? {
        if let override = sanitiseOverride(override) { return override }
        return calculated(rowLengthMetres: rowLengthMetres, vineSpacing: vineSpacing)
    }
}

/// Row-identity preservation across block geometry regeneration.
///
/// The block editor rebuilds every row from the boundary + direction + count on
/// each save. Before sql/188 that minted a BRAND NEW `PaddockRow.id` every time,
/// which silently detached anything keyed on row identity — pruning progress
/// (`pruning_row_segments.paddock_row_id`, sql/112) included.
///
/// `preserveIdentity` re-attaches regenerated rows to the block's existing rows
/// by their REAL-WORLD row number — the identifier the grower actually uses and
/// the one the editor keeps stable — carrying across:
///   * the existing stable row `id`, and
///   * the row's manual `vineCountOverride`.
///
/// Rows that genuinely did not exist before (the block grew) keep their fresh
/// id and have no override. Rows that disappeared are simply gone.
nonisolated enum PaddockRowRegeneration {

    /// Re-applies existing identity + manual counts onto freshly generated rows.
    ///
    /// - Parameters:
    ///   - regenerated: rows just built from the new geometry.
    ///   - existing: the block's currently stored rows.
    static func preserveIdentity(regenerated: [PaddockRow], existing: [PaddockRow]) -> [PaddockRow] {
        guard !existing.isEmpty else { return regenerated }
        var byNumber: [Int: PaddockRow] = [:]
        for row in existing where byNumber[row.number] == nil {
            byNumber[row.number] = row
        }
        return regenerated.map { row in
            guard let match = byNumber[row.number] else { return row }
            return PaddockRow(
                id: match.id,
                number: row.number,
                startPoint: row.startPoint,
                endPoint: row.endPoint,
                vineCountOverride: match.vineCountOverride
            )
        }
    }

    /// Applies an edited map of manual counts (keyed by ROW NUMBER — stable
    /// across regeneration) onto a set of rows. A number missing from the map
    /// clears that row's override.
    static func applyOverrides(_ overrides: [Int: Int], to rows: [PaddockRow]) -> [PaddockRow] {
        rows.map { row in
            var copy = row
            copy.vineCountOverride = PaddockRowVineCount.sanitiseOverride(overrides[row.number])
            return copy
        }
    }

    /// Extracts the current manual counts keyed by row number.
    static func overrides(from rows: [PaddockRow]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for row in rows {
            if let value = row.vineCountOverride { map[row.number] = value }
        }
        return map
    }
}
