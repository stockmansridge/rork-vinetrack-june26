import SwiftUI
import PhotosUI
import Vision
import Supabase

nonisolated struct ViticultureRates: Codable, Sendable, Hashable {
    let perHectare: [ChemicalLabelRate]
    let per100Litres: [ChemicalLabelRate]

    enum CodingKeys: String, CodingKey {
        case perHectare = "per_hectare"
        case per100Litres = "per_100_litres"
    }

    var all: [ChemicalLabelRate] { perHectare + per100Litres }

    static func fromRegisteredUses(_ uses: [ChemicalRegisteredUse]) -> ViticultureRates {
        let rates = uses.filter(\.isViticultural).flatMap(\.rates)
        return ViticultureRates(
            perHectare: rates.filter { $0.basis == .perHectare || $0.basis == .rangePerHectare },
            per100Litres: rates.filter { $0.basis == .per100Litres || $0.basis == .rangePer100Litres }
        )
    }
}

nonisolated enum ChemicalSearchV2OperationalDefaults {
    static func unambiguousRates(from rates: ViticultureRates) -> [ChemicalDefaultRateBasis: ChemicalLabelRate] {
        var result: [ChemicalDefaultRateBasis: ChemicalLabelRate] = [:]
        let groups: [(ChemicalDefaultRateBasis, [ChemicalLabelRate])] = [
            (.perHectare, rates.perHectare),
            (.per100Litres, rates.per100Litres)
        ]
        for (basis, candidates) in groups {
            var seen = Set<String>()
            let usable = candidates.filter(ChemicalSaveContract.isAutoApplicable).filter {
                seen.insert(ChemicalDefaultRate.distinctnessKey($0)).inserted
            }
            if usable.count == 1 { result[basis] = usable[0] }
        }
        return result
    }

    static func effectiveRates(
        automatic: [ChemicalDefaultRateBasis: ChemicalLabelRate],
        edited: ChemicalLabelRate?
    ) -> [ChemicalLabelRate] {
        var result = automatic
        if let edited, let basis = ChemicalDefaultRateBasis.of(edited.basis) { result[basis] = edited }
        return ChemicalDefaultRateBasis.allCases.compactMap { result[$0] }
    }

    static func storedDefaults(
        rates: [ChemicalLabelRate],
        selectedAt: String
    ) -> StoredChemicalDefaultRates? {
        var defaults = StoredChemicalDefaultRates()
        for rate in rates {
            guard let basis = ChemicalDefaultRateBasis.of(rate.basis) else { continue }
            let slot: StoredChemicalDefaultRate?
            if let min = rate.minValue, let max = rate.maxValue {
                slot = .manual(basis: basis, unit: rate.unit, minValue: min, maxValue: max, selectedAt: selectedAt)
            } else if let value = rate.value {
                slot = .manual(basis: basis, unit: rate.unit, value: value, selectedAt: selectedAt)
            } else {
                slot = nil
            }
            if let slot { defaults = defaults.withSlot(basis, slot) }
        }
        return defaults.isEmpty ? nil : defaults
    }
}

nonisolated struct MasterChemicalV2: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let registrationCountry: String
    let registrationScheme: String
    let registrationNumber: String
    let registrant: String?
    let registeredProductName: String
    let commonNames: [String]
    let productCategory: String?
    let formType: String?
    let activeIngredients: [ChemicalActiveIngredient]
    let activityGroups: [String]
    let activityGroupScheme: String?
    let registeredUses: [ChemicalRegisteredUse]
    let viticultureRates: ViticultureRates
    let hasViticultureEvidence: Bool
    let labelRateBases: [String]
    let labelReference: String?
    let labelVersion: String?
    let verificationStatus: String
    let verificationSources: [ChemicalDataSource]
    let verificationConflicts: [ChemicalVerificationConflict]
    let verificationUnresolvedFields: [String]
    let verifiedAt: Date?
    let sourceKind: String
    let reviewStatus: String
    let catalogueVersion: Int
    let manufacturerLabelURL: String?
    let manufacturerProductURL: String?
    let regulatorLabelURL: String?
    let searchRank: Int

    enum CodingKeys: String, CodingKey {
        case id, registrant, commonNames = "common_names", productCategory = "product_category"
        case formType = "form_type", activeIngredients = "active_ingredients"
        case activityGroups = "activity_groups", activityGroupScheme = "activity_group_scheme"
        case registeredUses = "registered_uses", viticultureRates = "viticulture_rates"
        case hasViticultureEvidence = "has_viticulture_evidence", labelRateBases = "label_rate_bases"
        case labelReference = "label_reference", labelVersion = "label_version"
        case verificationStatus = "verification_status", verificationSources = "verification_sources"
        case verificationConflicts = "verification_conflicts"
        case verificationUnresolvedFields = "verification_unresolved_fields"
        case verifiedAt = "verified_at", sourceKind = "source_kind", reviewStatus = "review_status"
        case catalogueVersion = "catalogue_version", registrationCountry = "registration_country"
        case registrationScheme = "registration_scheme", registrationNumber = "registration_number"
        case registeredProductName = "registered_product_name"
        case manufacturerLabelURL = "manufacturer_label_url"
        case manufacturerProductURL = "manufacturer_product_url"
        case regulatorLabelURL = "regulator_label_url", searchRank = "search_rank"
    }

    var intelligence: ChemicalIntelligence {
        let status = ChemicalVerificationStatus(rawValue: verificationStatus) ?? .unverified
        let registration = ChemicalRegistration(
            countryCode: registrationCountry,
            scheme: ChemicalRegistrationScheme(rawValue: registrationScheme) ?? .other,
            registrationNumber: registrationNumber,
            registrant: registrant,
            registeredProductName: registeredProductName,
            labelReference: labelReference,
            manufacturerLabelURL: manufacturerLabelURL,
            regulatorLabelURL: regulatorLabelURL,
            manufacturerProductURL: manufacturerProductURL,
            labelVersion: labelVersion
        )
        return ChemicalIntelligence(
            activeIngredients: activeIngredients,
            registration: registration,
            verification: ChemicalVerification(
                status: status,
                sources: verificationSources,
                verifiedAt: verifiedAt,
                conflicts: verificationConflicts,
                unresolvedFields: verificationUnresolvedFields
            ),
            registeredUses: registeredUses,
            productCategory: productCategory ?? "",
            activityGroupTableVersion: AuthoritativeActivityGroups.tableVersion
        )
    }

    var grapevineRates: [ChemicalLabelRate] { viticultureRates.all }
}

