import Foundation
import Observation

/// Display-only worker. It never owns a repository, changes a Trip, or acknowledges sync.
/// GPS history is append-only during tracking; identity/count/endpoints avoid O(n)
/// comparisons on each timer tick. A disappeared view invalidates all publication.
@MainActor @Observable
final class ActiveTripTrailPreparation {
    private struct Signature: Equatable {
        let tripID: UUID
        let count: Int
        let first: CoordinatePoint?
        let last: CoordinatePoint?
    }
    private(set) var segments: [TrailSegment] = []
    private(set) var fullCount = 0
    private(set) var updatedAt: Date?
    private(set) var completedPreparations = 0
    private(set) var lastWorkerMilliseconds = 0.0
    private(set) var lastPublicationMilliseconds = 0.0
    private(set) var lastWorkerWasOffMain = false
    private var signature: Signature?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var worker: Task<Prepared?, Never>?

    nonisolated struct Prepared: Sendable {
        let points: [CoordinatePoint]
        let milliseconds: Double
        let offMain: Bool
    }

    /// Fixed production map contract: five colour buckets, at most 500 vertices
    /// including the four shared endpoints. No full-history work runs on MainActor.
    nonisolated static func prepare(_ points: [CoordinatePoint]) -> Task<Prepared?, Never> {
        Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return nil }
            let start = ProcessInfo.processInfo.systemUptime
            let sampled = TrailDisplayProcessor.makeDisplayPoints(points: points, maxDisplayPoints: 496)
            guard !Task.isCancelled else { return nil }
            return Prepared(points: sampled,
                milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000,
                offMain: !Thread.isMainThread)
        }
    }

    @discardableResult
    func request(tripID: UUID, points: [CoordinatePoint]) -> Bool {
        let next = Signature(tripID: tripID, count: points.count, first: points.first, last: points.last)
        guard next != signature else { return false }
        if task != nil {
            // Do not enqueue snapshots at GPS frequency. A switched Trip invalidates
            // the old work; appended points are picked up by the next timer tick.
            guard signature?.tripID != tripID else { return false }
            stop()
        }
        signature = next
        let token = generation
        let worker = Self.prepare(points)
        self.worker = worker
        task = Task { [weak self] in
            let result = await worker.value
            guard let self, !Task.isCancelled, self.generation == token else { return }
            defer { self.task = nil; self.worker = nil }
            guard let result else { self.signature = nil; return }
            let start = ProcessInfo.processInfo.systemUptime
            self.segments = TrailDisplayProcessor.makeDisplayTrailSegments(points: result.points)
            self.fullCount = next.count
            self.updatedAt = Date()
            self.lastWorkerMilliseconds = result.milliseconds
            self.lastWorkerWasOffMain = result.offMain
            self.completedPreparations += 1
            self.lastPublicationMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        return true
    }

    func stop() {
        generation = UUID()
        worker?.cancel()
        task?.cancel()
        worker = nil
        task = nil
        signature = nil
    }

    // Also used to await the real worker deterministically in native tests.
    func waitForPreparation() async { await task?.value }
}
