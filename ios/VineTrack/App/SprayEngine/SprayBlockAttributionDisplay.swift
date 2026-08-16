import Foundation

/// The ONE rule for turning stored block attribution (sql/195) into text a human
/// reads — on screen, in a PDF, in a CSV cell.
///
/// # Why this is centralised
///
/// Every export faces the same three-way question and must answer it identically,
/// because a spray PDF and a spray CSV describing the same application in
/// different words is a compliance problem, not a cosmetic one.
///
/// # The deterministic display rule
///
/// ```text
/// 1. The id still resolves to a live block  -> that block's CURRENT name
/// 2. The id no longer resolves              -> the STORED blockName snapshot
/// 3. Neither is available                   -> "Unknown block"
/// ```
///
/// Step 1 is deliberately the current name, not the snapshot: after a rename,
/// "North 3" is what the operator will find in the app today, so an export that
/// still said "North Three" would send them looking for a block that no longer
/// appears anywhere. The stored snapshot exists for step 2, which is the case a
/// live lookup cannot serve — an archived or deleted block whose name would
/// otherwise be lost. Readability must not depend on the block still existing.
///
/// Identity is always the id. Names are never matched on, in either direction.
///
/// # Absence
///
/// ``notRecorded`` is the single wording for "this record predates block
/// attribution". Resolving nil attribution NEVER falls back to the vineyard's
/// current blocks: that would turn an honest unknown into a false statement about
/// where a chemical was applied.
///
/// Mirrors the Android `SprayBlockAttributionDisplay`.
nonisolated enum SprayBlockAttributionDisplay {

    /// The single human wording for attribution that was never recorded.
    static let notRecorded = "Blocks not recorded"

    /// Shown when an id resolves to nothing and carried no name snapshot.
    static let unknownBlock = "Unknown block"

    /// Separator for multi-value machine-readable cells.
    ///
    /// `"; "` rather than `","` because these exports are CSV: a comma inside a
    /// cell would force quoting and invite a consumer to split the row on the
    /// wrong character. A semicolon cannot occur in a uuid, so the ID cell stays
    /// unambiguously splittable.
    static let machineSeparator = "; "

    /// One attributed block, resolved for display.
    struct Resolved: Sendable, Hashable {
        let blockId: String
        let name: String
        /// True when the id still resolves to a live block in the vineyard.
        let isLive: Bool
    }

    /// Resolve each attributed block to a display name.
    ///
    /// Returns nil when `blocks` is nil — attribution was never recorded — so
    /// callers must handle the unknown case explicitly rather than receiving an
    /// empty array they might render as "no blocks".
    static func resolve(
        _ blocks: [SprayApplicationBlockSnapshot]?,
        paddocks: [Paddock]
    ) -> [Resolved]? {
        guard let blocks else { return nil }
        // iOS writes `UUID.uuidString` (uppercase) while Postgres and Android use
        // lowercase, so the same block legitimately appears in both spellings.
        // Comparison is therefore case-insensitive — this is normalisation of one
        // identity, not name matching.
        var liveNames: [String: String] = [:]
        for paddock in paddocks {
            liveNames[paddock.id.uuidString.lowercased()] = paddock.name
        }
        return blocks.map { block in
            let live = liveNames[block.blockId.lowercased()]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            let snapshot = block.blockName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            return Resolved(
                blockId: block.blockId,
                name: live ?? snapshot ?? unknownBlock,
                isLive: live != nil
            )
        }
    }

    /// Human-readable summary for a PDF row or a compact table cell:
    /// `"Block A, Block C"`, or ``notRecorded`` when attribution is absent.
    static func summary(
        _ blocks: [SprayApplicationBlockSnapshot]?,
        paddocks: [Paddock]
    ) -> String {
        guard let resolved = resolve(blocks, paddocks: paddocks) else { return notRecorded }
        let joined = resolved.map(\.name).joined(separator: ", ")
        return joined.isEmpty ? notRecorded : joined
    }

    /// Human-readable names for a machine-readable cell, or an EMPTY string when
    /// attribution was never recorded.
    ///
    /// Machine-readable exports use emptiness for unknown rather than the
    /// ``notRecorded`` prose, matching how every other never-recorded spray field
    /// is already exported. A parser must not have to string-match English.
    static func namesCell(
        _ blocks: [SprayApplicationBlockSnapshot]?,
        paddocks: [Paddock]
    ) -> String {
        guard let resolved = resolve(blocks, paddocks: paddocks) else { return "" }
        return resolved
            .map { $0.name.replacingOccurrences(of: ";", with: " ") }
            .joined(separator: machineSeparator)
    }

    /// Stable ids for a machine-readable cell, in the operator's selection order,
    /// or an EMPTY string when attribution was never recorded.
    ///
    /// This is the column a consumer should join on. Names are for people.
    static func idsCell(_ blocks: [SprayApplicationBlockSnapshot]?) -> String {
        guard let blocks else { return "" }
        return blocks.blockIds.joined(separator: machineSeparator)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
