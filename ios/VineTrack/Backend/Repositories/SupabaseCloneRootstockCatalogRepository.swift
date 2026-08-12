import Foundation
import Supabase

// MARK: - Models

/// Row from `get_grape_clone_catalog` (sql/182).
nonisolated struct SharedGrapeCloneCatalogEntry: Codable, Sendable, Hashable, Identifiable {
    let key: String
    let varietyKey: String
    let displayName: String
    let cloneCode: String
    let selectionSystem: String?
    let sourceCountry: String?
    let aliases: [String]
    let sourceReference: String?
    let isBuiltin: Bool
    let isActive: Bool
    let updatedAt: Date?

    var id: String { key }

    nonisolated enum CodingKeys: String, CodingKey {
        case key
        case varietyKey = "variety_key"
        case displayName = "display_name"
        case cloneCode = "clone_code"
        case selectionSystem = "selection_system"
        case sourceCountry = "source_country"
        case aliases
        case sourceReference = "source_reference"
        case isBuiltin = "is_builtin"
        case isActive = "is_active"
        case updatedAt = "updated_at"
    }

    init(
        key: String,
        varietyKey: String,
        displayName: String,
        cloneCode: String,
        selectionSystem: String?,
        sourceCountry: String?,
        aliases: [String],
        sourceReference: String?,
        isBuiltin: Bool = true,
        isActive: Bool = true,
        updatedAt: Date? = nil
    ) {
        self.key = key
        self.varietyKey = varietyKey
        self.displayName = displayName
        self.cloneCode = cloneCode
        self.selectionSystem = selectionSystem
        self.sourceCountry = sourceCountry
        self.aliases = aliases
        self.sourceReference = sourceReference
        self.isBuiltin = isBuiltin
        self.isActive = isActive
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        varietyKey = try c.decode(String.self, forKey: .varietyKey)
        displayName = try c.decode(String.self, forKey: .displayName)
        cloneCode = (try? c.decodeIfPresent(String.self, forKey: .cloneCode)) ?? displayName
        selectionSystem = try? c.decodeIfPresent(String.self, forKey: .selectionSystem)
        sourceCountry = try? c.decodeIfPresent(String.self, forKey: .sourceCountry)
        aliases = (try? c.decodeIfPresent([String].self, forKey: .aliases)) ?? []
        sourceReference = try? c.decodeIfPresent(String.self, forKey: .sourceReference)
        isBuiltin = (try? c.decodeIfPresent(Bool.self, forKey: .isBuiltin)) ?? true
        isActive = (try? c.decodeIfPresent(Bool.self, forKey: .isActive)) ?? true
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    /// Fallback entry derived from the bundled catalogue.
    init(builtin e: BuiltInCloneCatalog.Entry) {
        self.init(
            key: e.key,
            varietyKey: e.varietyKey,
            displayName: e.displayName,
            cloneCode: e.cloneCode,
            selectionSystem: e.selectionSystem,
            sourceCountry: e.sourceCountry,
            aliases: e.aliases,
            sourceReference: nil
        )
    }
}

/// Row from `get_rootstock_catalog` (sql/182).
nonisolated struct SharedRootstockCatalogEntry: Codable, Sendable, Hashable, Identifiable {
    let key: String
    let canonicalName: String
    let displayName: String
    let aliases: [String]
    let parentage: String?
    let sourceReference: String?
    let isBuiltin: Bool
    let isActive: Bool
    let updatedAt: Date?

    var id: String { key }

    nonisolated enum CodingKeys: String, CodingKey {
        case key
        case canonicalName = "canonical_name"
        case displayName = "display_name"
        case aliases
        case parentage
        case sourceReference = "source_reference"
        case isBuiltin = "is_builtin"
        case isActive = "is_active"
        case updatedAt = "updated_at"
    }

    init(
        key: String,
        canonicalName: String,
        displayName: String,
        aliases: [String],
        parentage: String?,
        sourceReference: String?,
        isBuiltin: Bool = true,
        isActive: Bool = true,
        updatedAt: Date? = nil
    ) {
        self.key = key
        self.canonicalName = canonicalName
        self.displayName = displayName
        self.aliases = aliases
        self.parentage = parentage
        self.sourceReference = sourceReference
        self.isBuiltin = isBuiltin
        self.isActive = isActive
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        canonicalName = try c.decode(String.self, forKey: .canonicalName)
        displayName = try c.decode(String.self, forKey: .displayName)
        aliases = (try? c.decodeIfPresent([String].self, forKey: .aliases)) ?? []
        parentage = try? c.decodeIfPresent(String.self, forKey: .parentage)
        sourceReference = try? c.decodeIfPresent(String.self, forKey: .sourceReference)
        isBuiltin = (try? c.decodeIfPresent(Bool.self, forKey: .isBuiltin)) ?? true
        isActive = (try? c.decodeIfPresent(Bool.self, forKey: .isActive)) ?? true
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    init(builtin e: BuiltInRootstockCatalog.Entry) {
        self.init(
            key: e.key,
            canonicalName: e.canonicalName,
            displayName: e.displayName,
            aliases: e.aliases,
            parentage: e.parentage,
            sourceReference: nil
        )
    }
}

/// Row from `list_vineyard_grape_clones` / `upsert_vineyard_grape_clone`.
nonisolated struct VineyardGrapeCloneRow: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let cloneKey: String
    let varietyKey: String
    let displayName: String
    let isCustom: Bool
    let isActive: Bool
    let createdAt: Date?
    let updatedAt: Date?

    nonisolated enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case cloneKey = "clone_key"
        case varietyKey = "variety_key"
        case displayName = "display_name"
        case isCustom = "is_custom"
        case isActive = "is_active"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Row from `list_vineyard_rootstocks` / `upsert_vineyard_rootstock`.
nonisolated struct VineyardRootstockRow: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let rootstockKey: String
    let displayName: String
    let isCustom: Bool
    let isActive: Bool
    let createdAt: Date?
    let updatedAt: Date?

    nonisolated enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case rootstockKey = "rootstock_key"
        case displayName = "display_name"
        case isCustom = "is_custom"
        case isActive = "is_active"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Repository

/// Supabase access for the shared clone + rootstock catalogues (sql/182).
/// Mirrors `SupabaseGrapeVarietyCatalogRepository` — same RPC surface, same
/// vineyard-scoped custom pattern.
final class SupabaseCloneRootstockCatalogRepository: Sendable {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func fetchCloneCatalog() async throws -> [SharedGrapeCloneCatalogEntry] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let rows: [SharedGrapeCloneCatalogEntry] = try await provider.client
            .rpc("get_grape_clone_catalog")
            .execute()
            .value
        return rows
    }

    func fetchRootstockCatalog() async throws -> [SharedRootstockCatalogEntry] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let rows: [SharedRootstockCatalogEntry] = try await provider.client
            .rpc("get_rootstock_catalog")
            .execute()
            .value
        return rows
    }

    func listVineyardClones(vineyardId: UUID) async throws -> [VineyardGrapeCloneRow] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        struct Params: Encodable, Sendable { let p_vineyard_id: UUID }
        let rows: [VineyardGrapeCloneRow] = try await provider.client
            .rpc("list_vineyard_grape_clones", params: Params(p_vineyard_id: vineyardId))
            .execute()
            .value
        return rows
    }

    func listVineyardRootstocks(vineyardId: UUID) async throws -> [VineyardRootstockRow] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        struct Params: Encodable, Sendable { let p_vineyard_id: UUID }
        let rows: [VineyardRootstockRow] = try await provider.client
            .rpc("list_vineyard_rootstocks", params: Params(p_vineyard_id: vineyardId))
            .execute()
            .value
        return rows
    }

    /// Create/update a vineyard-scoped CUSTOM clone. The parent variety key
    /// is REQUIRED (built-in key like `shiraz` or the vineyard's
    /// `custom:<vineyardId>:<slug>` key). The server derives a stable
    /// `custom:<vineyardId>:<varietySlug>:<slug>` clone key.
    @discardableResult
    func upsertVineyardClone(
        vineyardId: UUID,
        varietyKey: String,
        displayName: String,
        isActive: Bool = true
    ) async throws -> VineyardGrapeCloneRow {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        struct Params: Encodable, Sendable {
            let p_vineyard_id: UUID
            let p_variety_key: String
            let p_display_name: String
            let p_is_active: Bool
        }
        let row: VineyardGrapeCloneRow = try await provider.client
            .rpc("upsert_vineyard_grape_clone", params: Params(
                p_vineyard_id: vineyardId,
                p_variety_key: varietyKey,
                p_display_name: displayName,
                p_is_active: isActive
            ))
            .execute()
            .value
        return row
    }

    @discardableResult
    func upsertVineyardRootstock(
        vineyardId: UUID,
        displayName: String,
        isActive: Bool = true
    ) async throws -> VineyardRootstockRow {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        struct Params: Encodable, Sendable {
            let p_vineyard_id: UUID
            let p_display_name: String
            let p_is_active: Bool
        }
        let row: VineyardRootstockRow = try await provider.client
            .rpc("upsert_vineyard_rootstock", params: Params(
                p_vineyard_id: vineyardId,
                p_display_name: displayName,
                p_is_active: isActive
            ))
            .execute()
            .value
        return row
    }

    @discardableResult
    func archiveVineyardClone(id: UUID) async throws -> VineyardGrapeCloneRow {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        struct Params: Encodable, Sendable { let p_id: UUID }
        let row: VineyardGrapeCloneRow = try await provider.client
            .rpc("archive_vineyard_grape_clone", params: Params(p_id: id))
            .execute()
            .value
        return row
    }

    @discardableResult
    func archiveVineyardRootstock(id: UUID) async throws -> VineyardRootstockRow {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        struct Params: Encodable, Sendable { let p_id: UUID }
        let row: VineyardRootstockRow = try await provider.client
            .rpc("archive_vineyard_rootstock", params: Params(p_id: id))
            .execute()
            .value
        return row
    }
}