nonisolated struct ChemicalSearchV2Diagnostics: Sendable, Hashable {
    var query: String = ""
    var durationMilliseconds: Int = 0
    var resultCount: Int = 0
    var masterHit: Bool = false
    var fallbackInvoked: Bool = false
    var photoMatch: Bool = false
    var externalLookupSucceeded: Bool? = nil
}

nonisolated enum ChemicalSearchV2RequestGate {
    static func accepts(completed: UUID, active: UUID?) -> Bool { completed == active }
}

nonisolated enum ChemicalSearchV2Rank {
    static func rank(query: String, productName: String, commonNames: [String], registrationNumber: String, activeNames: [String], registrant: String?) -> Int? {
        let normal = ChemicalStoreMatching.normalisedName(query).replacingOccurrences(of: " ", with: "")
        let product = ChemicalStoreMatching.normalisedName(productName)
        let compactProduct = product.replacingOccurrences(of: " ", with: "")
        if compactProduct == normal { return 1 }
        if product.hasPrefix(ChemicalStoreMatching.normalisedName(query)) { return 2 }
        if commonNames.contains(where: { ChemicalStoreMatching.normalisedName($0).replacingOccurrences(of: " ", with: "") == normal }) { return 3 }
        if product.contains(ChemicalStoreMatching.normalisedName(query)) { return 4 }
        let digits = query.filter(\.isNumber)
        if !digits.isEmpty, registrationNumber.filter(\.isNumber) == digits { return 5 }
        let secondary = (activeNames + [registrant ?? ""]).joined(separator: " ").lowercased()
        return secondary.contains(query.lowercased()) ? 6 : nil
    }
}

nonisolated enum ChemicalSearchV2Duplicate {
    static func localMatches(query: String, in chemicals: [SavedChemical]) -> [SavedChemical] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let registration = trimmed.filter(\.isNumber)
        if !registration.isEmpty && (registration == trimmed || trimmed.uppercased() == "APVMA \(registration)") {
            let matches = chemicals.filter {
                $0.isActive && $0.resolvedIntelligence.registration?.registrationNumber == registration &&
                $0.resolvedIntelligence.registration?.countryCode.uppercased() == "AU" &&
                $0.resolvedIntelligence.registration?.scheme == .apvma
            }
            if !matches.isEmpty { return matches }
        }
        return ChemicalStoreMatching.findByProductName(in: chemicals, query: trimmed)
    }

    static func existing(master: MasterChemicalV2?, intelligence: ChemicalIntelligence, name: String, in chemicals: [SavedChemical]) -> SavedChemical? {
        if let master, let found = chemicals.first(where: { $0.isActive && $0.masterChemicalId == master.id }) {
            return found
        }
        if let found = ChemicalStoreMatching.findByRegistrationIdentity(
            in: chemicals, registration: intelligence.registration
        ) { return found }
        let incomingIdentity = intelligence.registration?.identityKey
        return chemicals.first {
            $0.isActive && ChemicalStoreMatching.namesMatch($0.name, name) &&
            (incomingIdentity == nil || $0.resolvedIntelligence.registration?.identityKey == nil)
        }
    }
}

nonisolated enum ChemicalSearchV2ManualPrefill {
    static func productName(from searchText: String) -> String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated struct ChemicalSearchV2ManualDetails: Sendable, Hashable {
    var manufacturer: String = ""
    var registrationNumber: String = ""
    var productCategory: String = ""
    var productForm: String = ""
    var activeIngredient: String = ""
    var concentration: String = ""
    var concentrationUnit: ChemicalConcentrationUnit?
    var activityGroupScheme: ChemicalActivityGroupScheme?
    var activityGroupCode: String = ""
    var labelURL: String = ""
    var productURL: String = ""
    var notes: String = ""
    var packSize: String = ""
    var packUnit: String = ""
    var pricePerPack: String = ""
    var inventoryQuantity: String = ""
    var inventoryUnit: String = ""

    func intelligence(productName: String, rate: ChemicalManualRateDraft) -> ChemicalIntelligence {
        let activeNames = activeIngredient.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let actives = activeNames.enumerated().map { index, name in
            ChemicalManualActiveDraft(
                name: name,
                concentrationText: index == 0 ? concentration : "",
                concentrationUnit: index == 0 ? concentrationUnit : nil,
                scheme: index == 0 ? activityGroupScheme : nil,
                groupCode: index == 0 ? activityGroupCode : ""
            )
        }
        let hasRegistration = !manufacturer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !registrationNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !labelURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !productURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let draft = ChemicalManualDraft(
            productName: productName,
            countryCode: hasRegistration ? "AU" : "",
            productCategory: productCategory,
            registrant: manufacturer,
            registrationScheme: hasRegistration ? .apvma : nil,
            registrationNumber: registrationNumber,
            labelReference: labelURL,
            productReference: productURL,
            actives: actives,
            productRates: [rate]
        )
        var intelligence = ChemicalManualEntry.outcome(for: draft, existing: nil).intelligence
        intelligence.registeredUses = []
        return intelligence
    }
}

@MainActor
struct MasterChemicalV2Repository: Sendable {
    static let invokesAI = false
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    private struct SearchParams: Encodable, Sendable {
        let query: String
        let limit: Int
        enum CodingKeys: String, CodingKey { case query = "p_query", limit = "p_limit" }
    }

    func search(_ query: String) async throws -> [MasterChemicalV2] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let response: [MasterChemicalV2] = try await provider.client
            .rpc("search_master_chemicals_v2", params: SearchParams(query: query, limit: 25))
            .execute().value
        return response
    }
}

