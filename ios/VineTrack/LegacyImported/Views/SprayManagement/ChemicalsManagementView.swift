import SwiftUI

/// Filter for the Chemical Store's verification audit.
///
/// Exists so a grower can work through "12 chemicals need verification"
/// incrementally instead of being handed a wall of unmatched records. The
/// counts come from `resolvedVerificationStatus`, not the stored column, so a
/// record that has lost its evidence shows up in the right bucket immediately.
private enum ChemicalVerificationFilter: String, CaseIterable, Identifiable {
    case all
    case verified
    case partiallyVerified
    case needsMatch
    case conflict
    case unverified

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .verified: return "Verified"
        case .partiallyVerified: return "Partially verified"
        case .needsMatch: return "Needs match"
        case .conflict: return "Conflict"
        case .unverified: return "Unverified"
        }
    }

    /// Each verification state gets its own bucket.
    ///
    /// Partially verified is deliberately NOT folded in with verified: they are
    /// different promises about the same product, and a grower auditing their
    /// store needs to see which records still have unconfirmed resistance data.
    func matches(_ status: ChemicalVerificationStatus) -> Bool {
        switch self {
        case .all: return true
        case .verified: return status == .verified
        case .partiallyVerified: return status == .partiallyVerified
        case .needsMatch: return status == .needsMatch
        case .conflict: return status == .conflict
        case .unverified: return status == .unverified
        }
    }
}