// MARK: - Local cache / store

/// Offline-tolerant cache of the shared clone + rootstock catalogues plus
/// the selected vineyard's custom records. Mirrors
/// `SharedGrapeVarietyCatalogCache`, with `@Observable` so pickers update
/// after refresh / custom adds.
@Observable
@MainActor
final class CloneRootstockCatalogStore {
    static let shared = CloneRootstockCatalogStore()

    private let repository: SupabaseCloneRootstockCatalogRepository
    private let systemFileURL: URL
    private let customDirURL: URL

    private(set) var systemClones: [SharedGrapeCloneCatalogEntry] = []
    private(set) var systemRootstocks: [SharedRootstockCatalogEntry] = []
    private(set) var customClones: [VineyardGrapeCloneRow] = []
    private(set) var customRootstocks: [VineyardRootstockRow] = []
    private(set) var loadedVineyardId: UUID?
    private var didLoadFromDisk = false

    private nonisolated struct SystemSnapshot: Codable {
        let clones: [SharedGrapeCloneCatalogEntry]
        let rootstocks: [SharedRootstockCatalogEntry]
    }

    private nonisolated struct CustomSnapshot: Codable {
        let clones: [VineyardGrapeCloneRow]
        let rootstocks: [VineyardRootstockRow]
    }

