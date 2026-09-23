import Foundation

/// Evidence provenance shared by new V2 saves and legacy queued-upload repair.
nonisolated enum SavedChemicalEntrySource {
    static func reviewed(isManual: Bool, isMaster: Bool, intelligence: ChemicalIntelligence) -> String {
        if isManual { return "customer_entered" }
        if isMaster { return "master_catalogue" }
        return intelligence.hasEvidencedRegistration ? "register_lookup" : "label_lookup"
    }

    /// Only rewrite the three obsolete V2 spellings. Never change other legacy values.
    static func repaired(_ source: String?, intelligence: ChemicalIntelligence?) -> String? {
        switch source {
        case "manual_v2": return "customer_entered"
        case "master_catalogue_v2": return "master_catalogue"
        case "label_lookup_v2":
            return intelligence?.hasEvidencedRegistration == true ? "register_lookup" : "label_lookup"
        default: return source
        }
    }
}
