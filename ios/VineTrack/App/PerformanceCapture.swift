import Foundation
import UIKit
import Supabase

/// Opt-in, bounded timing evidence. No record values, keys, IDs, URLs or error messages are accepted.
@MainActor
final class PerformanceCapture {
    // Explicit deinit keeps this non-isolated: Swift's implicit isolated deinit aborts on iOS 18.x–26.3 (swiftlang/swift#88036).
    deinit {}
    static let shared = PerformanceCapture()
    private let preference = "adminPerformanceCaptureRequested"
    private let earlyPreference = "adminPerformanceEarlyCaptureOwner"
    private var earlyAccount: UUID? = UserDefaults.standard.string(forKey: "adminPerformanceEarlyCaptureOwner").flatMap(UUID.init(uuidString:))
    private var authorized: Bool = false
    private var account: UUID?
    private var foreground: Bool = false
    private var timer: Timer?
    private var lastTick: TimeInterval?
    private var origin: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var generation: UUID = UUID()
    private var rows: [String] = []
    private var dropped: Int = 0
    private var sequence: Int = 0
    private var active: [Int: String] = [:]
    private var operationCounts: [String: Int] = [:]

    // Numeric, allowlisted dataset summaries only. Recording them never
    // reads or writes the user's local sync/persistence data.
    private struct PersistenceTotals {
        var count: Int = 0
        var failureCount: Int = 0
        var offMainCount: Int = 0
        var longMainCount: Int = 0
        var totalBytes: Int64 = 0
        var maxBytes: Int = 0
        var totalReadMs: Double = 0
        var totalCodecMs: Double = 0
        var totalWriteMs: Double = 0
        var totalMainMs: Double = 0
        var maxMainMs: Double = 0
        var maxCodecMs: Double = 0

        mutating func add(_ item: PersistenceMeasurement) {
            count += 1
            if !item.succeeded { failureCount += 1 }
            if item.offMain { offMainCount += 1 }
            if item.mainMilliseconds >= 100 { longMainCount += 1 }
            totalBytes += Int64(item.bytes)
            maxBytes = max(maxBytes, item.bytes)
            totalReadMs += item.readMilliseconds
            totalCodecMs += item.codecMilliseconds
            totalWriteMs += item.writeMilliseconds
            totalMainMs += item.mainMilliseconds
            maxMainMs = max(maxMainMs, item.mainMilliseconds)
            maxCodecMs = max(maxCodecMs, item.codecMilliseconds)
        }
    }
    private var persistenceTotals: [String: PersistenceTotals] = [:]

    struct Span {
        let id: Int
        let generation: UUID
        let label: String
        let start: TimeInterval
    }

    private var hasAccess: Bool {
        authorized && account != nil && SupabaseClientProvider.shared.client.auth.currentUser?.id == account
    }
    private var preferenceKey: String { preference + "." + (account?.uuidString ?? "none") }
    var isEnabled: Bool { hasAccess && UserDefaults.standard.bool(forKey: preferenceKey) }

    private var shouldCapture: Bool {
        if isEnabled { return true }
        guard let earlyAccount else { return false }
        let current = SupabaseClientProvider.shared.client.auth.currentUser?.id
        if let current, current != earlyAccount {
            disarmEarlyCapture()
            clear()
            return false
        }
        return true
    }

    private func disarmEarlyCapture() {
        earlyAccount = nil
        UserDefaults.standard.removeObject(forKey: earlyPreference)
    }

    func suspendAuthorization() {
        if isEnabled { earlyAccount = account }
        authorized = false
        updateTimer()
    }

    func authorize(_ allowed: Bool) {
        let current = SupabaseClientProvider.shared.client.auth.currentUser?.id
        // Numeric early-launch rows are retained only for the same freshly
        // verified admin. Opt-in alone never authorizes viewing or exporting.
        if account != current && earlyAccount != current { clear() }
        account = current
        authorized = allowed && current != nil
        foreground = UIApplication.shared.applicationState == .active
        if !authorized {
            disarmEarlyCapture()
            clear()
        } else if UserDefaults.standard.bool(forKey: preferenceKey), let current {
            earlyAccount = current
            UserDefaults.standard.set(current.uuidString, forKey: earlyPreference)
        } else {
            disarmEarlyCapture()
        }
        updateTimer()
    }

