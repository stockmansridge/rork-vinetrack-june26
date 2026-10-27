#if DEBUG
import SwiftUI

/// Separate opt-in sandbox. No authenticated screens, production persistence, or writes to a server.
struct SyntheticSwitchPerformanceView: View {
    @State private var reports = Array(repeating: "Preparing synthetic cache…", count: 4)
    @State private var section = CommandLine.arguments.contains("--synthetic-access-performance") ? 2 : 0
    private let sections = ["Switch", "Home", "Access", "Control"]
    var body: some View {
        NavigationStack {
            VStack {
                Picker("Evidence section", selection: $section) {
                    ForEach(sections.indices, id: \.self) { index in
                        Text(sections[index]).tag(index)
                    }
                }.pickerStyle(.segmented).padding(.horizontal)
                ScrollView {
                    Text(reports[section]).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding()
                }.id(section)
            }.navigationTitle("Synthetic switch evidence")
        }.task {
            do {
                _ = try await SyntheticSwitchPerformanceFixture.capture(prepared: false)
                let baseline = SyntheticSwitchPerformanceFixture.latestSummary
                _ = try await SyntheticSwitchPerformanceFixture.capture()
                let after = SyntheticSwitchPerformanceFixture.latestSummary
                let home = try await SyntheticHomePerformanceFixture.capture()
                let access = try SyntheticAccessPerformanceFixture.capture()
                reports = ["CURRENT SWITCH\n" + after, "HOME APPLICATION\n" + home.report,
                           "ACCESS COST SAMPLE\n" + access.report, "PAIRED UNPREPARED CONTROL\n" + baseline]
            } catch { reports = Array(repeating: "Synthetic fixture failed: \(error)", count: 4) }
        }
    }
}

