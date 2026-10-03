import Foundation

/// Store-only projections; historical resolvers keep the complete saved collection.
nonisolated enum ChemicalStorePresentation {
    enum EditorKind { case catalogue, manual, legacyRepair }
    static func editorKind(_ chemical: SavedChemical?) -> EditorKind {
        guard let chemical else { return .manual }
        if chemical.chemicalV3RevisionId != nil { return .catalogue }
        if ["customer_entered", "manual", "manual_v2"].contains(chemical.entrySource ?? ""),
           chemical.defaultRates?.perHectare?.entryMethod == "manual" || chemical.defaultRates?.per100Litres?.entryMethod == "manual" { return .manual }
        return .legacyRepair
    }
    static func safeLegacyGroup(_ text: String) -> String {
        ["NOT_APPLICABLE", "UNRESOLVED", "CLASSIFIED"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()) ? "" : text
    }
    static func active(_ chemicals: [SavedChemical]) -> [SavedChemical] {
        chemicals.filter(\.isActive)
    }
    static func archived(_ chemical: SavedChemical) -> SavedChemical {
        var archived = chemical
        archived.isActive = false
        return archived
    }
    static func notesOnlyEdit(_ chemical: SavedChemical, session: ChemicalReviewSession, initialSession: ChemicalReviewSession) -> SavedChemical? {
        var unchanged = session
        unchanged.notes = initialSession.notes
        guard unchanged == initialSession else { return nil }
        var edited = chemical
        edited.notes = session.notes
        return edited
    }
    static func notesPatch(_ notes: String) -> [String: SprayReportPayloadV1.JSONValue] {
        ["notes": .string(notes)]
    }
}
