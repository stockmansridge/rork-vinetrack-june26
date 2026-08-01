import Foundation
import Observation

/// Per-user layout for the Home "Operational Tools" grid.
///
/// Behaviour (matches the Android `OperationalToolLayoutStore`):
/// * The layout is keyed by the authenticated user UUID — never by vineyard —
///   so it follows the user across vineyards, devices and platforms.
/// * The locally cached layout is applied synchronously on `configure` so the
///   grid never flashes hidden tools while the server call is in flight.
/// * Every change saves locally first, then pushes to Supabase. A failed push
///   keeps the local layout and is retried on the next load/change.
/// * The saved arrays hold raw tool IDs. Unauthorised tools are filtered out
///   at display time only, so restoring access restores the saved position.
@Observable
final class OperationalToolLayoutStore {

    /// Message shown after a save that only reached this device.
    static let offlineSaveMessage =
        "Your tool layout has been saved on this device and will sync when a connection is available."

    /// Message shown when the user tries to hide the last visible tool.
    static let minimumVisibleMessage = "At least one operational tool must remain visible."

    private(set) var savedVisibleIds: [String] = []
    private(set) var savedHiddenIds: [String] = []

    /// False until the cached layout for the current user has been applied.
    /// The grid renders a placeholder until this flips, which is what stops
    /// hidden tools flashing on screen during startup.
    private(set) var isReady = false

    /// True while a server read/write is in flight (never blocks the grid).
    private(set) var isSyncing = false

    /// True when the local layout is ahead of the server (save failed).
    private(set) var hasPendingSync = false

    /// Non-fatal diagnostic for the customisation screen.
    private(set) var lastSyncErrorMessage: String?

    private var userId: UUID?
    private var lastServerRefresh: Date?
    private let repository: any OperationalToolPreferencesProviding
    private let defaults: UserDefaults

    init(
        repository: any OperationalToolPreferencesProviding = OperationalToolPreferencesRepository(),
        defaults: UserDefaults = .standard
    ) {
        self.repository = repository
        self.defaults = defaults
    }

    // MARK: - Lifecycle

    /// Applies the cached layout for `userId` immediately, then refreshes from
    /// the server in the background. Safe to call repeatedly.
    func configure(userId: UUID?) {
        guard userId != self.userId else { return }
        self.userId = userId
        lastServerRefresh = nil
        hasPendingSync = false
        lastSyncErrorMessage = nil

        guard let userId else {
            savedVisibleIds = []
            savedHiddenIds = []
            isReady = true
            return
        }

        let cached = loadCache(for: userId)
        savedVisibleIds = cached.visible
        savedHiddenIds = cached.hidden
        isReady = true
        hasPendingSync = cached.pending
    }

    /// Background refresh from Supabase. Throttled — a failure silently keeps
    /// the cached layout (the grid must never be blocked by this).
    func refreshFromServer(force: Bool = false) async {
        guard let userId else { return }
        if !force, let last = lastServerRefresh, Date().timeIntervalSince(last) < 60 { return }
        if isSyncing { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let remote = try await repository.fetch()
            lastServerRefresh = Date()
            if hasPendingSync {
                // A local change never reached the server — push it instead of
                // letting the stale server copy win.
                await pushPendingLayout()
                return
            }
            apply(remote, for: userId)
            lastSyncErrorMessage = nil
        } catch {
            lastSyncErrorMessage = friendlyMessage(for: error)
        }
    }

    /// Clears in-memory state on sign-out. The per-user cache is left on disk
    /// so the same account restores instantly next time.
    func signOut() {
        userId = nil
        savedVisibleIds = []
        savedHiddenIds = []
        isReady = false
        isSyncing = false
        hasPendingSync = false
        lastSyncErrorMessage = nil
        lastServerRefresh = nil
    }

    // MARK: - Resolved layout

    /// Visible tiles, in the user's order, filtered through the authorised
    /// catalogue. Newly released authorised tools are appended at the end so a
    /// user with an older saved layout never permanently misses them.
    func visibleTools(authorised: [OperationalTool]) -> [OperationalTool] {
        let byId = Dictionary(uniqueKeysWithValues: authorised.map { ($0.id, $0) })
        let hidden = Set(savedHiddenIds)
        var result: [OperationalTool] = []
        var seen = Set<String>()
        for id in savedVisibleIds {
            guard let tool = byId[id], !seen.contains(id) else { continue }
            result.append(tool)
            seen.insert(id)
        }
        for tool in authorised where !seen.contains(tool.id) && !hidden.contains(tool.id) {
            result.append(tool)
            seen.insert(tool.id)
        }
        return result
    }

    /// Hidden tiles the caller is still entitled to. A tool hidden by
    /// PERMISSION is never listed here — only tools the user chose to hide.
    func hiddenTools(authorised: [OperationalTool]) -> [OperationalTool] {
        let byId = Dictionary(uniqueKeysWithValues: authorised.map { ($0.id, $0) })
        var result: [OperationalTool] = []
        var seen = Set<String>()
        for id in savedHiddenIds {
            guard let tool = byId[id], !seen.contains(id) else { continue }
            result.append(tool)
            seen.insert(id)
        }
        return result
    }

    var isCustomised: Bool {
        !savedVisibleIds.isEmpty || !savedHiddenIds.isEmpty
    }

    // MARK: - Mutations (auto-saving)

