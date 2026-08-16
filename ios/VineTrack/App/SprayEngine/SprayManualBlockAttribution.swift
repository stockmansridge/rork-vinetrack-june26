import Foundation

/// Turns a manual spray form's block selection into the attribution to persist
/// (sql/195).
///
/// # Why this is not inside the form
///
/// Manual entry is the one path with no guided calculation to project attribution
/// from, so it has to decide three things that are genuinely domain rules rather
/// than presentation:
///
///  1. When to keep a historical snapshot **verbatim**.
///  2. When to project **fresh** geometry for a newly chosen block.
///  3. What to do about a selected block that **no longer exists**.
///
/// Those rules decide what a compliance record says, so they live here where they
/// can be tested directly, rather than inside a `View` where they could only ever
/// be verified by eye.
///
/// Mirrors the Android `SprayManualBlockAttribution`.
nonisolated enum SprayManualBlockAttribution {

    /// The attribution to persist, or nil for "blocks not recorded".
    ///
    /// - Parameters:
    ///   - selectedBlockIds: what the operator currently has ticked, in order.
    ///   - recordedBlocks: what the record already says it treated (nil when it
    ///     predates sql/195, or for a brand-new record).
    ///   - availableBlocks: the vineyard's live blocks, used ONLY to resolve
    ///     geometry for ids the operator selected. Never used to add ids.
    ///   - isEdit: true when editing an existing record rather than creating one.
    static func resolve(
        selectedBlockIds: [String],
        recordedBlocks: [SprayApplicationBlockSnapshot]?,
        availableBlocks: [Paddock],
        isEdit: Bool
    ) -> [SprayApplicationBlockSnapshot]? {
        // An empty selection is "not recorded", never "treated no blocks". This is
        // also what keeps an operator editing a legacy record's wind speed from
        // being forced to invent history: they leave it empty and it stays nil.
        guard !selectedBlockIds.isEmpty else { return nil }

        // Selection unchanged on an edit -> the stored snapshot is authoritative and
        // is returned untouched. Re-projecting here would silently refreeze TODAY's
        // block geometry onto a spray that happened last season, which is exactly
        // the retroactive rewrite the snapshot exists to prevent.
        if isEdit, let recordedBlocks {
            let recorded = Set(recordedBlocks.blockIds.map { $0.lowercased() })
            if recorded == Set(selectedBlockIds.map { $0.lowercased() }) {
                return recordedBlocks
            }
        }

        // The operator changed the selection, so this is an intentional correction.
        // Resolve through the SAME canonical resolver the Guided Spray uses, so
        // per-block areas and row lengths come from one implementation, not two.
        //
        // iOS writes `UUID.uuidString` (uppercase) while Postgres and Android use
        // lowercase, so the same block legitimately appears in both spellings.
        // Lookups are therefore case-insensitive on the id — normalisation of one
        // identity, never name matching.
        var liveById: [String: Paddock] = [:]
        for paddock in availableBlocks {
            liveById[paddock.id.uuidString.lowercased()] = paddock
        }
        let livePaddocks = selectedBlockIds.compactMap { liveById[$0.lowercased()] }
        let resolvedGeometry = SprayGeometryResolver.resolve(
            livePaddocks.map { SprayBlockInput.from(paddock: $0) }
        )
        var resolvedById: [String: SprayBlockGeometry] = [:]
        for block in resolvedGeometry.blocks {
            resolvedById[block.blockId.lowercased()] = block
        }
        var storedById: [String: SprayApplicationBlockSnapshot] = [:]
        for block in recordedBlocks ?? [] {
            storedById[block.blockId.lowercased()] = block
        }

        let blocks: [SprayApplicationBlockSnapshot] = selectedBlockIds.compactMap { id in
            // A live block gets fresh geometry. A block that no longer exists keeps
            // its stored snapshot, so changing the selection never destroys the
            // attribution of an archived block. An id that is neither is dropped —
            // there is nothing factual to record.
            if let geometry = resolvedById[id.lowercased()] {
                return SprayApplicationBlockSnapshot(geometry: geometry)
            }
            return storedById[id.lowercased()]
        }
        return SprayApplicationBlockSnapshot.normalised(blocks)
    }

    /// The full geometry snapshot to persist from a manual save.
    ///
    /// Carries `existing` through VERBATIM and replaces only the attribution, so an
    /// edit to an unrelated field cannot clear a calculator-produced record's
    /// treated area, band widths or row length.
    static func geometryToPersist(
        existing: SprayApplicationSnapshot?,
        blocks: [SprayApplicationBlockSnapshot]?
    ) -> SprayApplicationSnapshot? {
        (existing ?? SprayApplicationSnapshot()).withBlocks(blocks)
    }
}