struct ChemicalsManagementView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl
    @State private var showAddSheet: Bool = false
    @State private var editingChemical: SavedChemical?
    @State private var matchingChemical: SavedChemical?
    @State private var reverifyingChemical: SavedChemical?
    @State private var searchText: String = ""
    @State private var filter: ChemicalVerificationFilter = .all
    @State private var deleteCoordinator = ChemicalDeleteCoordinator()

    private var canManageSetup: Bool { accessControl?.canManageSetup ?? false }

    /// The country a re-check would be keyed on, from the vineyard profile.
    private var countryCode: String {
        ChemicalRegistration.normaliseCountry(
            ChemicalInfoService.resolveCountry(vineyardCountry: store.selectedVineyard?.country)
        )
    }

    /// Whether Re-verify belongs on this row.
    ///
    /// The answer comes straight from the domain. Duplicating the eligibility
    /// rule here would let the button and the behaviour drift apart, and the
    /// interesting case — a legacy record with a registration number but no
    /// match — is exactly the one a hand-written UI check gets wrong.
    private func canReverify(_ chemical: SavedChemical) -> Bool {
        ChemicalReverification.isOffered(for: chemical, fallbackCountry: countryCode)
    }

    private var filteredChemicals: [SavedChemical] {
        var list = store.savedChemicals.filter { filter.matches($0.verificationStatus) }
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            list = list.filter { chem in
                let combined = "\(chem.name) \(chem.activeIngredient) \(chem.chemicalGroup) \(chem.manufacturer) \(chem.problem) \(chem.modeOfAction)"
                return combined.localizedStandardContains(trimmed)
            }
        }
        return list
    }

    private func count(for filter: ChemicalVerificationFilter) -> Int {
        store.savedChemicals.filter { filter.matches($0.verificationStatus) }.count
    }

    private var needsAttentionCount: Int {
        count(for: .needsMatch) + count(for: .conflict) + count(for: .unverified)
    }

    var body: some View {
        List {
            if needsAttentionCount > 0 {
                Section {
                    Label(
                        "\(needsAttentionCount) chemical\(needsAttentionCount == 1 ? "" : "s") need verification",
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(VineyardTheme.warning)
                }
            }

            if !canManageSetup && !filteredChemicals.isEmpty {
                Section {
                    Label("Setup data is managed by vineyard owners and managers.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Stated where the lookup STARTS, not only once it is running. The
            // + in this toolbar opens a register search that can take minutes
            // on a first-time product; an operator who learns that only after
            // committing has already spent the wait deciding whether the app
            // has hung.
            //
            // Only for those who can actually add: a viewer cannot start a
            // lookup, so the duration is not their concern.
            if canManageSetup {
                Section {
                    ChemicalLookupDurationNotice()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            ForEach(filteredChemicals) { chemical in
                Group {
                    if canManageSetup {
                        Button {
                            editingChemical = chemical
                        } label: {
                            ChemicalDetailRow(chemical: chemical, vineyardCountry: countryCode)
                        }
                    } else {
                        ChemicalDetailRow(chemical: chemical, vineyardCountry: countryCode)
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if canManageSetup {
                        // Re-verify for records VineTrack can already identify;
                        // Match & Verify for the ones it cannot. A legacy record
                        // with nothing but a typed name has no identity to
                        // re-check, so the domain sends it to Match & Verify
                        // instead of quietly running a brand-name search.
                        if canReverify(chemical) {
                            Button {
                                reverifyingChemical = chemical
                            } label: {
                                Label("Re-verify", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .tint(VineyardTheme.info)
                        } else if chemical.verificationStatus != .verified {
                            Button {
                                matchingChemical = chemical
                            } label: {
                                Label("Match & Verify", systemImage: "checkmark.seal")
                            }
                            .tint(VineyardTheme.info)
                        }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if canManageSetup {
                        Button(role: .destructive) {
                            deleteCoordinator.pending = chemical
                        } label: {
                            let inUse = store.isSavedChemicalInUseLocally(chemical.id)
                            Label(inUse ? "Archive" : "Delete", systemImage: inUse ? "archivebox" : "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Chemicals")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search chemicals...")
        .safeAreaInset(edge: .top) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ChemicalVerificationFilter.allCases) { option in
                        let isSelected = filter == option
                        Button {
                            filter = option
                        } label: {
                            Text("\(option.label) (\(count(for: option)))")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(isSelected
                                            ? VineyardTheme.info.opacity(0.18)
                                            : Color(.secondarySystemBackground))
                                .foregroundStyle(isSelected ? VineyardTheme.info : .secondary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
            }
            .contentMargins(.horizontal, 16)
            .background(.bar)
        }
        .toolbar {
            if canManageSetup {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .overlay {
            if store.savedChemicals.isEmpty {
                ContentUnavailableView {
                    Label("No Chemicals", systemImage: "flask")
                } description: {
                    Text("Add chemicals to quickly select them in spray records.")
                }
            } else if filteredChemicals.isEmpty {
                ContentUnavailableView {
                    Label("Nothing here", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("No chemicals match this filter.")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            // Adding starts with identification rather than a blank form: the
            // structured record is only worth having if the product is known.
            ChemicalMatchFlowView()
        }
        .sheet(item: $matchingChemical) { chem in
            ChemicalMatchFlowView(existing: chem, prefillQuery: chem.name)
        }
        .sheet(item: $reverifyingChemical) { chem in
            ChemicalReverifyFlowView(chemical: chem)
        }
        .sheet(item: $editingChemical) { chem in
            EditSavedChemicalSheet(chemical: chem)
        }
        .chemicalDeletionActions(coordinator: deleteCoordinator, store: store)
    }
}

struct ChemicalDetailRow: View {
    let chemical: SavedChemical
    /// The vineyard's country, for marking foreign-registered products. Empty
    /// (the default) renders no jurisdiction mark — suitability is unknown.
    var vineyardCountry: String = ""

    private var ratesPerHa: [ChemicalRate] {
        chemical.rates.filter { $0.basis == .perHectare }
    }

    private var ratesPer100L: [ChemicalRate] {
        chemical.rates.filter { $0.basis == .per100Litres }
    }

    /// Group text for the row.
    ///
    /// Derived from structured actives whenever they exist, so a verified
    /// mixture shows `FRAC 3 + 11` built from its actives. Only a record with
    /// no structured data falls back to the old free-text column.
    private var groupDisplay: String {
        let groups = chemical.resolvedIntelligence.activityGroups
        if !groups.isEmpty { return groups.legacyGroupProjection }
        return chemical.chemicalGroup
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(chemical.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    ChemicalVerificationBadge(status: chemical.verificationStatus, compact: true)
                }

                // A verified FOREIGN registration must never read as verified
                // for this vineyard: its label facts belong to another country's
                // law. Identity and chemistry still stand — only label authority
                // is marked as not applicable here.
                if case .mismatch(let registration, let vineyard) = ChemicalJurisdiction.suitability(
                    for: chemical, vineyardCountry: vineyardCountry
                ) {
                    ChemicalJurisdictionChip(
                        registrationCountry: registration,
                        vineyardCountry: vineyard
                    )
                }

                if chemical.category != nil || !groupDisplay.isEmpty || !chemical.problem.isEmpty {
                    HStack(spacing: 6) {
                        if let category = chemical.category {
                            Text(category.label)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    (category.isFertiliser ? VineyardTheme.leafGreen : VineyardTheme.info).opacity(0.12)
                                )
                                .foregroundStyle(category.isFertiliser ? VineyardTheme.leafGreen : VineyardTheme.info)
                                .clipShape(Capsule())
                        }
                        if !groupDisplay.isEmpty {
                            Text(groupDisplay)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(VineyardTheme.olive.opacity(0.12))
                                .foregroundStyle(VineyardTheme.olive)
                                .clipShape(Capsule())
                        }
                        if !chemical.problem.isEmpty {
                            Text(chemical.problem)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(VineyardTheme.info.opacity(0.12))
                                .foregroundStyle(VineyardTheme.info)
                                .clipShape(Capsule())
                        }
                    }
                }

                if !ratesPerHa.isEmpty {
                    Text(ratesPerHa.map { "\($0.label): \(SprayRateFormatter.format(chemical.unit.fromBase($0.value)))/ha" }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !ratesPer100L.isEmpty {
                    Text(ratesPer100L.map { "\($0.label): \(SprayRateFormatter.format(chemical.unit.fromBase($0.value)))/100L" }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // Legacy-only fallback, shown when a historical chemical carries
                // no structured rates at all. A nil projection means there is no
                // valid per-hectare scalar (sql/222) — a confirmed 2–3 L/100 L
                // rate, for instance — so the row stays silent rather than
                // printing a fabricated "0 L/Ha".
                if ratesPerHa.isEmpty,
                   ratesPer100L.isEmpty,
                   let legacyPerHa = chemical.ratePerHa,
                   legacyPerHa > 0 {
                    Text("\(SprayRateFormatter.format(legacyPerHa)) \(chemical.unit.rawValue)/Ha")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !chemical.activeIngredient.isEmpty {
                    Text(chemical.activeIngredient)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
