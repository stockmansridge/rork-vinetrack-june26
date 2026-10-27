#if DEBUG
import SwiftUI
import UIKit

/// Numeric, opt-in evidence for isolated tests; never enabled by normal launch.
@MainActor
enum SyntheticHomePerformanceProbe {
    struct Stage { let name: String; let milliseconds: Double }
    static var enabled = false
    static var stages: [Stage] = []
    static var publications = 0
    static var persistence: [PersistenceMeasurement] = []
    static func reset() { stages = []; publications = 0; persistence = [] }
    static func start() -> TimeInterval? { enabled ? ProcessInfo.processInfo.systemUptime : nil }
    static func end(_ name: String, _ start: TimeInterval?) {
        guard enabled, let start else { return }
        stages.append(Stage(name: name, milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000))
    }
    static func publication() { if enabled { publications += 1 } }
    static func report() -> String {
        var result = "iOS mounted Home, production remote application primitives; no network latency.\n"
        for name in Set(stages.map(\.name)).sorted() {
            let values = stages.filter { $0.name == name }.map(\.milliseconds)
            result += String(format: "%@: count=%d max=%.3fms total=%.3fms\n", name, values.count, values.max() ?? 0, values.reduce(0, +))
        }
        let writes = persistence.filter { $0.operation == .save || $0.operation == .durableSave }
        result += "Observable collection mutations: \(publications); MainActor persistence calls: \(persistence.filter { !$0.offMain }.count); writes: \(writes.count)\n"
        result += String(format: "Persistence longest MainActor occupancy %.3fms\n", persistence.map(\.mainMilliseconds).max() ?? 0)
        return result
    }
}

private struct SyntheticHomeOfflineKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var syntheticHomeOffline: Bool {
        get { self[SyntheticHomeOfflineKey.self] }
        set { self[SyntheticHomeOfflineKey.self] = newValue }
    }
}

