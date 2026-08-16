import Foundation

/// ONE block that an application actually treated, frozen at save time.
///
/// # What this is for
///
/// A completed spray record has always known its `vineyardId` and nothing more.
/// The operator's Blocks-step selection reached the canonical geometry engine,
/// every block's area and row length was resolved individually, and then the
/// whole per-block array was collapsed into aggregate totals and discarded. This
/// type is the durable form of that array (sql/195).
///
/// # Identity is the id, never the name
///
/// `blockId` is the stable `Paddock` UUID and is the ONLY identity. `blockName`
/// is a display snapshot kept so an export, or a block that was later renamed or
/// deleted, still reads sensibly. Matching on names is never correct: two
/// vineyards may reuse a name, and a rename must not move history.
///
/// # It extends the geometry contract rather than duplicating it
///
/// Every measurement here is copied verbatim from the `SprayBlockGeometry` the
/// calculation used, so the per-block values reconcile with the sql/191
/// aggregates by construction: the gross areas sum to `grossAreaHa` and the row
/// lengths sum to `canonicalRowLengthMetres`. There is no second geometry path.
///
/// # There is deliberately no per-block treated area
///
/// Treated area is a banded-application figure the engine computes ONCE from the
/// selection's total row length. Splitting it per block here would be a second
/// implementation of the band arithmetic, and the two could drift. Per-block
/// gross area and row length are direct copies; a per-block treated area would
/// be a new derivation, so it is not stored. Read `treatedAreaHa` on the parent
/// snapshot, which remains the single authority.
nonisolated struct SprayApplicationBlockSnapshot: Codable, Sendable, Hashable, Identifiable {

    /// Stable `Paddock` UUID string. THE identity of this attribution.
    let blockId: String
    /// Display-name snapshot at application time. Never used for matching.
    let blockName: String?

    /// Gross (whole-block) hectares for this block, copied from the geometry.
    let grossAreaHa: Double?
    /// Applicable row/trellis metres for this block, copied from the geometry.
    let rowLengthMetres: Double?
    let rowSpacingMetres: Double?
    let rowCount: Int?
    let geometrySource: SprayGeometrySource?
    let geometryQuality: SprayGeometryQuality?

    nonisolated var id: String { blockId }

    init(
        blockId: String,
        blockName: String? = nil,
        grossAreaHa: Double? = nil,
        rowLengthMetres: Double? = nil,
        rowSpacingMetres: Double? = nil,
        rowCount: Int? = nil,
        geometrySource: SprayGeometrySource? = nil,
        geometryQuality: SprayGeometryQuality? = nil
    ) {
        self.blockId = blockId
        self.blockName = Self.trimmed(blockName)
        self.grossAreaHa = Self.nonNegative(grossAreaHa)
        self.rowLengthMetres = Self.positive(rowLengthMetres)
        self.rowSpacingMetres = Self.positive(rowSpacingMetres)
        self.rowCount = rowCount.flatMap { $0 > 0 ? $0 : nil }
        self.geometrySource = geometrySource
        self.geometryQuality = geometryQuality
    }

    /// Project ONE resolved block geometry onto its persisted form.
    ///
    /// Values are copied, never recomputed — the same rule the parent snapshot
    /// follows.
    init(geometry: SprayBlockGeometry) {
        self.init(
            blockId: geometry.blockId,
            blockName: geometry.blockName,
            grossAreaHa: geometry.grossAreaHectares,
            rowLengthMetres: geometry.rowLengthMetres,
            rowSpacingMetres: geometry.rowSpacingMetres,
            rowCount: geometry.rowCount,
            geometrySource: geometry.source,
            geometryQuality: geometry.quality
        )
    }

    /// This block's IDENTITY only, with every geometry-dependent output cleared.
    ///
    /// What a template keeps. A template must carry *which blocks the operator
    /// intends* without freezing one season's areas and row lengths, because the
    /// new spray recalculates those from current geometry — and may well run
    /// against a different selection entirely.
    var identityOnly: SprayApplicationBlockSnapshot {
        SprayApplicationBlockSnapshot(blockId: blockId, blockName: blockName)
    }

    /// A name to show, falling back to a clearly non-authoritative placeholder
    /// when the block was recorded before names were snapshotted.
    var displayName: String {
        guard let blockName, !blockName.isEmpty else { return "Unnamed block" }
        return blockName
    }

    // MARK: - Normalisation

    /// De-duplicate a selection by `blockId`, keeping first occurrence and
    /// order.
    ///
    /// A block appearing twice in one application would be counted twice by a
    /// per-block resistance history, so this runs on every write path. Returns
    /// `nil` for an empty selection: absence of attribution is `nil` and never
    /// `[]`, matching the sql/195 rule that rejects an empty array.
    static func normalised(_ blocks: [SprayApplicationBlockSnapshot]?) -> [SprayApplicationBlockSnapshot]? {
        guard let blocks else { return nil }
        var seen = Set<String>()
        let unique = blocks
            .filter { !$0.blockId.trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { seen.insert($0.blockId).inserted }
        return unique.isEmpty ? nil : unique
    }

    /// Project a whole resolved selection, normalised.
    static func project(_ geometry: [SprayBlockGeometry]) -> [SprayApplicationBlockSnapshot]? {
        normalised(geometry.map(SprayApplicationBlockSnapshot.init(geometry:)))
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func nonNegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case blockId, blockName, grossAreaHa, rowLengthMetres
        case rowSpacingMetres, rowCount, geometrySource, geometryQuality
    }

    /// Tolerant decode: an unrecognised enum value degrades that one field to
    /// `nil` rather than failing the whole spray record. A missing or blank
    /// `blockId` throws, because a block snapshot with no identity is not an
    /// honest "unknown" — it is corruption, and silently dropping it would
    /// shrink an application's attribution without saying so.
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = try container.decode(String.self, forKey: .blockId)
        let id = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .blockId,
                in: container,
                debugDescription: "A treated-block snapshot must carry a non-empty blockId."
            )
        }
        blockId = id
        blockName = Self.trimmed(try container.decodeIfPresent(String.self, forKey: .blockName))
        grossAreaHa = Self.nonNegative(try container.decodeIfPresent(Double.self, forKey: .grossAreaHa))
        rowLengthMetres = Self.positive(try container.decodeIfPresent(Double.self, forKey: .rowLengthMetres))
        rowSpacingMetres = Self.positive(try container.decodeIfPresent(Double.self, forKey: .rowSpacingMetres))
        rowCount = (try container.decodeIfPresent(Int.self, forKey: .rowCount)).flatMap { $0 > 0 ? $0 : nil }
        geometrySource = try? container.decodeIfPresent(SprayGeometrySource.self, forKey: .geometrySource)
        geometryQuality = try? container.decodeIfPresent(SprayGeometryQuality.self, forKey: .geometryQuality)
    }
}

extension Array where Element == SprayApplicationBlockSnapshot {
    /// The stable ids, in selection order — the client-side mirror of the
    /// sql/195 `block_ids` projection.
    var blockIds: [String] { map(\.blockId) }

    /// Human-readable list for exports and summaries.
    var displayNames: [String] { map(\.displayName) }
}