@MainActor
struct ChemicalLabelAttachmentRepository: Sendable {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    private struct Insert: Encodable, Sendable {
        let vineyardId: UUID
        let savedChemicalId: UUID
        let storagePath: String
        enum CodingKeys: String, CodingKey {
            case vineyardId = "vineyard_id", savedChemicalId = "saved_chemical_id", storagePath = "storage_path"
        }
    }

    func upload(_ image: Data, vineyardId: UUID, chemicalId: UUID) async throws {
        let path = "\(vineyardId.uuidString.lowercased())/\(chemicalId.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        let payload = PinPhotoStorage.compress(image) ?? image
        _ = try await provider.client.storage.from("chemical-label-photos").upload(
            path, data: payload,
            options: FileOptions(cacheControl: "3600", contentType: "image/jpeg", upsert: false)
        )
        try await provider.client.from("saved_chemical_attachments").insert(
            Insert(vineyardId: vineyardId, savedChemicalId: chemicalId, storagePath: path)
        ).execute()
    }
}

@MainActor
enum ChemicalLabelIdentityOCR {
    struct Evidence: Sendable, Hashable {
        let text: String
        let apvmaNumber: String?
        let searchQuery: String?
    }

    static func proposedQuery(apvma: String?, identifiedName: String?) -> String? {
        apvma ?? identifiedName
    }

