import Foundation

/// Durable, bounded breadcrumbs for diagnosing vineyard-selection and full-sync stalls.
/// They intentionally store no record contents, names, credentials, or payloads.
@MainActor
enum VineyardSelectionDiagnostics {
    private struct Snapshot: Codable {
        let attemptId: UUID
        let appVersion: String
        let appBuild: String
        let vineyardId: UUID
        let startedAt: Date
        let stage: String
        let stageStartedAt: Date
        let completedAt: Date?
    }

    private struct History: Codable {
        var current: Snapshot?
        var previous: Snapshot?
    }

    private struct LegacySnapshot: Codable {
        let appVersion: String
        let appBuild: String
        let vineyardId: UUID
        let startedAt: Date
        let stage: String
        let stageStartedAt: Date
        let completedAt: Date?
    }

    private static let key = "vinetrack_vineyard_selection_diagnostic_v2"
    private static let legacyKey = "vinetrack_vineyard_selection_diagnostic_v1"
    /// Traceability aid only; it identifies the reviewed source snapshot and
    /// expected batch path, not archive integrity or successful execution.
    static let sourceBuildFingerprint = "VT-IOS-BATCH-54184BA-PINSYNC-131D9D217C38-FILTERS-R2"
    /// Deliberately not reconstructed from disk: relaunch hydration must never
    /// continue an attempt which was interrupted in a previous process.
    private static var activeAttemptId: UUID?

    static func started(vineyardId: UUID) {
        beginAttempt(vineyardId: vineyardId, stage: "selection")
    }

    /// Starts a separate attempt for an operator-requested full sweep. Automatic
    /// startup sweeps only append to an already-active selection attempt.
    static func manualSyncStarted(vineyardId: UUID) {
        beginAttempt(vineyardId: vineyardId, stage: "manual sync started")
    }

    static func stage(_ stage: String, vineyardId: UUID) {
        updateActive(vineyardId: vineyardId, stage: stage, completedAt: nil)
    }

    /// Records one bounded full-sweep interval marker without record contents.
    static func intervalStage(
        _ operation: String,
        phase: String,
        vineyardId: UUID,
        count: Int,
        elapsedSince startedAt: Date? = nil
    ) {
        let elapsed = startedAt.map { max(0, Date().timeIntervalSince($0)) }
        let formattedElapsed = elapsed.map { String(format: "%.3f", $0) }
        let timing = formattedElapsed.map { " elapsed=\($0)s" } ?? ""
        stage("\(operation)-\(phase) count=\(max(0, count))\(timing)", vineyardId: vineyardId)
    }

    static func hydrationCompleted(vineyardId: UUID) {
        stage("hydration-completed", vineyardId: vineyardId)
    }

    static func syncSucceeded(vineyardId: UUID) {
        finish(vineyardId: vineyardId, stage: "sync-succeeded")
    }

    static func syncFailed(vineyardId: UUID) {
        finish(vineyardId: vineyardId, stage: "sync-failed")
    }

    static func syncCancelled(vineyardId: UUID) {
        finish(vineyardId: vineyardId, stage: "sync-cancelled")
    }

    static var report: String {
        let history = loadHistory()
        guard history.current != nil || history.previous != nil else {
            return "Vineyard selection diagnostic: no attempt recorded"
        }
        var sections: [String] = []
        if let current = history.current {
            sections.append(format(current, label: "Current attempt"))
        }
        if let previous = history.previous {
            sections.append(format(previous, label: "Previous attempt"))
        }
        return "Vineyard selection diagnostic\nSource build fingerprint (traceability only): \(sourceBuildFingerprint)\nExpected pin merge: staged durable batch / pin-merge-cache-r1-w1-p…\n\n" + sections.joined(separator: "\n\n")
    }

    private static func beginAttempt(vineyardId: UUID, stage: String) {
        let now = Date()
        let attemptId = UUID()
        var history = loadHistory()
        history.previous = history.current
        history.current = Snapshot(
            attemptId: attemptId,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            vineyardId: vineyardId,
            startedAt: now,
            stage: stage,
            stageStartedAt: now,
            completedAt: nil
        )
        activeAttemptId = attemptId
        persist(history)
    }

    private static func finish(vineyardId: UUID, stage: String) {
        if updateActive(vineyardId: vineyardId, stage: stage, completedAt: Date()) {
            activeAttemptId = nil
        }
    }

    @discardableResult
    private static func updateActive(vineyardId: UUID, stage: String, completedAt: Date?) -> Bool {
        guard let activeAttemptId else { return false }
        var history = loadHistory()
        guard let snapshot = history.current,
              snapshot.attemptId == activeAttemptId,
              snapshot.vineyardId == vineyardId,
              snapshot.completedAt == nil else { return false }
        history.current = Snapshot(
            attemptId: snapshot.attemptId,
            appVersion: snapshot.appVersion,
            appBuild: snapshot.appBuild,
            vineyardId: snapshot.vineyardId,
            startedAt: snapshot.startedAt,
            stage: stage,
            stageStartedAt: Date(),
            completedAt: completedAt
        )
        persist(history)
        return true
    }

    private static func loadHistory() -> History {
        if let data = UserDefaults.standard.data(forKey: key),
           let history = try? JSONDecoder().decode(History.self, from: data) {
            return history
        }
        guard let data = UserDefaults.standard.data(forKey: legacyKey),
              let legacy = try? JSONDecoder().decode(LegacySnapshot.self, from: data) else {
            return History()
        }
        return History(
            current: Snapshot(
                attemptId: UUID(),
                appVersion: legacy.appVersion,
                appBuild: legacy.appBuild,
                vineyardId: legacy.vineyardId,
                startedAt: legacy.startedAt,
                stage: legacy.stage,
                stageStartedAt: legacy.stageStartedAt,
                completedAt: legacy.completedAt
            ),
            previous: nil
        )
    }

    private static func persist(_ history: History) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func format(_ snapshot: Snapshot, label: String) -> String {
        let elapsed = (snapshot.completedAt ?? Date()).timeIntervalSince(snapshot.startedAt)
        let elapsedLabel = snapshot.completedAt == nil ? "Time since attempt started" : "Attempt duration"
        return """
        \(label)
        Attempt ID: \(snapshot.attemptId.uuidString)
        App: \(snapshot.appVersion) (\(snapshot.appBuild))
        Vineyard ID: \(snapshot.vineyardId.uuidString)
        Last stage: \(snapshot.stage)
        Started: \(snapshot.startedAt.formatted(.iso8601))
        Stage started: \(snapshot.stageStartedAt.formatted(.iso8601))
        Completed: \(snapshot.completedAt?.formatted(.iso8601) ?? "no")
        \(elapsedLabel): \(String(format: "%.3f", elapsed)) seconds
        """
    }

    #if DEBUG
    static func resetForTesting(simulatingRestart: Bool = false) {
        activeAttemptId = nil
        guard !simulatingRestart else { return }
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }
    #endif
}