@MainActor
enum SyntheticHomePerformanceFixture {
    struct Result {
        let report: String
        let longestMainStage: Double
        let summaryMaximum: Double
        let summaryCount: Int
        let publications: Int
        let persistenceCount: Int
    }
    static func capture() async throws -> Result {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = PersistenceStore(directory: root)
        let store = MigratedDataStore(persistence: disk)
        let vineyard = Vineyard(name: "Synthetic Home")
        store.vineyards = [vineyard]
        store.selectedVineyardId = vineyard.id
        let window = store.settings.seasonWindow(for: store.settings.currentSeasonVintage)
        let date = window.start.addingTimeInterval(86_400)
        let blocks = (0..<100).map { Paddock(vineyardId: vineyard.id, name: "Block \($0)") }
        store.paddocks = blocks
        let pins = (0..<2_000).map { index in
            VinePin(vineyardId: vineyard.id, latitude: -34, longitude: 138, heading: nil,
                    buttonName: "Synthetic", buttonColor: "red", side: .left, mode: .repairs,
                    paddockId: blocks[index % blocks.count].id, timestamp: date)
        }
        let trips = (0..<500).map { _ in Trip(vineyardId: vineyard.id, startTime: date, endTime: date, isActive: false) }
        let tasks = (0..<500).map { _ in WorkTask(vineyardId: vineyard.id, date: date) }
        let sprays = (0..<250).map { _ in SprayRecord(tripId: UUID(), vineyardId: vineyard.id, date: date, startTime: date) }
        let chemicals = (0..<250).map { SavedChemical(vineyardId: vineyard.id, name: "Chemical \($0)") }
        let maintenance = (0..<250).map { _ in MaintenanceLog(vineyardId: vineyard.id, date: date) }
        let yields = (0..<250).map { _ in YieldEstimationSession(vineyardId: vineyard.id, createdAt: date) }
        // Existing realistic collections precede incoming changed records.
        try disk.saveOrThrow(pins, key: PinRepository.storageKey)
        try disk.saveOrThrow(trips, key: TripRepository.storageKey)
        try disk.saveOrThrow(tasks, key: WorkTaskRepository.storageKey)
        try disk.saveOrThrow(sprays, key: SprayRepository.recordsKey)
        try disk.saveOrThrow(chemicals, key: SprayRepository.savedChemicalsKey)
        try disk.saveOrThrow(maintenance, key: MaintenanceLogRepository.storageKey)
        try disk.saveOrThrow(yields, key: YieldRepository.sessionsKey)
        store.reloadCurrentVineyardData()
        store.paddocks = blocks
        let mount = SyntheticHomeMount(store: store)
        defer { mount.close() }
        SyntheticHomePerformanceProbe.reset()
        SyntheticHomePerformanceProbe.enabled = true
        disk.onPersistenceMeasurementForTesting = { SyntheticHomePerformanceProbe.persistence.append($0) }
        defer {
            disk.onPersistenceMeasurementForTesting = nil
            SyntheticHomePerformanceProbe.enabled = false
        }
        // Run-loop turns allow actual SwiftUI body/layout between application batches.
        for _ in 0..<3 { try await Task.sleep(for: .milliseconds(20)) }
        var scrollUpdates = 0
        let scrolling = Task { @MainActor in
            for index in 0..<600 {
                guard !Task.isCancelled else { return }
                if mount.scroll(step: index) { scrollUpdates += 1 }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        defer { scrolling.cancel() }
        func stage(_ name: String, _ action: () throws -> Void) rethrows {
            let start = ProcessInfo.processInfo.systemUptime
            defer { SyntheticHomePerformanceProbe.end(name, start) }
            try action()
        }
        var changedPins = Array(pins.prefix(200))
        for index in changedPins.indices { changedPins[index].notes = "Synced pin" }
        try stage("sync pins batch 200") {
            try store.applyRemotePinBatch(vineyardId: vineyard.id,
                cacheSnapshot: store.pinRepo.loadAllForDurableUpdate(), upserts: changedPins, deleting: [])
        }
        try await Task.sleep(for: .milliseconds(20))
        try stage("sync tasks batch 100") {
            var changed = Array(tasks.prefix(100))
            for index in changed.indices { changed[index].date = date.addingTimeInterval(60) }
            try store.applyRemoteWorkTaskBatch(changed.map { .upsert($0) }, for: vineyard.id, persisted: store.workTaskRepo.loadForReconciliation())
        }
        try await Task.sleep(for: .milliseconds(20))
        try await ResponsiveRemoteApplication.forEach(Array(trips.prefix(50)), isCurrent: store.remoteApplicationCurrentCheck()) { trip in
            await store.prepareRemoteTripCache()
            var changed = trip
            changed.endTime = date.addingTimeInterval(60)
            stage("sync trip row") { store.applyRemoteTripUpsert(changed) }
        }
        try await Task.sleep(for: .milliseconds(20))
        try await ResponsiveRemoteApplication.forEach(Array(sprays.prefix(50)), isCurrent: store.remoteApplicationCurrentCheck()) { spray in
            var changed = spray
            changed.date = date.addingTimeInterval(60)
            stage("sync spray row") { store.applyRemoteSprayRecordUpsert(changed) }
        }
        try await Task.sleep(for: .milliseconds(20))
        try stage("sync chemicals batch 100") {
            var changed = Array(chemicals.prefix(100))
            for index in changed.indices { changed[index].name = "Synced chemical" }
            try store.applyRemoteSavedChemicalBatch(changed, for: vineyard.id, persisted: store.sprayRepo.loadChemicalsForReconciliation())
        }
        try await Task.sleep(for: .milliseconds(20))
        for var log in maintenance.prefix(20) {
            await Task.yield()
            log.date = date.addingTimeInterval(60)
            stage("sync maintenance row") { store.applyRemoteMaintenanceLogUpsert(log) }
        }
        // Yield does not feed the vintage summary; exercise its existing application only.
        stage("sync Yield 10 uninterrupted") {
            for var session in yields.prefix(10) {
                session.createdAt = date.addingTimeInterval(60)
                stage("sync Yield row") { store.applyRemoteYieldSessionUpsert(session) }
            }
        }
        for _ in 0..<3 { try await Task.sleep(for: .milliseconds(20)) }
        guard store.pins.count == 2_000, store.trips.count == 500, store.workTasks.count == 500,
              store.sprayRecords.count == 250, store.savedChemicals.count == 250 else { throw CocoaError(.coderInvalidValue) }
        let probe = SyntheticHomePerformanceProbe.self
        let summaries = probe.stages.filter { $0.name == "Home vintage summary" }
        let report = probe.report() + "Programmatic scroll updates during application: \(scrollUpdates). Weather card excluded to prevent all weather transport; no gesture/frame claim. Growth records are service-owned and not Home inputs.\n"
        print("HOME_PERFORMANCE_BEGIN\n\(report)HOME_PERFORMANCE_END")
        return Result(report: report, longestMainStage: probe.stages.map(\.milliseconds).max() ?? 0,
                      summaryMaximum: summaries.map(\.milliseconds).max() ?? 0, summaryCount: summaries.count,
                      publications: probe.publications, persistenceCount: probe.persistence.count)
    }
}

@MainActor
final class SyntheticHomeMount {
    let window: UIWindow
    init(store: MigratedDataStore) {
        let home = NewHomeTabView(selectedTab: .constant(0))
            .modifier(VineyardLoadingPresentation())
            .environment(store).environment(NewBackendAuthService())
            .environment(BackendAccessControl()).environment(OperationalToolLayoutStore())
            .environment(SystemAdminService()).environment(TripTrackingService())
            .environment(AlertService()).environment(AppNoticeService())
            .environment(SyncStatusCenter()).environment(NetworkMonitor())
            .environment(\.syntheticHomeOffline, true)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = UIHostingController(rootView: home)
        window.makeKeyAndVisible()
    }
    func close() { window.isHidden = true; window.rootViewController = nil }
    func scroll(step: Int) -> Bool {
        func find(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height { return scroll }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        guard let view = window.rootViewController?.view, let scroll = find(view) else { return false }
        let maximum = max(0, scroll.contentSize.height - scroll.bounds.height)
        let phase = CGFloat(step % 80) / 40
        scroll.setContentOffset(CGPoint(x: 0, y: maximum * (phase <= 1 ? phase : 2 - phase)), animated: false)
        return true
    }
}

/// Display-link observations are render opportunities, NOT pixel-present proof.
/// They deliberately stay separate from the synchronous state acknowledgement.
@MainActor
final class SyntheticSwitchDisplayRecorder: NSObject {
    private var link: CADisplayLink?
    private weak var store: MigratedDataStore?
    private var target: UUID?
    private var origin: TimeInterval = 0
    private(set) var loadingTick: Double?
    private(set) var interactiveTick: Double?
    func start(store: MigratedDataStore, target: UUID) {
        stop()
        self.store = store; self.target = target
        origin = ProcessInfo.processInfo.systemUptime
        loadingTick = nil; interactiveTick = nil
        let link = CADisplayLink(target: self, selector: #selector(tick))
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    @objc private func tick() {
        guard let store else { return }
        let elapsed = (ProcessInfo.processInfo.systemUptime - origin) * 1000
        if store.preparingVineyard?.id == target, loadingTick == nil { loadingTick = elapsed }
        if store.preparingVineyard == nil, store.selectedVineyardId == target, interactiveTick == nil { interactiveTick = elapsed }
    }
    func stop() { link?.invalidate(); link = nil }
}
#endif