    /// Reorders the visible list. `offsets`/`destination` come from SwiftUI
    /// `.onMove` and index into `visibleTools(authorised:)`.
    func move(from offsets: IndexSet, to destination: Int, authorised: [OperationalTool]) {
        var visible = visibleTools(authorised: authorised).map(\.id)
        let sorted = offsets.sorted()
        let moving = sorted.compactMap { visible.indices.contains($0) ? visible[$0] : nil }
        guard !moving.isEmpty else { return }
        for index in sorted.reversed() where visible.indices.contains(index) {
            visible.remove(at: index)
        }
        let insertAt = min(max(destination - sorted.filter { $0 < destination }.count, 0), visible.count)
        visible.insert(contentsOf: moving, at: insertAt)
        commit(visible: visible, hidden: hiddenTools(authorised: authorised).map(\.id), authorised: authorised)
    }

    /// Hides a tool. Returns false (and changes nothing) when it is the last
    /// visible tool — at least one must always remain.
    @discardableResult
    func hide(toolId: String, authorised: [OperationalTool]) -> Bool {
        var visible = visibleTools(authorised: authorised).map(\.id)
        guard visible.count > 1, let index = visible.firstIndex(of: toolId) else { return false }
        visible.remove(at: index)
        var hidden = hiddenTools(authorised: authorised).map(\.id)
        if !hidden.contains(toolId) { hidden.append(toolId) }
        commit(visible: visible, hidden: hidden, authorised: authorised)
        return true
    }

    /// Restores a hidden tool to the END of the visible list.
    func show(toolId: String, authorised: [OperationalTool]) {
        var hidden = hiddenTools(authorised: authorised).map(\.id)
        guard let index = hidden.firstIndex(of: toolId) else { return }
        hidden.remove(at: index)
        var visible = visibleTools(authorised: authorised).map(\.id)
        if !visible.contains(toolId) { visible.append(toolId) }
        commit(visible: visible, hidden: hidden, authorised: authorised)
    }

    /// Back to the VineTrack default order with every authorised tool shown.
    /// Affects the current user only.
    func resetToDefault() {
        guard let userId else { return }
        savedVisibleIds = []
        savedHiddenIds = []
        hasPendingSync = false
        lastSyncErrorMessage = nil
        writeCache(visible: [], hidden: [], pending: false, for: userId)
        Task { [repository] in
            do {
                let remote = try await repository.reset()
                await MainActor.run { self.apply(remote, for: userId) }
            } catch {
                await MainActor.run {
                    self.hasPendingSync = true
                    self.lastSyncErrorMessage = Self.offlineSaveMessage
                }
            }
        }
    }

    // MARK: - Internals

    /// Applies a layout locally (instant UI + cache), then pushes it to
    /// Supabase. Unauthorised saved IDs are preserved so a later permission
    /// restore brings the tool back where the user left it.
    private func commit(visible: [String], hidden: [String], authorised: [OperationalTool]) {
        guard let userId else { return }
        let authorisedIds = Set(authorised.map(\.id))
        let carriedVisible = savedVisibleIds.filter { !authorisedIds.contains($0) && !hidden.contains($0) }
        let carriedHidden = savedHiddenIds.filter { !authorisedIds.contains($0) && !visible.contains($0) }

        savedVisibleIds = dedupe(visible + carriedVisible)
        savedHiddenIds = dedupe(hidden + carriedHidden).filter { !savedVisibleIds.contains($0) }
        writeCache(visible: savedVisibleIds, hidden: savedHiddenIds, pending: true, for: userId)
        hasPendingSync = true
        Task { await pushPendingLayout() }
    }

    private func pushPendingLayout() async {
        guard let userId else { return }
        let visible = savedVisibleIds
        let hidden = savedHiddenIds
        do {
            let remote = try await repository.save(visibleToolIds: visible, hiddenToolIds: hidden)
            // The server may have dropped retired IDs — take its answer as
            // the new truth, but only if nothing changed locally meanwhile.
            if visible == savedVisibleIds && hidden == savedHiddenIds {
                apply(remote, for: userId)
            }
            hasPendingSync = false
            lastSyncErrorMessage = nil
        } catch {
            // Keep the local layout and mark it for retry — never revert the
            // user's change because the network was unavailable.
            hasPendingSync = true
            lastSyncErrorMessage = Self.offlineSaveMessage
            #if DEBUG
            print("[opTools] layout save failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func apply(_ remote: OperationalToolPreferences, for userId: UUID) {
        savedVisibleIds = dedupe(remote.visibleToolIds)
        savedHiddenIds = dedupe(remote.hiddenToolIds).filter { !savedVisibleIds.contains($0) }
        hasPendingSync = false
        writeCache(visible: savedVisibleIds, hidden: savedHiddenIds, pending: false, for: userId)
    }

    private func dedupe(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private func friendlyMessage(for error: Error) -> String {
        if let repoError = error as? BackendRepositoryError,
           case .missingSupabaseConfiguration = repoError {
            return "VineTrack is not connected to the cloud on this device."
        }
        return "Your saved tool layout could not be refreshed. Using the layout stored on this device."
    }

    // MARK: - Local cache (per user)

    private struct CachedLayout: Codable {
        let visible: [String]
        let hidden: [String]
        let pending: Bool
    }

    private func cacheKey(for userId: UUID) -> String {
        "vinetrack.operationalTools.layout.\(userId.uuidString)"
    }

    private func loadCache(for userId: UUID) -> (visible: [String], hidden: [String], pending: Bool) {
        guard let data = defaults.data(forKey: cacheKey(for: userId)),
              let cached = try? JSONDecoder().decode(CachedLayout.self, from: data) else {
            return ([], [], false)
        }
        return (cached.visible, cached.hidden, cached.pending)
    }

    private func writeCache(visible: [String], hidden: [String], pending: Bool, for userId: UUID) {
        let payload = CachedLayout(visible: visible, hidden: hidden, pending: pending)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: cacheKey(for: userId))
    }
}
