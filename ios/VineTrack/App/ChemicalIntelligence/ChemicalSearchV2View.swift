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
    static func existing(master: MasterChemicalV2?, intelligence: ChemicalIntelligence, name: String, in chemicals: [SavedChemical]) -> SavedChemical? {
        if let master, let found = chemicals.first(where: { $0.isActive && $0.masterChemicalId == master.id }) {
            return found
        }
        if let found = ChemicalStoreMatching.findByRegistrationIdentity(
            in: chemicals, registration: intelligence.registration
        ) { return found }
        return chemicals.first { $0.isActive && ChemicalStoreMatching.namesMatch($0.name, name) }
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
                let name = lines.first(where: { line in
                    let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    return clean.count >= 3 && clean.rangeOfCharacter(from: .letters) != nil
                        && !clean.lowercased().contains("apvma")
                })
                continuation.resume(returning: Evidence(text: text, apvmaNumber: number, searchQuery: number ?? name))
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

    @State private var query: String = ""
    @State private var results: [MasterChemicalV2] = []
    @State private var isSearching: Bool = false
    @State private var message: String?
    @State private var requestID: UUID?
    @State private var review: ReviewDraft?
    @State private var photoData: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var isShowingCamera: Bool = false
    @State private var isExternalLookupRunning: Bool = false
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
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Product name, APVMA number, active or manufacturer", text: $query)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                        .onSubmit(search)
                    Button(action: search) {
                        if isSearching { ProgressView().frame(maxWidth: .infinity) }
                        else { Label("Search VineTrack Master", systemImage: "magnifyingglass").frame(maxWidth: .infinity) }
                    }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || isSearching)
                } footer: {
                    Text("Master Catalogue only. No AI, web search or label lookup runs while you type or search here.")
                }

                if let message { Text(message).foregroundStyle(.secondary) }

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

                Section("Fallbacks") {
                    Button("Can't find it? Search label online", action: searchOnline)
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || isExternalLookupRunning)
                    Button("Take Photo of Label") { isShowingCamera = true }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Choose Label Photo", systemImage: "photo.on.rectangle")
                    }
                }
            }
            .navigationTitle("Chemical Search V2")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $isShowingCamera) {
                CameraImagePicker { data in if let data { acceptPhoto(data) } }
            }
            .sheet(item: $review) { draft in
                ChemicalSearchV2ReviewView(draft: draft, photoData: photoData) { outcome in
                    message = outcome
                    review = nil
                    if outcome.hasPrefix("Saved") || outcome.hasPrefix("Already") { dismiss() }
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
                if found.isEmpty { message = "No Master Catalogue match. Use a deliberate fallback below." }
            } catch { if requestID == token { message = error.localizedDescription; results = [] } }
            if requestID == token { isSearching = false }
        }
    }

    private func openMaster(_ master: MasterChemicalV2) {
        let rates = master.grapevineRates
        let initial = rates.count == 1 ? draftRate(rates[0]) : ChemicalManualRateDraft()
        review = ReviewDraft(
            source: "VineTrack Master", master: master, intelligence: master.intelligence,
            formType: master.formType, productName: master.registeredProductName,
            unit: unit(for: initial.unit), rate: initial, viticultureRates: master.viticultureRates,
            selectedRegisteredRateID: rates.count == 1 ? rates[0].id : nil
        )
    }

    private func searchOnline() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, !isExternalLookupRunning else { return }
        isExternalLookupRunning = true; diagnostics.fallbackInvoked = true
        print("[ChemicalSearchV2] fallback_invoked=true type=label_lookup")
        Task {
            do {
                let lookup = try await externalService.lookupStructured(trimmed, "AU", nil)
                let intel = lookup.intelligence()
                let viticultureRates = ViticultureRates.fromRegisteredUses(intel.registeredUses)
                let rates = viticultureRates.all
                let initial = rates.count == 1 ? draftRate(rates[0]) : ChemicalManualRateDraft()
                review = ReviewDraft(
                    source: "Label lookup", master: nil, intelligence: intel, formType: lookup.formType,
                    productName: lookup.productName ?? trimmed, unit: unit(for: initial.unit), rate: initial,
                    viticultureRates: viticultureRates,
                    selectedRegisteredRateID: rates.count == 1 ? rates[0].id : nil
                )
                diagnostics.externalLookupSucceeded = true
                print("[ChemicalSearchV2] external_lookup=success")
            } catch {
                diagnostics.externalLookupSucceeded = false
                message = "Label lookup failed. \(error.localizedDescription)"
                print("[ChemicalSearchV2] external_lookup=failure")
            }
            isExternalLookupRunning = false
        }
    }

    private func acceptPhoto(_ data: Data) {
        photoData = data; message = "Reading visible label identity…"
        Task {
            do {
                let evidence = try await ChemicalLabelIdentityOCR.recognise(data)
                guard let identity = evidence.searchQuery else {
                    message = "No clear product identity was found. Search the Master Catalogue by name or APVMA number."
                    return
                }
                query = identity
                let found = try await repository.search(identity)
                results = found
                diagnostics.photoMatch = !found.isEmpty
                print("[ChemicalSearchV2] photo_match=\(!found.isEmpty) apvma_present=\(evidence.apvmaNumber != nil)")
                if let exact = evidence.apvmaNumber.flatMap({ number in found.first { $0.registrationNumber.filter { $0.isNumber } == number } }) {
                    message = "Suggested Master Catalogue match from APVMA number. Please confirm."
                    openMaster(exact)
                } else {
                    message = found.isEmpty ? "No Master match from the visible identity. You may explicitly search the label online." : "Possible Master matches found. Please confirm one."
                }
            } catch { message = error.localizedDescription }
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
    let photoData: Data?
    let onComplete: (String) -> Void

    init(draft: ChemicalSearchV2View.ReviewDraft, photoData: Data?, onComplete: @escaping (String) -> Void) {
        _draft = State(initialValue: draft); self.photoData = photoData; self.onComplete = onComplete
    }

    private var parsedRate: ChemicalLabelRate? {
        let temp = ChemicalManualDraft(productName: draft.productName, productRates: [draft.rate])
        return ChemicalManualEntry.proposedIntelligence(from: temp, existing: nil)
            .registeredUses.first(where: ChemicalManualEntry.isProductRateCarrier)?.rates.first
    }

    private var evaluation: ChemicalSaveEvaluation {
        ChemicalSaveContract.evaluateMinimumOperational(
            productName: draft.productName, productUnit: draft.unit.rawValue,
            rates: parsedRate.map { [$0] } ?? []
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Source") { Label(draft.source, systemImage: "checkmark.seal") }
                Section("Product") {
                    TextField("Chemical / product name *", text: $draft.productName)
                    LabeledContent("Registrant", value: draft.intelligence.registration?.registrant ?? "—")
                    LabeledContent("APVMA", value: draft.intelligence.registration?.registrationNumber ?? "—")
                    LabeledContent("Active ingredients", value: draft.intelligence.activeIngredients.map(\.name).joined(separator: ", ").ifEmpty("—"))
                    if !draft.intelligence.productCategory.isEmpty { LabeledContent("Category", value: draft.intelligence.productCategory.capitalized) }
                }
                Section("Registered vineyard rates") {
                    if draft.viticultureRates.all.isEmpty {
                        Text("No registered vineyard rate is currently recorded in VineTrack.")
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
                }
                Section("Operational Default Rate *") {
                    let rates = draft.viticultureRates.all
                    if rates.count > 1 {
                        Picker("Registered rate", selection: $draft.selectedRegisteredRateID) {
                            Text("Enter/edit manually").tag(String?.none)
                            ForEach(rates) { rate in Text(rate.displayRate).tag(Optional(rate.id)) }
                        }
                        .onChange(of: draft.selectedRegisteredRateID) { _, id in
                            if let rate = rates.first(where: { $0.id == id }) {
                                draft.rate = ChemicalManualRateDraft(
                                    label: rate.label, basis: rate.basis,
                                    valueText: rate.value.map(ChemicalReviewSession.formatRate) ?? "",
                                    minText: rate.minValue.map(ChemicalReviewSession.formatRate) ?? "",
                                    maxText: rate.maxValue.map(ChemicalReviewSession.formatRate) ?? "",
                                    unit: rate.unit.isEmpty ? "L" : rate.unit
                                )
                                draft.unit = ChemicalUnit.fromLabelRateToken(draft.rate.unit) ?? draft.unit
                            }
                        }
                    }
                    ChemicalManualRateEditor(rate: $draft.rate, allowsRemoval: false, onRemove: {})
                    Picker("Product unit *", selection: $draft.unit) {
                        ForEach(ChemicalUnit.allCases, id: \.rawValue) { Text($0.rawValue).tag($0) }
                    }
                } footer: { Text("Editable vineyard-level default. The Master Catalogue record is never changed.") }
                if let notice { Text(notice).foregroundStyle(.orange) }
                ForEach(evaluation.violations, id: \.code) { Text($0.message).font(.caption).foregroundStyle(.red) }
            }
            .navigationTitle("Review Chemical")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!evaluation.canSave || isSaving) }
            }
        }
    }

    private func save() {
        guard !isSaving, evaluation.canSave, let rate = parsedRate else { return }
        if let existing = ChemicalSearchV2Duplicate.existing(
            master: draft.master, intelligence: draft.intelligence, name: draft.productName,
            in: store.savedChemicals
        ) {
            onComplete("Already in Vineyard Chemicals: \(existing.name)")
            return
        }
        guard let vineyardId = store.selectedVineyardId else { notice = "Select a vineyard first."; return }
        guard let canonicalIntelligence = ChemicalLabelRateNormalizer.normalize(draft.intelligence) else {
            notice = "Invalid stored rate. Correct the unit, amount and rate basis before saving."
            return
        }
        isSaving = true
        let basis: ChemicalRateBasis = rate.basis.isVolumeBased ? .per100Litres : .perHectare
        let display = rate.value ?? rate.minValue ?? 0
        let legacyRates: [ChemicalRate] = rate.value.map {
            [ChemicalRate(label: rate.label, value: draft.unit.toBase($0), basis: basis)]
        } ?? []
        let storedBasis: ChemicalDefaultRateBasis = basis == .perHectare ? .perHectare : .per100Litres
        let slot: StoredChemicalDefaultRate? = {
            if let min = rate.minValue, let max = rate.maxValue {
                return .manual(basis: storedBasis, unit: rate.unit, minValue: min, maxValue: max, selectedAt: Date().ISO8601Format())
            }
            guard let value = rate.value else { return nil }
            return .manual(basis: storedBasis, unit: rate.unit, value: value, selectedAt: Date().ISO8601Format())
        }()
        let defaults = slot.map { StoredChemicalDefaultRates().withSlot(storedBasis, $0) }
        let chemical = SavedChemical(
            vineyardId: vineyardId, name: draft.productName,
            ratePerHa: basis == .perHectare && rate.value != nil ? display : nil,
            unit: draft.unit, chemicalGroup: draft.intelligence.legacyChemicalGroup,
            manufacturer: draft.intelligence.registration?.registrant ?? "",
            activeIngredient: draft.intelligence.legacyActiveIngredient,
            rates: legacyRates, labelURL: draft.intelligence.registration?.labelReference ?? "",
            productURL: draft.intelligence.registration?.manufacturerProductURL ?? "",
            productCategory: draft.intelligence.productCategory,
            productForm: draft.formType ?? "", chemicalIntelligence: canonicalIntelligence,
            masterChemicalId: draft.master?.id, masterSourceRevision: draft.master?.catalogueVersion,
            defaultRates: defaults, entrySource: draft.master == nil ? "label_lookup_v2" : "master_catalogue_v2"
        )
        store.addSavedChemical(chemical)
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
