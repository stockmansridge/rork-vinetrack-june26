import SwiftUI

/// Compatibility route for older presenters. No legacy lookup runtime is entered.
struct ChemicalMatchFlowView: View {
    let existing: SavedChemical?
    let prefillQuery: String
    let onSaved: ((SavedChemical) -> Void)?
    init(existing: SavedChemical? = nil, prefillQuery: String = "", onSaved: ((SavedChemical) -> Void)? = nil) {
        self.existing = existing; self.prefillQuery = prefillQuery; self.onSaved = onSaved
    }
    var body: some View {
        if let existing { ChemicalReverifyFlowView(chemical: existing) }
        else { CatalogueSearchView(prefillQuery: prefillQuery, onSaved: { onSaved?($0) }) }
    }
}