    private init(
        repository: SupabaseCloneRootstockCatalogRepository = SupabaseCloneRootstockCatalogRepository()
    ) {
        self.repository = repository
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.systemFileURL = dir.appendingPathComponent("shared_clone_rootstock_catalog.json")
        self.customDirURL = dir
    }

    /// System catalogue with bundled fallback — never empty.
    var effectiveSystemClones: [SharedGrapeCloneCatalogEntry] {
        loadCachedIfNeeded()
        if systemClones.isEmpty {
            return BuiltInCloneCatalog.entries.map { SharedGrapeCloneCatalogEntry(builtin: $0) }
        }
        return systemClones
    }

    var effectiveSystemRootstocks: [SharedRootstockCatalogEntry] {
        loadCachedIfNeeded()
        if systemRootstocks.isEmpty {
            return BuiltInRootstockCatalog.entries.map { SharedRootstockCatalogEntry(builtin: $0) }
        }
        return systemRootstocks
    }

    /// Clone options for ONE variety: system catalogue entries + this
    /// vineyard's active custom clones. A custom Shiraz clone never
    /// surfaces under Chardonnay.
    func systemClones(forVarietyKey key: String) -> [SharedGrapeCloneCatalogEntry] {
        effectiveSystemClones.filter { $0.varietyKey == key && $0.isActive }
    }

    func customClones(forVarietyKey key: String) -> [VineyardGrapeCloneRow] {
        customClones.filter { $0.varietyKey == key && $0.isActive }
    }

    func activeCustomRootstocks() -> [VineyardRootstockRow] {
        customRootstocks.filter { $0.isActive }
    }

