import Foundation
import UIKit
import Supabase

/// Opt-in, bounded timing evidence. No record values, keys, IDs, URLs or error messages are accepted.
@MainActor
final class PerformanceCapture {
    static let shared = PerformanceCapture()
    private let preference = "adminPerformanceCaptureRequested"
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

    func suspendAuthorization() {
        authorized = false
        updateTimer()
    }

    func authorize(_ allowed: Bool) {
        let current = SupabaseClientProvider.shared.client.auth.currentUser?.id
        if account != current { clear() }
        account = current
        authorized = allowed && current != nil
        foreground = UIApplication.shared.applicationState == .active
        if !authorized { clear() }
        updateTimer()
    }

    func revoke() {
        authorize(false)
    }

    func setEnabled(_ enabled: Bool) {
        guard hasAccess else { return }
        UserDefaults.standard.set(enabled, forKey: preferenceKey)
        if enabled {
            clear()
        } else {
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
        guard isEnabled else { return nil }
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
        guard hasAccess else { return }
        let milliseconds = (ProcessInfo.processInfo.systemUptime - span.start) * 1000
        append(String(format: "end #%d %@ %.1f ms", span.id, span.label, milliseconds))
    }

    func mark(_ label: StaticString) {
        guard isEnabled else { return }
        append(String(describing: label))
    }

    /// Categories and numeric statistics only; the caller cannot supply record contents or keys.
    func persistence(_ measurement: PersistenceMeasurement) {
        guard isEnabled else { return }
        let count = measurement.records.map(String.init) ?? "unknown"
        let changed = measurement.changed.map { $0 ? "yes" : "no" } ?? "unknown"
        append(String(format: "persistence dataset=%@ operation=%@ records=%@ bytes=%d read=%.1fms codec=%.1fms write=%.1fms changed=%@ decodeReused=%@ encodeReused=%@ success=%@ offMain=%@",
            measurement.dataset.rawValue, measurement.operation.rawValue, count, measurement.bytes,
            measurement.readMilliseconds, measurement.codecMilliseconds, measurement.writeMilliseconds, changed,
            measurement.reusedDecode ? "yes" : "no", measurement.reusedEncode ? "yes" : "no",
            measurement.succeeded ? "yes" : "no", measurement.offMain ? "yes" : "no"))
    }

    func clear() {
        rows.removeAll(keepingCapacity: true)
        active.removeAll(keepingCapacity: true)
        generation = UUID()
        dropped = 0
        sequence = 0
        origin = ProcessInfo.processInfo.systemUptime
        lastTick = nil
    }

    func report() -> String? {
        guard hasAccess else { return nil }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let pending = active.sorted { $0.key < $1.key }.map { "#\($0.key) \($0.value)" }.joined(separator: ", ")
        return """
        VineTrack iOS performance timing report
        Version: \(version) (\(build))
        OS: \(UIDevice.current.systemVersion)
        Capture enabled: \(isEnabled)
        Exported: \(Date().ISO8601Format())
        Retained events: \(rows.count); older events dropped: \(dropped)
        Unfinished spans: \(pending)
        Timings use monotonic elapsed seconds since capture reset.
        Async spans include network waiting, not just CPU work.
        Main-queue delays are scheduling evidence, not sampled stacks or exact UIKit hang durations.
        Capture begins only after system-admin verification; pre-verification startup is NOT measured.
        Reports are memory-only and lost on termination. The opt-in setting survives restart, but never grants admin access.
        No vineyard records, persistence keys, account IDs, credentials or raw errors are collected.
        Persistence categories are allowlisted; counts and bytes describe whole payloads. changed=unknown means no comparison was made. Durable saves are never skipped.

        \(rows.joined(separator: "\n"))
        """
    }

    private func append(_ text: String) {
        guard hasAccess else { return }
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
