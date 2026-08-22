import Foundation
import Observation

/// The vineyard's reusable spray target vocabulary (sql/204), plus the offline
/// cache and replay queue that keep it usable in a shed with no signal.
///
/// # What "the library" actually is
///
/// Three sources, unioned, in decreasing authority:
///
///   1. **Server rows** — the shared `vineyard_spray_targets` catalogue. The
///      authoritative wording, and the reason a target added on iOS shows up on
///      Android and in the portal.
///   2. **Queued additions** — a target added offline. It is offered
///      immediately, because refusing to reuse a word the operator just typed
///      would be absurd, and it replays on the next refresh.
///   3. **Observed identifiers** — every custom target already present on this
///      vineyard's own Program Steps. A vineyard that has been writing
///      "Phomopsis" into its program since before this feature existed gets it
///      offered without anyone re-typing it, and the feature is useful the
///      moment it ships rather than after a season of data entry.
///
/// Source 3 is also why the library is never load-bearing: the identifier lives
/// on the spray, so losing this catalogue costs readability, never meaning.
///
/// # Vineyard scoping
///
/// Every read is filtered by vineyard id. A target created for Vineyard A is
/// not offered in Vineyard B — different vineyards have different pest
/// pressure, and a shared list would be noise at best and a wrong compliance
/// claim at worst.
@Observable
@MainActor
final class SprayTargetLibraryService {

    /// Server + queued entries across all vineyards; always filter by vineyard.
    private(set) var entries: [VineyardSprayTargetRecord] = []
    private(set) var pending: [VineyardSprayTargetCreateParams] = []
    var errorMessage: String?

    private let repository: VineyardSprayTargetRepository
    private var isSyncing = false

    private static let cacheKey = "vinetrack_spray_target_library_cache"
    private static let outboxKey = "vinetrack_spray_target_library_outbox"

    init(repository: VineyardSprayTargetRepository = VineyardSprayTargetRepository()) {
        self.repository = repository
        loadPersisted()
    }

    // MARK: - Reads

    /// identifier -> wording for one vineyard, for resolving stored tags.
    func labels(vineyardId: UUID?) -> [String: String] {
        guard let vineyardId else { return [:] }
        return Self.labels(in: entries, vineyardId: vineyardId)
    }

    /// This vineyard's custom targets, sorted by wording.
    ///
    /// `observed` lets the caller fold in identifiers already used on the
    /// vineyard's Program Steps, so the chooser offers what the vineyard
    /// demonstrably sprays for rather than only what has been formally added.
    func customTags(vineyardId: UUID?, observed: [SprayTargetTag] = []) -> [SprayTargetTag] {
        guard let vineyardId else { return [] }
        return Self.customTags(in: entries, vineyardId: vineyardId, observed: observed)
    }

    // MARK: - Scoping rules
    //
    // Pure, because "a target created for Vineyard A is never offered in
    // Vineyard B" is the rule most worth proving and it should not need a
    // network, a cache or a running app to prove.

    nonisolated static func labels(
        in entries: [VineyardSprayTargetRecord],
        vineyardId: UUID
    ) -> [String: String] {
        var map: [String: String] = [:]
        for entry in entries where entry.vineyardId == vineyardId && entry.isActive {
            map[entry.identifier] = entry.label
        }
        return map
    }

    nonisolated static func customTags(
        in entries: [VineyardSprayTargetRecord],
        vineyardId: UUID,
        observed: [SprayTargetTag] = []
    ) -> [SprayTargetTag] {
        var byIdentifier: [String: SprayTargetTag] = [:]
        // Observed first so a real library entry's wording wins over a
        // de-slugged approximation of the same identifier.
        for tag in observed where tag.isCustom {
            byIdentifier[tag.identifier] = tag
        }
        for entry in entries where entry.vineyardId == vineyardId && entry.isActive {
            byIdentifier[entry.identifier] = entry.tag
        }
        return byIdentifier.values
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    // MARK: - Refresh

    /// Replay queued additions, then pull the shared catalogue.
    ///
    /// A failed pull keeps the cached list: an operator offline in a block must
    /// still see the targets they use, and blanking the chooser would push them
    /// back to re-typing wording that already exists.
    func refresh(vineyardId: UUID) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        await replayOutbox()
        do {
            let remote = try await repository.listTargets(vineyardId: vineyardId)
            let pendingIds = Set(pending.map(\.id))
            let kept = entries.filter { $0.vineyardId != vineyardId || pendingIds.contains($0.id) }
            entries = kept + remote.filter { !pendingIds.contains($0.id) }
            errorMessage = nil
        } catch {
            #if DEBUG
            print("[SprayTargetLibraryService] refresh failed: \(error.localizedDescription)")
            #endif
        }
        persist()
    }