    func loadCachedIfNeeded() {
        guard !didLoadFromDisk else { return }
        didLoadFromDisk = true
        guard let data = try? Data(contentsOf: systemFileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let snapshot = try? decoder.decode(SystemSnapshot.self, from: data) {
            systemClones = snapshot.clones
            systemRootstocks = snapshot.rootstocks
        }
    }

    /// Refresh the system catalogues (and, when a vineyard is given, its
    /// custom records). Failures preserve the previous cache/fallback.
    func refresh(vineyardId: UUID?) async {
        loadCachedIfNeeded()
        do {
            async let clones = repository.fetchCloneCatalog()
            async let rootstocks = repository.fetchRootstockCatalog()
            let (c, r) = try await (clones, rootstocks)
            systemClones = c
            systemRootstocks = r
            persistSystem()
        } catch {
            // Keep cached/bundled copy.
        }

        guard let vineyardId else { return }
        if loadedVineyardId != vineyardId {
            // Vineyard switch: show the new vineyard's cached custom rows
            // immediately while the network read runs.
            loadCustomFromDisk(vineyardId: vineyardId)
        }
        loadedVineyardId = vineyardId
        do {
            async let clones = repository.listVineyardClones(vineyardId: vineyardId)
            async let rootstocks = repository.listVineyardRootstocks(vineyardId: vineyardId)
            let (c, r) = try await (clones, rootstocks)
            customClones = c
            customRootstocks = r
            persistCustom(vineyardId: vineyardId)
        } catch {
            // Keep cached copy for this vineyard.
        }
    }

    /// Create a custom clone and mirror it locally so the picker updates
    /// immediately. Throws when offline — callers degrade to free text.
    @discardableResult
    func addCustomClone(
        vineyardId: UUID,
        varietyKey: String,
        displayName: String
    ) async throws -> VineyardGrapeCloneRow {
        let row = try await repository.upsertVineyardClone(
            vineyardId: vineyardId,
            varietyKey: varietyKey,
            displayName: displayName
        )
        if loadedVineyardId == vineyardId || loadedVineyardId == nil {
            loadedVineyardId = vineyardId
            customClones.removeAll { $0.cloneKey == row.cloneKey && $0.vineyardId == row.vineyardId }
            customClones.append(row)
            persistCustom(vineyardId: vineyardId)
        }
        return row
    }

    @discardableResult
    func addCustomRootstock(
        vineyardId: UUID,
        displayName: String
    ) async throws -> VineyardRootstockRow {
        let row = try await repository.upsertVineyardRootstock(
            vineyardId: vineyardId,
            displayName: displayName
        )
        if loadedVineyardId == vineyardId || loadedVineyardId == nil {
            loadedVineyardId = vineyardId
            customRootstocks.removeAll { $0.rootstockKey == row.rootstockKey && $0.vineyardId == row.vineyardId }
            customRootstocks.append(row)
            persistCustom(vineyardId: vineyardId)
        }
        return row
    }

    /// Soft-archive a custom clone (`archive_vineyard_grape_clone`,
    /// owner/manager only) and drop it from the local mirror. Historical
    /// block allocations keep resolving by key.
    @discardableResult
    func archiveCustomClone(id: UUID, vineyardId: UUID) async throws -> VineyardGrapeCloneRow {
        let row = try await repository.archiveVineyardClone(id: id)
        customClones.removeAll { $0.id == id }
        persistCustom(vineyardId: vineyardId)
        return row
    }

    /// Rootstock counterpart of `archiveCustomClone` (`archive_vineyard_rootstock`).
    @discardableResult
    func archiveCustomRootstock(id: UUID, vineyardId: UUID) async throws -> VineyardRootstockRow {
        let row = try await repository.archiveVineyardRootstock(id: id)
        customRootstocks.removeAll { $0.id == id }
        persistCustom(vineyardId: vineyardId)
        return row
    }

    // MARK: Persistence

    private func customFileURL(vineyardId: UUID) -> URL {
        customDirURL.appendingPathComponent("vineyard_clone_rootstock_\(vineyardId.uuidString.lowercased()).json")
    }

    private func loadCustomFromDisk(vineyardId: UUID) {
        customClones = []
        customRootstocks = []
        guard let data = try? Data(contentsOf: customFileURL(vineyardId: vineyardId)) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let snapshot = try? decoder.decode(CustomSnapshot.self, from: data) {
            customClones = snapshot.clones
            customRootstocks = snapshot.rootstocks
        }
    }

    private func persistSystem() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let snapshot = SystemSnapshot(clones: systemClones, rootstocks: systemRootstocks)
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: systemFileURL, options: .atomic)
    }

    private func persistCustom(vineyardId: UUID) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let snapshot = CustomSnapshot(clones: customClones, rootstocks: customRootstocks)
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: customFileURL(vineyardId: vineyardId), options: .atomic)
    }
}
