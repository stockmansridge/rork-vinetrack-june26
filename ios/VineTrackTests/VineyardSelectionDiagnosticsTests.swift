import Foundation
import Testing
@testable import VineTrack

@Suite(.serialized)
@MainActor
struct VineyardSelectionDiagnosticsTests {
    init() {
        VineyardSelectionDiagnostics.resetForTesting()
    }

    @Test func sameVineyardHydrationAfterRestartDoesNotResumeInterruptedAttempt() {
        let boomey = UUID()
        VineyardSelectionDiagnostics.started(vineyardId: boomey)
        VineyardSelectionDiagnostics.stage("block-cache", vineyardId: boomey)
        VineyardSelectionDiagnostics.resetForTesting(simulatingRestart: true)

        VineyardSelectionDiagnostics.stage("core-records", vineyardId: boomey)

        let report = VineyardSelectionDiagnostics.report
        #expect(report.contains("Last stage: block-cache"))
        #expect(!report.contains("Last stage: core-records"))
        #expect(report.contains("Time since attempt started"))
    }

    @Test func returningToBellviewPreservesInterruptedAttemptAsPrevious() {
        let boomey = UUID()
        let bellview = UUID()
        VineyardSelectionDiagnostics.started(vineyardId: boomey)
        VineyardSelectionDiagnostics.stage("block-cache", vineyardId: boomey)
        VineyardSelectionDiagnostics.started(vineyardId: bellview)

        let report = VineyardSelectionDiagnostics.report
        #expect(report.contains("Current attempt"))
        #expect(report.contains("Vineyard ID: \(bellview.uuidString)"))
        #expect(report.contains("Previous attempt"))
        #expect(report.contains("Vineyard ID: \(boomey.uuidString)"))
        #expect(report.contains("Last stage: block-cache"))
    }

    @Test func manualSyncAfterCompletionCreatesFreshAttemptAndKeepsResult() {
        let vineyard = UUID()
        VineyardSelectionDiagnostics.started(vineyardId: vineyard)
        VineyardSelectionDiagnostics.syncSucceeded(vineyardId: vineyard)
        let completedReport = VineyardSelectionDiagnostics.report
        let completedAttemptId = attemptIds(in: completedReport).first

        VineyardSelectionDiagnostics.manualSyncStarted(vineyardId: vineyard)

        let report = VineyardSelectionDiagnostics.report
        let ids = attemptIds(in: report)
        #expect(ids.count == 2)
        #expect(ids.first != completedAttemptId)
        #expect(ids.last == completedAttemptId)
        #expect(report.contains("Last stage: manual sync started"))
        #expect(report.contains("Last stage: sync-succeeded"))
    }

    @Test func failedSweepIsTerminalButNeverReportedAsSuccess() {
        let vineyard = UUID()
        VineyardSelectionDiagnostics.manualSyncStarted(vineyardId: vineyard)
        VineyardSelectionDiagnostics.syncFailed(vineyardId: vineyard)

        let report = VineyardSelectionDiagnostics.report
        #expect(report.contains("Last stage: sync-failed"))
        #expect(!report.contains("Last stage: sync-succeeded"))
        #expect(report.contains("Attempt duration"))
        #expect(!report.contains("Time since attempt started"))
    }

    private func attemptIds(in report: String) -> [String] {
        report.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("Attempt ID: ") }
            .map { String($0.dropFirst("Attempt ID: ".count)) }
    }
}