    static func recognise(_ data: Data) async throws -> Evidence {
        guard let image = UIImage(data: data), let cgImage = image.cgImage else {
            throw NSError(domain: "ChemicalSearchV2", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected photo could not be read."])
        }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let lines = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
                let text = lines.joined(separator: "\n")
                let number = apvmaNumber(in: text)
                continuation.resume(returning: Evidence(text: text, apvmaNumber: number, searchQuery: number))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage)
            do { try handler.perform([request]) } catch { continuation.resume(throwing: error) }
        }
    }

    static func apvmaNumber(in text: String) -> String? {
        let pattern = #"(?i)(?:APVMA|product\s*(?:no\.?|number)|registration\s*(?:no\.?|number))[^0-9]{0,16}([0-9]{3,8})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

@MainActor
struct ChemicalSearchV2View: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store

    let onOpenExisting: (SavedChemical) -> Void
    let onSaved: (SavedChemical) -> Void

    init(prefillQuery: String = "", onOpenExisting: @escaping (SavedChemical) -> Void = { _ in }, onSaved: @escaping (SavedChemical) -> Void = { _ in }) {
        self.onOpenExisting = onOpenExisting
        self.onSaved = onSaved
        _query = State(initialValue: prefillQuery)
    }

    @State private var query: String = ""
    @State private var results: [MasterChemicalV2] = []
    @State private var onlineCandidates: [ChemicalInfoService.WebV2Candidate] = []
    @State private var savedMatches: [SavedChemical] = []
    @State private var isSearching: Bool = false
    @State private var message: String?
    @State private var requestID: UUID?
    @State private var review: ReviewDraft?
    @State private var photoData: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var isShowingCamera: Bool = false
    @State private var isExternalLookupRunning: Bool = false
    @State private var isReadingPhoto: Bool = false
    @State private var proposedIdentity: String?
    @State private var photoRegistration: String?
    @State private var photoProductName: String?
    @State private var externalRequestID: UUID?
    @State private var photoRequestID: UUID?
    @State private var diagnostics = ChemicalSearchV2Diagnostics()

    private let repository = MasterChemicalV2Repository()
    private let externalService = ChemicalInfoService()

    struct ReviewDraft: Identifiable {
        let id = UUID()
        let source: String
        let master: MasterChemicalV2?
        let intelligence: ChemicalIntelligence
        let formType: String?
        var productName: String
        var unit: ChemicalUnit
        var rate: ChemicalManualRateDraft
        var viticultureRates: ViticultureRates
        var selectedRegisteredRateID: String?
        var automaticRates: [ChemicalDefaultRateBasis: ChemicalLabelRate]
        var masterMatch: ChemicalMasterMatch? = nil
        var isManual: Bool = false
        var manualDetails = ChemicalSearchV2ManualDetails()
        var enteredLabelRate: ChemicalManualRateDraft?
        var activeCorrections: [String: ChemicalManualActiveDraft] = [:]
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Product name, APVMA number, active or manufacturer", text: $query)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                        .onSubmit(search)
                        .onChange(of: query) { _, _ in
                            requestID = nil
                            externalRequestID = nil
                            results = []
                            onlineCandidates = []
                            savedMatches = []
                            isSearching = false
                            isExternalLookupRunning = false
                            message = nil
                        }
                    Button(action: search) {
                        if isSearching { ProgressView().frame(maxWidth: .infinity) }
                        else { Label("Find Chemical", systemImage: "magnifyingglass").frame(maxWidth: .infinity) }
                    }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || isSearching || isExternalLookupRunning)
                    Button(action: openManual) {
                        Label("Create Manually", systemImage: "plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } footer: {
                    Text("Checks your Chemical Store, then VineTrack's catalogue. If there is no catalogue match, searches online automatically.")
                }

                if isReadingPhoto { HStack { ProgressView(); Text("Identifying product on label…") } }
                if let proposedIdentity {
                    Section("Product found on label") {
                        Text(proposedIdentity)
                        if let photoRegistration { Text("APVMA \(photoRegistration)").font(.caption) }
                        TextField("Edit product or APVMA number", text: $query)
                        Button("Search this product") {
                            self.proposedIdentity = nil
                            search()
                        }
                    }
                }
                if let message { Text(message).foregroundStyle(.secondary) }

                if !savedMatches.isEmpty {
                    Section("Already in your Chemical Store") {
                        ForEach(savedMatches) { chemical in
                            Button("Use Chemical — \(chemical.name)") {
                                onSaved(chemical)
                                dismiss()
                            }
                        }
                    }
                }

                ForEach(results) { result in
                    Section {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(result.registeredProductName).font(.headline)
                            if let registrant = result.registrant { Text(registrant).font(.subheadline).foregroundStyle(.secondary) }
                            Text("APVMA \(result.registrationNumber)").font(.caption.monospaced())
                            if !result.activeIngredients.isEmpty {
                                Text(result.activeIngredients.map(\.name).joined(separator: ", ")).font(.caption)
                            }
                            if let category = result.productCategory, !category.isEmpty { Text(category.capitalized).font(.caption).foregroundStyle(.secondary) }
                            Button("Use this chemical") { openMaster(result) }.buttonStyle(.borderedProminent)
                        }.padding(.vertical, 4)
                    }
                }

                if !onlineCandidates.isEmpty {
                    Section("Agricultural products — choose your product") {
                        ForEach(onlineCandidates) { candidate in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(candidate.name).font(.headline)
                                if !candidate.brand.isEmpty { Text(candidate.brand).font(.subheadline) }
                                if !candidate.activeIngredient.isEmpty { Text(candidate.activeIngredient).font(.caption) }
                                if let category = candidate.productCategory, !category.isEmpty { Text(category.capitalized).font(.caption) }
                                Button("Use this chemical") { openOnlineCandidate(candidate) }.buttonStyle(.borderedProminent)
                            }.padding(.vertical, 4)
                        }
                    }
                }

                Section(results.isEmpty ? "More ways to find a product" : "Other options") {
                    if isExternalLookupRunning {
                        HStack { ProgressView(); Text("Finding agricultural product and reading label…") }
                    } else {
                        Button("Search Online") { searchOnline() }
                            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                    }
                    Button("Take Photo of Label") { isShowingCamera = true }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Choose Label Photo", systemImage: "photo.on.rectangle")
                    }
                }
            }
            .navigationTitle("Add Chemical")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { externalRequestID = nil; photoRequestID = nil; dismiss() } } }
            .onDisappear { externalRequestID = nil; photoRequestID = nil }
            .sheet(isPresented: $isShowingCamera) {
                CameraImagePicker { data in if let data { acceptPhoto(data) } }
            }
            .sheet(item: $review) { draft in
                ChemicalSearchV2ReviewView(
                    draft: draft,
                    photoData: draft.isManual ? nil : photoData,
                    onOpenExisting: { existing in
                        review = nil
                        dismiss()
                        onOpenExisting(existing)
                    },
                    onSaved: { chemical in
                        onSaved(chemical)
                    }
                ) { outcome in
                    message = outcome
                    review = nil
                    if outcome.hasPrefix("Saved") || outcome.hasPrefix("Used") { dismiss() }
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) { acceptPhoto(data) }
                    photoItem = nil
                }
            }
        }
    }

    private func search() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        requestID = nil
        externalRequestID = nil
        isExternalLookupRunning = false
        results = []
        onlineCandidates = []
        savedMatches = ChemicalSearchV2Duplicate.localMatches(query: trimmed, in: store.savedChemicals)
        if !savedMatches.isEmpty {
            isSearching = false
            message = "This chemical is already saved. Use the existing record without creating another copy."
            return
        }
        let token = UUID(); requestID = token; isSearching = true; message = nil
        let started = Date()
        Task {
            do {
                let found = try await repository.search(trimmed)
                guard requestID == token else { return }
                results = found
                let elapsedMilliseconds = Int(Date().timeIntervalSince(started) * 1_000)
                diagnostics = ChemicalSearchV2Diagnostics(
                    query: trimmed,
                    durationMilliseconds: elapsedMilliseconds,
                    resultCount: found.count, masterHit: !found.isEmpty,
                    fallbackInvoked: diagnostics.fallbackInvoked,
                    photoMatch: diagnostics.photoMatch,
                    externalLookupSucceeded: diagnostics.externalLookupSucceeded
                )
                print("[ChemicalSearchV2] query=\(trimmed) duration_ms=\(diagnostics.durationMilliseconds) results=\(found.count) master_hit=\(!found.isEmpty)")
                if found.isEmpty {
                    isSearching = false
                    searchOnline(automatically: true)
                }
            } catch { if requestID == token { message = error.localizedDescription; results = [] } }
            if requestID == token { isSearching = false }
        }
    }

    private func openMaster(_ master: MasterChemicalV2) {
        if let existing = ChemicalSearchV2Duplicate.existing(master: master, intelligence: master.intelligence, name: master.registeredProductName, in: store.savedChemicals) {
            savedMatches = [existing]
            results = []
            return
        }
        let automatic = master.viticultureRates.all.count > 1 ? [:] : ChemicalSearchV2OperationalDefaults.unambiguousRates(from: master.viticultureRates)
        let selected = automatic[.perHectare] ?? automatic[.per100Litres]
        let initial = selected.map(draftRate) ?? ChemicalManualRateDraft()
        if photoRegistration != master.registrationNumber { photoData = nil }
        review = ReviewDraft(
            source: "VineTrack Master", master: master, intelligence: master.intelligence,
            formType: master.formType, productName: master.registeredProductName,
            unit: unit(for: initial.unit), rate: initial, viticultureRates: master.viticultureRates,
            selectedRegisteredRateID: selected?.id, automaticRates: automatic
        )
    }

    private func openManual() {
        review = ReviewDraft(
            source: "Manual — this vineyard",
            master: nil,
            intelligence: ChemicalIntelligence(verification: .manual()),
            formType: nil,
            productName: ChemicalSearchV2ManualPrefill.productName(from: query),
            unit: .litres,
            rate: ChemicalManualRateDraft(),
            viticultureRates: ViticultureRates(perHectare: [], per100Litres: []),
            selectedRegisteredRateID: nil,
            automaticRates: [:],
            isManual: true
        )
    }

    private func searchOnline(automatically: Bool = false) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, !isExternalLookupRunning else { return }
        let local = ChemicalSearchV2Duplicate.localMatches(query: trimmed, in: store.savedChemicals)
        if !local.isEmpty { savedMatches = local; results = []; return }
        requestID = nil
        isSearching = false
        let token = UUID(); externalRequestID = token
        isExternalLookupRunning = true
        message = automatically ? "No catalogue match. Searching the official register online…" : "Searching the official register online…"
        onlineCandidates = []; diagnostics.fallbackInvoked = true
        Task {
            do {
                let response = try await externalService.lookupOnlineCandidates(query: trimmed)
                guard externalRequestID == token else { return }
                onlineCandidates = response.candidates
                if let detail = response.detail { openWebReview(detail, fallbackName: response.candidates.first?.name ?? trimmed) }
                message = response.detail != nil ? nil : onlineCandidates.isEmpty
                    ? "No reliable agricultural source found online. Check the name or create manually."
                    : automatically ? "No catalogue match. Choose an agricultural product found online." : "Choose the agricultural product you use."
                diagnostics.externalLookupSucceeded = response.detail != nil || !onlineCandidates.isEmpty
            } catch {
                if externalRequestID == token {
                    diagnostics.externalLookupSucceeded = false
                    message = automatically ? "No catalogue match. Online search is unavailable; try again or create manually." : "Online search is unavailable. Try again or create manually."
                }
            }
            if externalRequestID == token { isExternalLookupRunning = false; externalRequestID = nil }
        }
    }

    private func openWebReview(_ lookup: ChemicalStructuredLookup, fallbackName: String) {
        let intel = lookup.intelligence()
        let rates = ViticultureRates.fromRegisteredUses(intel.registeredUses)
        let automatic: [ChemicalDefaultRateBasis: ChemicalLabelRate] = rates.all.count > 1
            ? [:] : ChemicalSearchV2OperationalDefaults.unambiguousRates(from: rates)
        let selected = automatic[.perHectare] ?? automatic[.per100Litres]
        let initial = selected.map(draftRate) ?? ChemicalManualRateDraft()
        review = ReviewDraft(
            source: "Product label / web", master: nil, intelligence: intel,
            formType: lookup.formType, productName: lookup.productName ?? fallbackName,
            unit: unit(for: initial.unit), rate: initial, viticultureRates: rates,
            selectedRegisteredRateID: selected?.id, automaticRates: automatic
        )
    }

    private func openOnlineCandidate(_ candidate: ChemicalInfoService.WebV2Candidate) {
        let token = UUID(); externalRequestID = token
        isExternalLookupRunning = true
        message = candidate.registrationNumber == nil ? "Reading product label…" : "Checking official product record…"
        Task {
            do {
                let response = try await externalService.lookupSelectedOnlineCandidate(candidate, query: query)
                guard externalRequestID == token else { return }
                if let detail = response.detail { openWebReview(detail, fallbackName: candidate.name) }
                else { message = "No reliable product source found. Check details or create manually." }
            } catch {
                if externalRequestID == token { message = "Could not read this product. Try again or create manually." }
            }
            if externalRequestID == token { isExternalLookupRunning = false; externalRequestID = nil }
        }
    }

    private func acceptPhoto(_ data: Data) {
        let token = UUID(); photoRequestID = token
        photoData = data; photoRegistration = nil; photoProductName = nil; proposedIdentity = nil; isReadingPhoto = true; message = nil
        Task {
            do {
                let evidence = try await ChemicalLabelIdentityOCR.recognise(data)
                let name = try? await externalService.identifyLabel(ocrText: evidence.text)
                guard photoRequestID == token else { return }
                photoRegistration = evidence.apvmaNumber
                photoProductName = name
                if let identity = ChemicalLabelIdentityOCR.proposedQuery(apvma: evidence.apvmaNumber, identifiedName: name) {
                    proposedIdentity = name ?? "APVMA \(identity)"
                    query = identity
                    message = "Confirm or edit the search text before searching VineTrack Master."
                } else {
                    message = "No confident product identity found. Enter the product name to search VineTrack Master."
                }
            } catch {
                if photoRequestID == token { message = "Could not identify the label. Enter a product name or APVMA number to search." }
            }
            if photoRequestID == token { isReadingPhoto = false; photoRequestID = nil }
        }
    }

    private func draftRate(_ rate: ChemicalLabelRate) -> ChemicalManualRateDraft {
        ChemicalManualRateDraft(
            label: rate.label, basis: rate.basis,
            valueText: rate.value.map(ChemicalReviewSession.formatRate) ?? "",
            minText: rate.minValue.map(ChemicalReviewSession.formatRate) ?? "",
            maxText: rate.maxValue.map(ChemicalReviewSession.formatRate) ?? "",
            unit: rate.unit.isEmpty ? "L" : rate.unit, rawText: rate.rawText ?? "",
            conditionIsAmbiguous: rate.conditionIsAmbiguous
        )
    }

    private func unit(for token: String) -> ChemicalUnit {
        ChemicalUnit.fromLabelRateToken(token) ?? .litres
    }
}

