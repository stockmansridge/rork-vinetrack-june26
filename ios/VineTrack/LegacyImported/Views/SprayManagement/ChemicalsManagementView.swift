import SwiftUI

private enum ChemicalVerificationFilter: String, CaseIterable, Identifiable {
    case all, complete, basic, review
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .complete: return "Complete details"
        case .basic: return "Basic details"
        case .review: return "Review required"
        }
    }
    func matches(_ chemical: SavedChemical) -> Bool {
        let details = ChemicalDetailsCompleteness.assess(chemical)
        switch self {
        case .all: return true
        case .complete: return details.title == "Complete details"
        case .basic: return details.title == "Basic details"
        case .review: return details.hasConflict
        }
    }
}

struct ChemicalsManagementView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl
    @Environment(SystemAdminService.self) private var systemAdmin
    @State private var showAddSheet: Bool = false
    @State private var showSearchV2: Bool = false
    @State private var editingChemical: SavedChemical?
    @State private var matchingChemical: SavedChemical?
    @State private var reverifyingChemical: SavedChemical?
    @State private var searchText: String = ""
    @State private var approvedMedia: [UUID: MasterFrontLabel] = [:]
    @State private var catalogueRevisions: [UUID: CatalogueWire] = [:]
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

    private var activeChemicals: [SavedChemical] { ChemicalStorePresentation.active(store.savedChemicals) }

    private var filteredChemicals: [SavedChemical] {
        var list = activeChemicals.filter { filter.matches($0) }
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            list = list.filter { chem in
                let targets = chem.chemicalV3RevisionId.flatMap { catalogueRevisions[$0] }?.targets.joined(separator: " ") ?? CatalogueWire.manualTargets(problem: chem.problem, use: chem.use)
                let combined = "\(chem.name) \(chem.activeIngredient) \(chem.chemicalGroup) \(chem.manufacturer) \(targets) \(chem.modeOfAction)"
                return combined.localizedStandardContains(trimmed)
            }
        }
        return list
    }

    private func count(for filter: ChemicalVerificationFilter) -> Int {
        activeChemicals.filter { filter.matches($0) }.count
    }

    private var needsAttentionCount: Int {
        count(for: .basic) + count(for: .review)
    }

    var body: some View {
        List {
            if needsAttentionCount > 0 {
                Section {
                    Label(
                        "\(needsAttentionCount) chemical\(needsAttentionCount == 1 ? "" : "s") need attention",
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

            if systemAdmin.isSystemAdmin {
                Section { NavigationLink { ChemicalInventoryView() } label: { Label("Chemical Inventory", systemImage: "shippingbox") } }
            }
            ForEach(filteredChemicals) { chemical in
                Group {
                    if canManageSetup {
                        Button {
                            editingChemical = chemical
                        } label: {
                            ChemicalDetailRow(chemical: chemical, vineyardCountry: countryCode,
                                              media: chemical.masterChemicalId.flatMap { approvedMedia[$0] }.flatMap {
                                                  $0.belongs(to: chemical.masterChemicalId,
                                                              identity: chemical.resolvedIntelligence.registration?.identityKey) ? $0 : nil
                                              })
                        }
                    } else {
                        ChemicalDetailRow(chemical: chemical, vineyardCountry: countryCode,
                                              media: chemical.masterChemicalId.flatMap { approvedMedia[$0] }.flatMap {
                                                  $0.belongs(to: chemical.masterChemicalId,
                                                              identity: chemical.resolvedIntelligence.registration?.identityKey) ? $0 : nil
                                              })
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if canManageSetup {
                        // Re-verify for records VineTrack can already identify;
                        // Match & Verify for the ones it cannot. A legacy record
                        // with nothing but a typed name has no identity to
                        // re-check, so the domain sends it to Match & Verify
                        // instead of quietly running a brand-name search.
                        Button {
                            editingChemical = chemical
                        } label: {
                            Label("Edit Chemical", systemImage: "pencil")
                        }
                        .tint(VineyardTheme.info)
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
        .task(id: activeChemicals.map(\.chemicalV3RevisionId)) {
            catalogueRevisions = [:]
            for id in Set(activeChemicals.compactMap(\.chemicalV3RevisionId)) {
                guard !Task.isCancelled else { return }
                catalogueRevisions[id] = try? await CatalogueRepository().revision(id.uuidString)
            }
        }
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
                        if systemAdmin.usesChemicalSearchV2ForCreation {
                            showSearchV2 = true
                        } else {
                            showAddSheet = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .overlay {
            if activeChemicals.isEmpty {
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
            // Existing Chemical Search remains unchanged.
            ChemicalMatchFlowView()
        }
        .sheet(isPresented: $showSearchV2) {
            ChemicalSearchV2View { existing in
                showSearchV2 = false
                editingChemical = existing
            }
        }
        .sheet(item: $matchingChemical) { chem in
            ChemicalMatchFlowView(existing: chem, prefillQuery: chem.name)
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
    var media: MasterFrontLabel? = nil

    /// Group text for the row.
    ///
    /// Derived from structured actives whenever they exist, so a verified
    /// mixture shows `FRAC 3 + 11` built from its actives. Only a record with
    /// no structured data falls back to the old free-text column.
    private var groupDisplay: String {
        let groups = chemical.resolvedIntelligence.activityGroups
        if !groups.isEmpty { return groups.legacyGroupProjection }
        return ChemicalStorePresentation.safeLegacyGroup(chemical.chemicalGroup)
    }

    var body: some View {
        if chemical.chemicalV3RevisionId != nil {
            CatalogueSavedChemicalView(chemical: chemical)
        } else {
        HStack {
            MasterFrontLabelView(media: media, interactive: false)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(chemical.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    ChemicalVerificationBadge(status: chemical.verificationStatus, chemical: chemical)
                }
                if let missing = ChemicalDetailsCompleteness.assess(chemical).missingText {
                    Text(missing).font(.caption2).foregroundStyle(.secondary)
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
                        let usedFor = CatalogueWire.manualTargets(problem: chemical.problem, use: chemical.use)
                        if !usedFor.isEmpty {
                            Text("Used for: \(usedFor)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(VineyardTheme.info.opacity(0.12))
                                .foregroundStyle(VineyardTheme.info)
                                .clipShape(Capsule())
                        }
                    }
                }

                if !chemical.manufacturer.isEmpty { Text(chemical.manufacturer).font(.caption).foregroundStyle(.secondary) }

            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        }
    }
}
