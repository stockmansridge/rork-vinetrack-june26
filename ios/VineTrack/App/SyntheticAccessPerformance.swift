#if DEBUG
import Foundation

/// Real local enforcement operations on isolated synthetic defaults. Frequency
/// here is a deliberate stress sample, NOT an observed production call count.
@MainActor
enum SyntheticAccessPerformanceFixture {
    struct Result { let report: String; let maximum: Double }
    static func capture() throws -> Result {
        let suite = "SyntheticAccessPerformance.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let user = UUID()
        let vineyardIds = (0..<64).map { _ in UUID() }
        let entries: [[String: Any]] = vineyardIds.enumerated().map { index, id in
            ["vineyard_id": id.uuidString, "has_vineyard_access": true,
             "can_enter_vineyard": true, "can_write": index % 2 == 0,
             "read_only_reason": index % 2 == 0 ? "" : "trial_expired"]
        }
        let matrix = try JSONDecoder().decode(VineyardAccessMatrix.self,
            from: JSONSerialization.data(withJSONObject: ["vineyards": entries]))
        let cache = EntitlementVerificationStore(defaults: defaults)
        cache.save(EntitlementVerificationSnapshot(userId: user.uuidString,
            lastVerifiedAt: Date(), wasEntitled: true,
            accessibleVineyardIds: vineyardIds.map(\.uuidString),
            operationalAccessByVineyard: matrix.operationalAccessByVineyard))
        let authority = VineyardWriteAuthority(defaults: defaults)
        authority.bind(userId: user, cached: matrix.operationalAccessByVineyard)
        let role = BackendAccessControl()
        role.currentRole = .manager
        var rows: [String: [Double]] = [:]
        func measure<T>(_ label: String, _ action: () -> T) -> T {
            let start = ProcessInfo.processInfo.systemUptime
            let result = action()
            rows[label, default: []].append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            return result
        }
        for phase in ["switch", "first Home", "sync application"] {
            for iteration in 0..<32 {
                let vineyard = vineyardIds[iteration % vineyardIds.count]
                let snapshot = measure("\(phase): entitlement cache read") { cache.load(for: user) }
                guard snapshot?.userId == user.uuidString else { throw CocoaError(.coderInvalidValue) }
                _ = measure("\(phase): access matrix lookup") { matrix.entry(for: vineyard)?.operationalAccess }
                _ = measure("\(phase): role/legacy matrix") { role.legacyAccessControl(for: vineyard, userId: user) }
                measure("\(phase): authority binding") { authority.bind(userId: user) }
                let writable = measure("\(phase): write authority/hold lookup") { authority.canWrite(vineyardId: vineyard.uuidString) }
                guard writable == (iteration % 2 == 0) else { throw CocoaError(.coderInvalidValue) }
            }
        }
        var report = "64 synthetic vineyards; 32 repetitions/operation/phase. Local operation-cost stress sample, not actual call frequency or authenticated-login latency.\n"
        for name in rows.keys.sorted() {
            report += String(format: "%@: max %.4fms total %.4fms\n", name, rows[name]!.max()!, rows[name]!.reduce(0, +))
        }
        return Result(report: report, maximum: rows.values.flatMap { $0 }.max() ?? 0)
    }
}
#endif