@MainActor
enum SyntheticSwitchPerformanceFixture {
    static private(set) var latestSummary = ""
    static private(set) var warmCommits: [Double] = []
    static func capture(prepared: Bool = true, mounted: Bool = true, switchCount: Int = 25) async throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = PersistenceStore(directory: root)
        let store = MigratedDataStore(persistence: PersistenceStore(directory: root))
        let date = Date(timeIntervalSince1970: 1_793_059_200)
        let vineyards = [Vineyard(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, name: "Synthetic A", createdAt: date),
                         Vineyard(id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, name: "Synthetic B", createdAt: date)]
        store.vineyards = vineyards
        var pins: [VinePin] = []
        var trips: [Trip] = []
        var tasks: [WorkTask] = []
        var sprays: [SprayRecord] = []
        var chemicals: [SavedChemical] = []
        var maintenance: [MaintenanceLog] = []
        var yields: [YieldEstimationSession] = []
        var blocks: [Paddock] = []
        var tractors: [Tractor] = []
        for vineyard in vineyards {
            for i in 0..<2_000 {
                pins.append(VinePin(vineyardId: vineyard.id, latitude: -34, longitude: 138, heading: nil, buttonName: "Synthetic", buttonColor: "red", side: .left, mode: .repairs, timestamp: date, photoData: i < 20 ? Data(repeating: 42, count: 16_384) : nil))
            }
            trips += (0..<500).map { _ in Trip(vineyardId: vineyard.id, startTime: date, endTime: date, isActive: false) }
            tasks += (0..<500).map { _ in WorkTask(vineyardId: vineyard.id, date: date) }
            sprays += (0..<250).map { _ in SprayRecord(tripId: UUID(), vineyardId: vineyard.id, date: date, startTime: date) }
            chemicals += (0..<250).map { SavedChemical(vineyardId: vineyard.id, name: "Synthetic \($0)") }
            maintenance += (0..<250).map { _ in MaintenanceLog(vineyardId: vineyard.id, date: date) }
            yields += (0..<250).map { _ in YieldEstimationSession(vineyardId: vineyard.id, createdAt: date) }
            blocks += (0..<100).map { Paddock(vineyardId: vineyard.id, name: "Synthetic \($0)") }
            tractors += (0..<50).map { Tractor(vineyardId: vineyard.id, name: "Synthetic \($0)") }
        }
        try disk.saveOrThrow(pins, key: PinRepository.storageKey)
        try disk.saveOrThrow(trips, key: TripRepository.storageKey)
        try disk.saveOrThrow(tasks, key: WorkTaskRepository.storageKey)
        try disk.saveOrThrow(sprays, key: SprayRepository.recordsKey)
        try disk.saveOrThrow(chemicals, key: SprayRepository.savedChemicalsKey)
        try disk.saveOrThrow(maintenance, key: MaintenanceLogRepository.storageKey)
        try disk.saveOrThrow(yields, key: YieldRepository.sessionsKey)
        try disk.saveOrThrow(blocks, key: "vinetrack_paddocks")
        try disk.saveOrThrow(tractors, key: "vinetrack_tractors")
        var report = "Per vineyard: 2000 pins, 500 trips/tasks,\n250 spray/chemicals/maintenance/Yield,\n100 blocks, 50 tractors. No network sync.\n"
        let mount = mounted ? SyntheticHomeMount(store: store) : nil
        defer { mount?.close() }
        let display = SyntheticSwitchDisplayRecorder()
        defer { display.stop() }
        SyntheticHomePerformanceProbe.reset()
        SyntheticHomePerformanceProbe.enabled = true
        defer { SyntheticHomePerformanceProbe.enabled = false }
        if mounted { try await Task.sleep(for: .milliseconds(40)) }
        var allSamples: [[VineyardSwitchPerformanceProbe.Sample]] = []
        var totals: [Double] = []
        var boundaries: [[String: Double]] = []
        var loadingTicks: [Double?] = []
        var interactiveTicks: [Double?] = []
        var loadingLifetimes: [Double] = []
        for iteration in 0..<switchCount {
            let vineyard = vineyards[iteration % 2]
            var samples: [VineyardSwitchPerformanceProbe.Sample] = []
            store.switchPerformanceSample = { samples.append($0) }
            var boundary: [String: Double] = [:]
            store.preparedSelectionMeasurement = { boundary[$0] = $1 }
            if mounted { display.start(store: store, target: vineyard.id) }
            let started = ProcessInfo.processInfo.systemUptime
            if prepared { await store.prepareAndSelectVineyard(vineyard) }
            else { store.selectVineyard(vineyard) }
            let completion = (ProcessInfo.processInfo.systemUptime - started) * 1000
            let elapsed = prepared ? (boundary["atomic-selection-commit"] ?? completion) : completion
            if prepared {
                guard (boundary["selection-state-acknowledgement"] ?? .infinity) < 32, elapsed < 32 else {
                    throw CocoaError(.coderInvalidValue)
                }
                report += String(format: "\nAcknowledgement %.2fms; preparation including waits %.2fms; cached availability %.2fms\n",
                    boundary["selection-state-acknowledgement"] ?? 0,
                    boundary["snapshot-preparation-including-waits"] ?? 0, completion)
            }
            guard store.pins.count == 2_000, store.pins.allSatisfy({ $0.vineyardId == vineyard.id }),
                  store.trips.count == 500, store.workTasks.count == 500, store.sprayRecords.count == 250,
                  store.savedChemicals.count == 250, store.maintenanceLogs.count == 250,
                  store.yieldSessions.count == 250, store.paddocks.count == 100, store.tractors.count == 50 else {
                throw CocoaError(.coderInvalidValue)
            }
            await store.deferredSelectionRepairs?.value
            if mounted {
                for _ in 0..<10 {
                    if display.interactiveTick != nil { break }
                    try await Task.sleep(for: .milliseconds(16))
                }
            }
            boundaries.append(boundary)
            loadingTicks.append(display.loadingTick)
            interactiveTicks.append(display.interactiveTick)
            loadingLifetimes.append(completion)
            display.stop()
            allSamples.append(samples)
            totals.append(elapsed)
            report += String(format: "\nSwitch %d total %.2fms (main)\n", iteration, elapsed)
            for sample in samples { report += String(format: "%@: %.2f\n", sample.stage, sample.milliseconds) }
        }
        var summary = "Synchronous ms: cold / warm maximum\n"
        for first in allSamples[0] {
            let warm = allSamples.dropFirst().flatMap { $0 }.filter { $0.stage == first.stage }.map(\.milliseconds).max() ?? 0
            summary += String(format: "%@ %.2f / %.2f\n", first.stage, first.milliseconds, warm)
        }
        summary += String(format: "TOTAL %.2f / %.2f\n", totals[0], totals.dropFirst().max() ?? 0)
        func coldWarm(_ values: [Double]) -> String {
            String(format: "%.3f / %.3f", values.first ?? 0, values.dropFirst().max() ?? 0)
        }
        summary += "\nTransition cold / warm maximum ms (\(switchCount) alternating switches):\n"
        for stage in ["selection-state-acknowledgement", "snapshot-preparation-including-waits", "atomic-selection-commit", "deferred-legacy-spray-recovery", "deferred-variety-canonicalization"] {
            summary += "\(stage): \(coldWarm(boundaries.map { $0[stage] ?? 0 }))\n"
        }
        summary += "Loading state lifetime: \(coldWarm(loadingLifetimes))\n"
        summary += "Loading first display-link observation (not pixel proof): \(loadingTicks.first.flatMap { $0 }.map { String(format: "%.3f", $0) } ?? "not observed") / warm observed \(loadingTicks.dropFirst().compactMap { $0 }.count) of \(switchCount - 1)\n"
        summary += "Interactive first display-link observation (not input/pixel proof): \(coldWarm(interactiveTicks.compactMap { $0 }))\n"
        let warm = totals.dropFirst().sorted()
        if !warm.isEmpty {
            summary += String(format: "Warm commit p50 %.3f p95 %.3f max %.3f mean %.3fms\n", warm[warm.count / 2], warm[min(warm.count - 1, Int(Double(warm.count) * 0.95))], warm.last!, warm.reduce(0, +) / Double(warm.count))
        }
        summary += SyntheticHomePerformanceProbe.report()
        summary += "Hydration/commit stages MainActor; preparation worker decoding measured separately. No sync included. Display-link observations are NOT a drawn-surface or interactive-input latency assertion.\n\n"
        latestSummary = summary
        warmCommits = Array(totals.dropFirst())
        print("SWITCH_PERFORMANCE_BEGIN\n\(summary)\(report)SWITCH_PERFORMANCE_END")
        return summary + report
    }
}
#endif