    // MARK: - Add

    /// Add a custom target to this vineyard's library and return it as a tag.
    ///
    /// De-duplication is by IDENTIFIER, which is a case-insensitive slug of the
    /// wording, so "eutypa dieback" typed into a vineyard that already has
    /// "Eutypa Dieback" returns the existing entry instead of creating a second
    /// one that the Resistance Planner would treat as a different disease.
    ///
    /// Wording that names a built-in target resolves to the built-in and is
    /// deliberately NOT written to the library — the app already ships that
    /// word, and a vineyard-level copy of it could only drift.
    ///
    /// A server failure never loses the tag: it is returned and queued, and the
    /// Program Step it was added to stores the identifier regardless.
    @discardableResult
    func addCustomTarget(wording: String, vineyardId: UUID) async -> SprayTargetTag? {
        guard let tag = SprayTargetVocabulary.tag(wording: wording) else {
            errorMessage = "Enter a target name."
            return nil
        }
        guard tag.isCustom else { return tag }

        if let existing = entries.first(where: {
            $0.vineyardId == vineyardId && $0.isActive && $0.identifier == tag.identifier
        }) {
            return existing.tag
        }

        let params = VineyardSprayTargetCreateParams(
            id: UUID(),
            vineyardId: vineyardId,
            identifier: tag.identifier,
            label: tag.label
        )
        do {
            let record = try await repository.createTarget(params)
            upsert(record)
            errorMessage = nil
            persist()
            return record.tag
        } catch where Self.isPermanentRejection(error) {
            errorMessage = Self.friendlyError(error)
            persist()
            // The vineyard library rejected it, but the operator's Program Step
            // may still legitimately carry the target — the tag is theirs, the
            // catalogue entry is a convenience.
            return tag
        } catch {
            upsert(VineyardSprayTargetRecord(
                id: params.id,
                vineyardId: vineyardId,
                identifier: tag.identifier,
                label: tag.label
            ))
            pending.removeAll { $0.identifier == params.identifier && $0.vineyardId == vineyardId }
            pending.append(params)
            persist()
            return tag
        }
    }

    // MARK: - Outbox

    func replayOutbox() async {
        guard !pending.isEmpty else { return }
        for params in pending {
            do {
                let record = try await repository.createTarget(params)
                upsert(record)
                pending.removeAll { $0.id == params.id }
            } catch where Self.isPermanentRejection(error) {
                pending.removeAll { $0.id == params.id }
                errorMessage = Self.friendlyError(error)
            } catch {
                // Offline or transient: stop rather than hammer the queue.
                break
            }
        }
        persist()
    }

    // MARK: - Local application

    private func upsert(_ record: VineyardSprayTargetRecord) {
        entries.removeAll { $0.id == record.id }
        entries.removeAll { $0.vineyardId == record.vineyardId && $0.identifier == record.identifier }
        entries.append(record)
    }

    private static func isPermanentRejection(_ error: Error) -> Bool {
        let message = String(describing: error)
        return ["TARGET_REQUIRED", "PERMISSION_DENIED", "AUTH_REQUIRED"].contains { message.contains($0) }
    }

    private static func friendlyError(_ error: Error) -> String {
        let message = String(describing: error)
        if message.contains("PERMISSION_DENIED") { return "You don't have permission to add targets here." }
        if message.contains("TARGET_REQUIRED") { return "Enter a target name." }
        return "That target couldn't be saved to the vineyard list."
    }

    // MARK: - Persistence

    private func loadPersisted() {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? decoder.decode([VineyardSprayTargetRecord].self, from: data) {
            entries = cached
        }
        if let data = UserDefaults.standard.data(forKey: Self.outboxKey),
           let queued = try? decoder.decode([VineyardSprayTargetCreateParams].self, from: data) {
            pending = queued
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        // A failed encode must never wipe previously persisted state.
        if let data = try? encoder.encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
        if let data = try? encoder.encode(pending) {
            UserDefaults.standard.set(data, forKey: Self.outboxKey)
        }
    }
}