    func revoke() {
        authorize(false)
    }

    func setEnabled(_ enabled: Bool) {
        guard hasAccess else { return }
        UserDefaults.standard.set(enabled, forKey: preferenceKey)
        if enabled {
            earlyAccount = account
            UserDefaults.standard.set(account?.uuidString, forKey: earlyPreference)
            clear()
        } else {
            disarmEarlyCapture()
            active.removeAll(keepingCapacity: true)
            generation = UUID()
        }
        updateTimer()
        append(enabled ? "capture enabled" : "capture stopped")
    }

    func setForeground(_ value: Bool) {
        foreground = value
        lastTick = nil
        updateTimer()
        mark(value ? "scene active" : "scene inactive")
    }

    func begin(_ label: StaticString) -> Span? {
        guard shouldCapture else { return nil }
        sequence += 1
        let name = String(describing: label)
        let span = Span(id: sequence, generation: generation, label: name, start: ProcessInfo.processInfo.systemUptime)
        // Avoid retaining unbounded metadata even if a transport never returns.
        if active.count < 128 { active[span.id] = name }
        append("begin #\(span.id) \(name)")
        return span
    }

    func end(_ span: Span?) {
        guard let span, span.generation == generation else { return }
        active.removeValue(forKey: span.id)
        guard shouldCapture else { return }
        let milliseconds = (ProcessInfo.processInfo.systemUptime - span.start) * 1000
        append(String(format: "end #%d %@ %.1f ms", span.id, span.label, milliseconds))
    }

    func mark(_ label: StaticString) {
        guard shouldCapture else { return }
        append(String(describing: label))
    }

    /// Preserve total timings while avoiding two formatted log rows for every
    /// repeated routine read. Never suppress slow operations or failures.
    func persistence(_ measurement: PersistenceMeasurement) {
        guard shouldCapture else { return }
        let operation = measurement.dataset.rawValue + "." + measurement.operation.rawValue
        let occurrence = (operationCounts[operation] ?? 0) + 1
        operationCounts[operation] = occurrence
        var totals = persistenceTotals[operation] ?? PersistenceTotals()
        totals.add(measurement)
        persistenceTotals[operation] = totals

        let exceptional = !measurement.succeeded ||
            measurement.mainMilliseconds >= 100 ||
            measurement.readMilliseconds >= 100 ||
            measurement.codecMilliseconds >= 100 ||
            measurement.writeMilliseconds >= 100
        // Retain the first three and every 32nd normal occurrence for a
        // representative timeline, plus ALL exceptional observations.
        guard exceptional || occurrence <= 3 || occurrence % 32 == 0 else { return }

        let records = measurement.records.map(String.init) ?? "unknown"
        let changed = measurement.changed.map { $0 ? "yes" : "no" } ?? "unknown"
        append(String(format: "persistence dataset=%@ operation=%@ occurrence=%d records=%@ bytes=%d read=%.1fms codec=%.1fms write=%.1fms changed=%@ decodeReused=%@ encodeReused=%@ success=%@ offMain=%@",
            measurement.dataset.rawValue, measurement.operation.rawValue, occurrence, records, measurement.bytes,
            measurement.readMilliseconds, measurement.codecMilliseconds, measurement.writeMilliseconds, changed,
            measurement.reusedDecode ? "yes" : "no", measurement.reusedEncode ? "yes" : "no",
            measurement.succeeded ? "yes" : "no", measurement.offMain ? "yes" : "no"))
        append(String(format: "occupancy operation=%@ occurrence=%d main=%.1fms longMain=%@",
            operation, occurrence, measurement.mainMilliseconds,
            measurement.mainMilliseconds >= 100 ? "yes" : "no"))
    }

    /// Aggregate pure view preparation only. This is not SwiftUI/CoreText layout or a usable-frame marker.
    func beginComputation() -> TimeInterval? {
        #if DEBUG
        if SyntheticHomePerformanceProbe.enabled { return ProcessInfo.processInfo.systemUptime }
        #endif
        return shouldCapture ? ProcessInfo.processInfo.systemUptime : nil
    }

