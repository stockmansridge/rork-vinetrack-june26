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
        CatalogueSearchView(prefillQuery: prefillQuery.isEmpty ? existing?.name ?? "" : prefillQuery, onSaved: { onSaved?($0) })
    }
}
