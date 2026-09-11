import Foundation

/// One durable, bounded breadcrumb for diagnosing vineyard-selection stalls.
/// It intentionally stores no record contents, names, credentials, or payloads.
@MainActor
enum VineyardSelectionDiagnostics {
    private struct Snapshot: Codable {
        let appVersion: String
        let appBuild: String
        let vineyardId: UUID
        let startedAt: Date
        let stage: String
        let stageStartedAt: Date
        let completedAt: Date?
    }

    private static let key = "vinetrack_vineyard_selection_diagnostic_v1"
    private static var startedAt: Date?

    static func started(vineyardId: UUID) {
        let now = Date()
        startedAt = now
        persist(vineyardId: vineyardId, stage: "selection", stageStartedAt: now, completedAt: nil)
    }

    static func stage(_ stage: String, vineyardId: UUID) {
        guard let snapshot = loadSnapshot(),
              snapshot.vineyardId == vineyardId,
              snapshot.completedAt == nil else { return }
        startedAt = snapshot.startedAt
        persist(vineyardId: vineyardId, stage: stage, stageStartedAt: Date(), completedAt: nil)
    }

    static func hydrationCompleted(vineyardId: UUID) {
        stage("hydration-completed", vineyardId: vineyardId)
    }

    static func syncCompleted(vineyardId: UUID) {
        guard let snapshot = loadSnapshot(),
              snapshot.vineyardId == vineyardId,
              snapshot.completedAt == nil else { return }
        let now = Date()
        startedAt = snapshot.startedAt
        persist(vineyardId: vineyardId, stage: "sync-completed", stageStartedAt: now, completedAt: now)
    }

    static var report: String {
        guard let snapshot = loadSnapshot() else {
            return "Vineyard selection diagnostic: no selection recorded"
        }
        let elapsed = (snapshot.completedAt ?? Date()).timeIntervalSince(snapshot.startedAt)
        return """
        Vineyard selection diagnostic
        App: \(snapshot.appVersion) (\(snapshot.appBuild))
        Vineyard ID: \(snapshot.vineyardId.uuidString)
        Last stage: \(snapshot.stage)
        Started: \(snapshot.startedAt.formatted(.iso8601))
        Stage started: \(snapshot.stageStartedAt.formatted(.iso8601))
        Completed: \(snapshot.completedAt?.formatted(.iso8601) ?? "no")
        Elapsed: \(String(format: "%.3f", elapsed)) seconds
        """
    }

    private static func loadSnapshot() -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private static func persist(
        vineyardId: UUID,
        stage: String,
        stageStartedAt: Date,
        completedAt: Date?
    ) {
        let snapshot = Snapshot(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            vineyardId: vineyardId,
            startedAt: startedAt ?? stageStartedAt,
            stage: stage,
            stageStartedAt: stageStartedAt,
            completedAt: completedAt
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