    func endComputation(_ start: TimeInterval?, label: StaticString, records: Int) {
        #if DEBUG
        if let start { SyntheticHomePerformanceProbe.end(String(describing: label), start) }
        #endif
        guard let start, shouldCapture else { return }
        let name = String(describing: label)
        let occurrence = (operationCounts[name] ?? 0) + 1
        operationCounts[name] = occurrence
        let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        append(String(format: "viewPreparation operation=%@ occurrence=%d records=%d main=%@ elapsed=%.1fms longMain=%@",
            name, occurrence, records, Thread.isMainThread ? "yes" : "no", milliseconds,
            Thread.isMainThread && milliseconds >= 100 ? "yes" : "no"))
    }

    func clear() {
        rows.removeAll(keepingCapacity: true)
        active.removeAll(keepingCapacity: true)
        generation = UUID()
        dropped = 0
        sequence = 0
        operationCounts.removeAll(keepingCapacity: true)
        persistenceTotals.removeAll(keepingCapacity: true)
        origin = ProcessInfo.processInfo.systemUptime
        lastTick = nil
    }

    func report() -> String? {
        guard hasAccess else { return nil }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        let freeBytes = (try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize] as? NSNumber)?.int64Value
        let pending = active.sorted { $0.key < $1.key }.map { "#\($0.key) \($0.value)" }.joined(separator: ", ")
        let summary = persistenceTotals.keys.sorted().compactMap { key -> String? in
            guard let value = persistenceTotals[key] else { return nil }
            return String(format: "  %@ count=%d failures=%d offMain=%d longMain=%d totalBytes=%lld maxBytes=%d readTotal=%.1fms codecTotal=%.1fms codecMax=%.1fms writeTotal=%.1fms mainTotal=%.1fms mainMax=%.1fms",
                key, value.count, value.failureCount, value.offMainCount,
                value.longMainCount, value.totalBytes, value.maxBytes,
                value.totalReadMs, value.totalCodecMs, value.maxCodecMs,
                value.totalWriteMs, value.totalMainMs, value.maxMainMs)
        }.joined(separator: "\n")
        return """
        VineTrack iOS performance timing report
        Version: \(version) (\(build))
        OS: \(UIDevice.current.systemVersion)
        At export: Low Power Mode=\(lowPower); thermalState=\(thermal); freeBytes=\(freeBytes.map(String.init) ?? "unavailable")
        Capture enabled: \(isEnabled)
        Exported: \(Date().ISO8601Format())
        Retained events: \(rows.count); older events dropped: \(dropped)
        Unfinished spans: \(pending)
        Timings use monotonic elapsed seconds since capture reset.
        Async spans include network waiting, not just CPU work.
        Main-queue delays are scheduling evidence, not sampled stacks or exact UIKit hang durations.
        Prior verified opt-in permits a bounded numeric early-launch buffer. Viewing/export requires current system-admin verification. Earliest timings depend on when instrumentation is first reached.
        Reports are memory-only and lost on termination. The opt-in setting survives restart, but never grants admin access.
        No vineyard records, persistence keys, account IDs, credentials or raw errors are collected.
        main occupancy is synchronous wall time, not CPU. prepare offMain refers to worker codec/IO, not report delivery. Occurrences count operations, not identical-payload fingerprints. View preparation is not text layout. Export power/storage describe export time, not every earlier event.
        Persistence categories are allowlisted; counts and bytes describe whole payloads. changed=unknown means no comparison was made. Durable saves are never skipped.
        Routine persistence log events are sampled (first 3, every 32nd); all failures and operations >=100ms are logged. Aggregate totals include every measured operation.
        Persistence aggregate summary:
        \(summary)

        \(rows.joined(separator: "\n"))
        """
    }

    private func append(_ text: String) {
        guard shouldCapture else { return }
        if rows.count >= 2000 {
            rows.removeFirst(200)
            dropped += 200
        }
        rows.append(String(format: "%.3f s | %@", ProcessInfo.processInfo.systemUptime - origin, text))
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        lastTick = nil
        guard isEnabled, foreground else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            // Timer is installed only on the main run loop.
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard isEnabled, foreground else { return }
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastTick = now }
        guard let lastTick else { return }
        let delay = now - lastTick - 0.25
        if delay >= 0.25 {
            let context = active.sorted { $0.key < $1.key }.map { "#\($0.key) \($0.value)" }.joined(separator: ", ")
            append(String(format: "main-queue delay %.1f ms | active: %@", delay * 1000, context))
        }
    }
}