@MainActor
private struct ChemicalSearchV2ReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store
    @State private var draft: ChemicalSearchV2View.ReviewDraft
    @State private var notice: String?
    @State private var isSaving: Bool = false
    @State private var isOptionalDetailsExpanded: Bool = false
    @State private var duplicate: SavedChemical?
    let photoData: Data?
    let onOpenExisting: (SavedChemical) -> Void
    let onSaved: (SavedChemical) -> Void
    let onComplete: (String) -> Void

    init(
        draft: ChemicalSearchV2View.ReviewDraft,
        photoData: Data?,
        onOpenExisting: @escaping (SavedChemical) -> Void,
        onSaved: @escaping (SavedChemical) -> Void,
        onComplete: @escaping (String) -> Void
    ) {
        _draft = State(initialValue: draft)
        self.photoData = photoData
        self.onOpenExisting = onOpenExisting
        self.onSaved = onSaved
        self.onComplete = onComplete
    }

    private var parsedRate: ChemicalLabelRate? {
        let temp = ChemicalManualDraft(productName: draft.productName, productRates: [draft.rate])
        return ChemicalManualEntry.proposedIntelligence(from: temp, existing: nil)
            .registeredUses.first(where: ChemicalManualEntry.isProductRateCarrier)?.rates.first
    }

    private var effectiveRates: [ChemicalLabelRate] {
        ChemicalSearchV2OperationalDefaults.effectiveRates(
            automatic: draft.automaticRates,
            edited: parsedRate
        )
    }

    private var enteredLabelRate: ChemicalLabelRate? {
        guard let rate = draft.enteredLabelRate else { return nil }
        let proposal = ChemicalManualEntry.proposedIntelligence(
            from: ChemicalManualDraft(productName: draft.productName, productRates: [rate]), existing: nil
        )
        return proposal.registeredUses.first(where: ChemicalManualEntry.isProductRateCarrier)?.rates.first
    }

    private var reviewIntelligence: ChemicalIntelligence {
        var proposed = draft.isManual
            ? draft.manualDetails.intelligence(productName: draft.productName, rate: draft.rate)
            : draft.intelligence
        let details = draft.manualDetails
        if !draft.isManual {
            if proposed.productCategory.isEmpty { proposed.productCategory = details.productCategory.trimmingCharacters(in: .whitespaces) }
            if proposed.activeIngredients.isEmpty, !details.activeIngredient.trimmingCharacters(in: .whitespaces).isEmpty {
                proposed.activeIngredients = details.activeIngredient.split(separator: ",").map {
                    ChemicalActiveIngredient(name: String($0).trimmingCharacters(in: .whitespaces), identitySource: .manualEntry)
                }
            }
            if !details.labelURL.trimmingCharacters(in: .whitespaces).isEmpty,
               proposed.registration?.labelReference?.isEmpty ?? true {
                var registration = proposed.registration ?? ChemicalRegistration(countryCode: "")
                registration.labelReference = details.labelURL.trimmingCharacters(in: .whitespaces)
                proposed.registration = registration
            }
        }
        proposed.activeIngredients = proposed.activeIngredients.map { active in
            guard let edit = draft.activeCorrections[active.name] else { return active }
            var updated = active
            if !active.hasConcentration,
               let value = Double(edit.concentrationText.replacingOccurrences(of: ",", with: ".")),
               let unit = edit.concentrationUnit {
                updated.concentration = value
                updated.concentrationUnit = unit
            }
            if active.activityGroup?.isResistanceRelevant != true,
               let scheme = edit.scheme, scheme != .notApplicable,
               !edit.groupCode.trimmingCharacters(in: .whitespaces).isEmpty {
                updated.activityGroup = ChemicalActivityGroup(scheme: scheme, code: edit.groupCode)
            }
            return updated
        }
        if let enteredLabelRate,
           !proposed.registeredUses.filter(\.isViticultural).flatMap(\.rates).contains(where: ChemicalSaveContract.isUsable) {
            proposed.registeredUses.append(ChemicalRegisteredUse(
                crop: "Grapes", targetRaw: "Entered manually from label", rates: [enteredLabelRate],
                provenance: ["rates": "manual_entry"]
            ))
        }
        return draft.isManual ? proposed : ChemicalEditReconciler.reconcile(existing: draft.intelligence, proposed: proposed).intelligence
    }

    private var completeness: ChemicalDetailsCompleteness {
        ChemicalDetailsCompleteness.assess(
            name: draft.productName,
            category: reviewIntelligence.productCategory,
            form: draft.manualDetails.productForm.isEmpty ? (draft.formType ?? "") : draft.manualDetails.productForm,
            intelligence: reviewIntelligence,
            labelURL: draft.manualDetails.labelURL,
            hasDefaultRate: !effectiveRates.isEmpty,
            hasLabelRate: reviewIntelligence.registeredUses.filter(\.isViticultural).flatMap(\.rates).contains(where: ChemicalSaveContract.isUsable)
        )
    }

    private var evaluation: ChemicalSaveEvaluation {
        ChemicalSaveContract.evaluateMinimumOperational(
            productName: draft.productName, productUnit: draft.unit.rawValue,
            rates: effectiveRates
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(completeness.title).font(.headline)
                    if let missing = completeness.missingText { Text(missing).font(.caption).foregroundStyle(.secondary) }
                    Text("Source: \(draft.isManual ? "Entered manually" : draft.source == "VineTrack Master" ? "VineTrack Master" : reviewIntelligence.registration?.labelReference == nil ? "Online lookup" : "Product label")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if draft.isManual {
                    Section("Required") {
                        TextField("Chemical / product name *", text: $draft.productName)
                        Label("Enter the details you have; missing fields can be completed below.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Product") {
                        TextField("Chemical / product name *", text: $draft.productName)
                        LabeledContent("Registrant", value: draft.intelligence.registration?.registrant?.ifEmpty("Not found — check label") ?? "Not found — check label")
                        LabeledContent("APVMA", value: draft.source == "Product label / web"
                            ? (draft.intelligence.registration?.registrationNumber.map { "\($0) (from label)" } ?? "Not stated on label")
                            : (draft.intelligence.hasEvidencedRegistration
                                ? (draft.intelligence.registration?.registrationNumber ?? "Not found — check label") : "APVMA number not available"))
                        LabeledContent("Active ingredients", value: draft.intelligence.activeIngredients.map(\.displayLabelWithGroup).joined(separator: ", ").ifEmpty("Needs confirmation — check label"))
                        LabeledContent("Category", value: draft.intelligence.productCategory.isEmpty ? "Not found — check label" : draft.intelligence.productCategory.capitalized)
                        LabeledContent("Product form", value: draft.manualDetails.productForm.ifEmpty(draft.formType ?? "Needs confirmation"))
                        if let label = [draft.intelligence.registration?.manufacturerLabelURL,
                                        draft.intelligence.registration?.regulatorLabelURL,
                                        draft.intelligence.registration?.labelReference]
                            .compactMap({ $0 }).compactMap(URL.init(string:))
                            .first(where: { $0.scheme == "https" && $0.host != nil && $0.path.lowercased().hasSuffix(".pdf") }) {
                            Link("View Label", destination: label)
                        } else {
                            Text("Label not found — check product packaging").foregroundStyle(.secondary)
                        }
                    }
                    Section(draft.source == "Product label / web" ? "Vineyard label rates" : "Registered vineyard rates") {
                        if draft.viticultureRates.all.isEmpty {
                            Text("Grapevine use / rate not found — check label.")
                                .foregroundStyle(.secondary)
                        }
                        if !draft.viticultureRates.perHectare.isEmpty {
                            LabeledContent("Per hectare") {
                                VStack(alignment: .trailing) {
                                    ForEach(draft.viticultureRates.perHectare) { Text($0.displayRate) }
                                }
                            }
                        }
                        if !draft.viticultureRates.per100Litres.isEmpty {
                            LabeledContent("Per 100 L") {
                                VStack(alignment: .trailing) {
                                    ForEach(draft.viticultureRates.per100Litres) { Text($0.displayRate) }
                                }
                            }
                        }
                        if draft.source == "Product label / web" {
                            ForEach(draft.intelligence.registeredUses.filter(\.isViticultural)) { use in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(use.targetRaw.isEmpty ? use.crop : "\(use.crop) · \(use.targetRaw)")
                                        .font(.subheadline.weight(.semibold))
                                    ForEach(use.rates) { rate in Text(rate.displayRate).font(.caption) }
                                    if let days = use.withholdingPeriodDays { Text("Withholding: \(days) days").font(.caption) }
                                    if let reEntry = use.reEntryStatement { Text("Re-entry: \(reEntry)").font(.caption) }
                                    if let restrictions = use.restrictions { Text(restrictions).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
                Section {
                    let rates = draft.viticultureRates.all
                    if rates.count > 1 {
                        Picker("Registered rate", selection: $draft.selectedRegisteredRateID) {
                            Text("Enter/edit manually").tag(String?.none)
                            ForEach(rates) { rate in Text(rate.displayRate).tag(Optional(rate.id)) }
                        }
                        .onChange(of: draft.selectedRegisteredRateID) { _, id in
                            guard let rate = rates.first(where: { $0.id == id }) else {
                                draft.automaticRates = [:]
                                draft.rate = ChemicalManualRateDraft()
                                return
                            }
                            if let basis = ChemicalDefaultRateBasis.of(rate.basis) {
                                draft.automaticRates = [basis: rate]
                            }
                            draft.rate = ChemicalManualRateDraft(
                                label: rate.label, basis: rate.basis,
                                valueText: rate.value.map(ChemicalReviewSession.formatRate) ?? "",
                                minText: rate.minValue.map(ChemicalReviewSession.formatRate) ?? "",
                                maxText: rate.maxValue.map(ChemicalReviewSession.formatRate) ?? "",
                                unit: rate.unit.isEmpty ? "L" : rate.unit,
                                rawText: rate.rawText ?? "",
                                conditionIsAmbiguous: rate.conditionIsAmbiguous
                            )
                            draft.unit = ChemicalUnit.fromLabelRateToken(draft.rate.unit) ?? draft.unit
                        }
                    }
                    ChemicalManualRateEditor(rate: $draft.rate, allowsRemoval: false, onRemove: {})
                    Picker("Product unit *", selection: $draft.unit) {
                        ForEach(ChemicalUnit.allCases, id: \.rawValue) { Text($0.rawValue).tag($0) }
                    }
                } header: {
                    Text("Operational Default Rate *")
                } footer: {
                    Text("If rate is not found, check the label and enter the correct vineyard rate here. Rate bases are stored exactly as entered and never converted.")
                }
                Section {
                    DisclosureGroup("Fill missing details", isExpanded: $isOptionalDetailsExpanded) {
                            if !draft.isManual {
                                TextField("Category", text: $draft.manualDetails.productCategory)
                                TextField("Product form (liquid or solid)", text: $draft.manualDetails.productForm)
                                if draft.intelligence.activeIngredients.isEmpty {
                                    TextField("Active ingredient(s), comma separated", text: $draft.manualDetails.activeIngredient)
                                }
                                TextField("Product label link", text: $draft.manualDetails.labelURL)
                                    .textInputAutocapitalization(.never).keyboardType(.URL)
                            }
                            if draft.isManual {
                            TextField("Manufacturer / registrant", text: $draft.manualDetails.manufacturer)
                            TextField("APVMA registration number", text: $draft.manualDetails.registrationNumber)
                                .keyboardType(.numberPad)
                            TextField("Category", text: $draft.manualDetails.productCategory)
                            TextField("Product form", text: $draft.manualDetails.productForm)
                            TextField("Active ingredient(s), comma separated", text: $draft.manualDetails.activeIngredient)
                            Picker("Activity group", selection: $draft.manualDetails.activityGroupScheme) {
                                Text("Not specified").tag(ChemicalActivityGroupScheme?.none)
                                ForEach(ChemicalActivityGroupScheme.allCases, id: \.rawValue) {
                                    Text($0.label).tag(Optional($0))
                                }
                            }
                            if draft.manualDetails.activityGroupScheme != nil {
                                TextField("Group code", text: $draft.manualDetails.activityGroupCode)
                            }
                            TextField("Label URL", text: $draft.manualDetails.labelURL)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                            }
                            ForEach(reviewIntelligence.activeIngredients.filter {
                                !$0.hasConcentration || ($0.activityGroup?.isResistanceRelevant != true && !draft.isManual) || draft.activeCorrections[$0.name] != nil
                            }, id: \.name) { active in
                                VStack(alignment: .leading) {
                                    Text(active.name).font(.subheadline.weight(.semibold))
                                    let binding = Binding<ChemicalManualActiveDraft>(
                                        get: { draft.activeCorrections[active.name] ?? ChemicalManualActiveDraft(name: active.name) },
                                        set: { draft.activeCorrections[active.name] = $0 }
                                    )
                                    if !active.hasConcentration || draft.activeCorrections[active.name] != nil {
                                        TextField("Concentration", text: binding.concentrationText).keyboardType(.decimalPad)
                                        Picker("Concentration unit", selection: binding.concentrationUnit) {
                                            Text("Choose unit").tag(ChemicalConcentrationUnit?.none)
                                            ForEach(ChemicalConcentrationUnit.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                                        }
                                    }
                                    if !draft.isManual, active.activityGroup?.isResistanceRelevant != true {
                                        Picker("Resistance group system", selection: binding.scheme) {
                                            Text("Not stated").tag(ChemicalActivityGroupScheme?.none)
                                            ForEach(ChemicalActivityGroupScheme.allCases, id: \.rawValue) { Text($0.label).tag(Optional($0)) }
                                        }
                                        if binding.wrappedValue.scheme != nil {
                                            TextField("Group code", text: binding.groupCode)
                                        }
                                    }
                                }
                            }
                            if draft.isManual {
                            TextField("Product URL", text: $draft.manualDetails.productURL)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                            TextField("Notes", text: $draft.manualDetails.notes, axis: .vertical)
                            TextField("Pack size", text: $draft.manualDetails.packSize)
                                .keyboardType(.decimalPad)
                            TextField("Pack unit", text: $draft.manualDetails.packUnit)
                            TextField("Price per pack", text: $draft.manualDetails.pricePerPack)
                                .keyboardType(.decimalPad)
                            TextField("Inventory quantity", text: $draft.manualDetails.inventoryQuantity)
                                .keyboardType(.decimalPad)
                            TextField("Inventory unit", text: $draft.manualDetails.inventoryUnit)
                            }
                            if draft.enteredLabelRate != nil {
                                ChemicalManualRateEditor(rate: Binding(
                                    get: { draft.enteredLabelRate ?? ChemicalManualRateDraft() },
                                    set: { draft.enteredLabelRate = $0 }
                                ), allowsRemoval: false, onRemove: {})
                            } else if completeness.missing.contains("label rate") {
                                Button("Enter vineyard rate from product label") { draft.enteredLabelRate = ChemicalManualRateDraft() }
                            }
                        }
                }
                if let duplicate {
                    Section {
                        Text("\(duplicate.name) already exists in this vineyard.")
                            .foregroundStyle(.orange)
                        Button("Use Chemical") { onSaved(duplicate); onComplete("Used \(duplicate.name)") }
                    }
                }
                if let notice { Text(notice).foregroundStyle(.orange) }
                ForEach(evaluation.violations, id: \.code) { Text($0.message).font(.caption).foregroundStyle(.red) }
            }
            .navigationTitle(draft.isManual ? "Add Chemical Manually" : "Review Chemical")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!evaluation.isSatisfied || isSaving) }
            }
        }
    }

    private func save() {
        guard !isSaving, evaluation.isSatisfied, let rate = effectiveRates.first else { return }
        let intelligence = reviewIntelligence
        if let existing = ChemicalSearchV2Duplicate.existing(
            master: draft.master, intelligence: intelligence, name: draft.productName,
            in: store.savedChemicals
        ) {
            duplicate = existing
            notice = nil
            return
        }
        guard let vineyardId = store.selectedVineyardId else { notice = "Select a vineyard first."; return }
        guard let canonicalIntelligence = ChemicalLabelRateNormalizer.normalize(intelligence) else {
            notice = "Invalid stored rate. Correct the unit, amount and rate basis before saving."
            return
        }
        isSaving = true
        let basis: ChemicalRateBasis = rate.basis.isVolumeBased ? .per100Litres : .perHectare
        let display = rate.value ?? rate.minValue ?? 0
        let legacyRates: [ChemicalRate] = rate.value.map {
            [ChemicalRate(label: rate.label, value: draft.unit.toBase($0), basis: basis)]
        } ?? []
        let defaults = ChemicalSearchV2OperationalDefaults.storedDefaults(
            rates: effectiveRates,
            selectedAt: Date().ISO8601Format()
        )
        let parseOptional: (String) -> Double? = {
            Double($0.replacingOccurrences(of: ",", with: "."))
        }
        let details = draft.manualDetails
        let packSize = parseOptional(details.packSize)
        let pricePerPack = parseOptional(details.pricePerPack)
        let purchase: ChemicalPurchase? = draft.isManual && (packSize != nil || pricePerPack != nil)
            ? ChemicalPurchase(
                brand: details.manufacturer,
                activeIngredient: details.activeIngredient,
                chemicalGroup: details.activityGroupCode,
                labelURL: details.labelURL,
                costDollars: pricePerPack ?? 0,
                containerSizeML: packSize ?? 0,
                containerUnit: draft.unit
            )
            : nil
        let chemical = SavedChemical(
            vineyardId: vineyardId, name: draft.productName,
            ratePerHa: basis == .perHectare && rate.value != nil ? display : nil,
            unit: draft.unit, chemicalGroup: canonicalIntelligence.legacyChemicalGroup,
            manufacturer: draft.isManual ? details.manufacturer : (draft.intelligence.registration?.registrant ?? ""),
            notes: draft.isManual ? details.notes : "",
            activeIngredient: canonicalIntelligence.legacyActiveIngredient,
            rates: legacyRates,
            purchase: purchase,
            labelURL: details.labelURL.isEmpty ? (intelligence.registration?.labelReference ?? "") : details.labelURL,
            productURL: draft.isManual ? details.productURL : (draft.intelligence.registration?.manufacturerProductURL ?? ""),
            productCategory: intelligence.productCategory,
            productForm: details.productForm.isEmpty ? (draft.formType ?? "") : details.productForm,
            packSize: draft.isManual ? packSize : nil,
            packUnit: draft.isManual ? details.packUnit : "",
            pricePerPack: draft.isManual ? pricePerPack : nil,
            inventoryQuantity: draft.isManual ? parseOptional(details.inventoryQuantity) : nil,
            inventoryUnit: draft.isManual ? details.inventoryUnit : "",
            chemicalIntelligence: canonicalIntelligence,
            masterChemicalId: draft.master?.id ?? draft.masterMatch?.masterChemicalId,
            masterSourceRevision: draft.master?.catalogueVersion ?? draft.masterMatch?.masterRevision,
            defaultRates: defaults,
            entrySource: SavedChemicalEntrySource.reviewed(
                isManual: draft.isManual, isMaster: draft.master != nil || draft.masterMatch != nil, intelligence: canonicalIntelligence
            )
        )
        store.addSavedChemical(chemical)
        guard store.savedChemicals.contains(where: { $0.id == chemical.id }) else {
            isSaving = false
            notice = "Couldn't save the chemical. Please try again."
            return
        }
        onSaved(chemical)
        guard let photoData else { onComplete("Saved \(chemical.name)"); return }
        Task {
            do {
                try await ChemicalLabelAttachmentRepository().upload(photoData, vineyardId: vineyardId, chemicalId: chemical.id)
                onComplete("Saved \(chemical.name) with label photo")
            } catch {
                onComplete("Saved \(chemical.name), but the label photo could not be uploaded")
            }
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
