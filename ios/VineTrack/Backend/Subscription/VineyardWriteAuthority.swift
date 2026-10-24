import Foundation

/// Entitlement admission only. Existing authentication/role checks remain required.
/// Holds are a separate durable ledger: operational payloads and receipts are never rewritten.
@MainActor
final class VineyardWriteAuthority {
    static let shared = VineyardWriteAuthority()
    static let holdReason = "READ_ONLY_TRIAL_EXPIRED"
    struct Restricted: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }
    private let defaults: UserDefaults
    private let key = "vinetrack.vineyardWriteHolds.v1"
    private var userId: String?
    /// Captured across suspensions; a capability refresh does not change account identity.
    var accountBinding: String? { userId }
    /// Invalidates suspended operations across sign-out/account transitions,
    /// including a return to the same UUID. Same-account capability refresh is not a transition.
    private(set) var accountGeneration: UInt64 = 0
    private var holds: [String: String]
    private(set) var deniedVineyardId: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        holds = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }
    private func scope(_ vineyardId: String) -> String? {
        userId.map { $0.lowercased() + ":" + vineyardId.lowercased() }
    }
    func bind(userId: UUID?, cached: [String: VineyardOperationalAccess] = [:]) {
        let next = userId?.uuidString
        if self.userId != next { accountGeneration &+= 1 }
        self.userId = next
        deniedVineyardId = nil
        // Cache may add a restriction; cache absence/legacy writable defaults never release one.
        for (vineyard, access) in cached where access.isTrialExpiredReadOnly {
            hold(vineyardId: vineyard, reason: Self.holdReason)
        }
    }
    func verified(vineyardId: String, access: VineyardOperationalAccess, explicitlyWritable: Bool) {
        guard let scope = scope(vineyardId) else { return }
        if access.isTrialExpiredReadOnly { hold(vineyardId: vineyardId, reason: Self.holdReason) }
        else if explicitlyWritable && access.canWrite {
            holds.removeValue(forKey: scope)
            defaults.set(holds, forKey: key)
        }
    }
    func hold(vineyardId: String, reason: String) {
        guard let scope = scope(vineyardId) else { return }
        // Preserve the more specific confirmed trial reason across server rejections.
        if holds[scope] == Self.holdReason { return }
        holds[scope] = reason
        defaults.set(holds, forKey: key)
    }
    func heldReason(vineyardId: String) -> String? { scope(vineyardId).flatMap { holds[$0] } }
    func canWrite(vineyardId: String) -> Bool { heldReason(vineyardId: vineyardId) == nil }
    func admit(vineyardId: String) -> Bool {
        guard !canWrite(vineyardId: vineyardId) else { return true }
        deniedVineyardId = vineyardId
        return false
    }
    func requireWrite(vineyardId: String) throws {
        guard admit(vineyardId: vineyardId) else {
            throw Restricted(reason: heldReason(vineyardId: vineyardId) ?? "VT_READ_ONLY")
        }
    }
    /// Structured PostgREST code or a typed local denial, never inferred from auth/network status.
    func handleServerCode(_ code: String?, vineyardId: String) -> Bool {
        guard code == "VT_READ_ONLY" else { return false }
        hold(vineyardId: vineyardId, reason: "VT_READ_ONLY")
        return true
    }
}
