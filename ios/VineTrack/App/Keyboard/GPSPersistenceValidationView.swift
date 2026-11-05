#if DEBUG
import SwiftUI

/// Deliberately separate from lifecycle acceptance: this screen seeds one
/// maintenance Trip and exposes the production ActiveTripView during a timed
/// point-by-point recording. All persistence is isolated; no live HTTP.
struct GPSPersistenceValidationView: View {
    @State private var fixture: GPSPersistenceFixture?
    @State private var access = BackendAccessControl()
    @State private var spraySync = SprayRecordSyncService()
    @State private var comparison = "Comparing encoders…"
    @State private var progress = "Ready for 120s recording from empty route"
    @State private var result = ""
    @State private var running = false
    @State private var completed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 4) {
                Text("ISOLATED GPS • OFFLINE UPLOADS").font(.caption.bold())
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: comparison).accessibilityIdentifier("gps.comparison")
                        Text(verbatim: progress).accessibilityIdentifier("gps.progress")
                        Text(verbatim: result).accessibilityIdentifier("gps.result")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }.font(.system(size: 10, design: .monospaced)).frame(height: completed ? 600 : (running ? 165 : 360))
                if let fixture {
                    if !completed {
                        Button("Record 120s + offline sync") { Task { await record(fixture) } }
                            .accessibilityIdentifier("gps.record").disabled(running)
                        // ActiveTripView resumes GPS on appear. Do not mount it
                        // until the empty-route recording has actually started.
                        if running, let trip = fixture.store.deviceOwnedTrip {
                            ActiveTripView(trip: trip)
                                .environment(fixture.store).environment(fixture.tracking).environment(fixture.location)
                                .environment(fixture.auth).environment(access).environment(NetworkMonitor.shared)
                                .environment(fixture.sync).environment(spraySync)
                        }
                    }
                }
                if completed { Text("Recording complete • fresh disk verified").accessibilityIdentifier("gps.complete") }
            }
        }
        .task {
            guard fixture == nil else { return }
            access.currentRole = .owner
            do {
                var reports: [String] = []
                for compact in [false, true] {
                    let paired = try GPSPersistenceFixture(points: 60_000, compact: compact)
                    paired.append(0)
                    for index in 1...6 { paired.append(index); await Task.yield() }
                    guard paired.verify() else { paired.cleanup(); throw URLError(.cannotDecodeContentData) }
                    reports.append("60k \(compact ? "COMPACT" : "LEGACY")\n\(paired.summary)")
                    paired.cleanup()
                }
                comparison = reports.joined(separator: "\n")
                let empty = try GPSPersistenceFixture(points: 0, compact: true)
                // Long enough for real button interaction during awaited sync.
                empty.transport.delayMilliseconds = 8_000
                fixture = empty
            } catch { comparison = "FAILED: \(error.localizedDescription)" }
        }
    }

    private func record(_ fixture: GPSPersistenceFixture) async {
        guard !running else { return }
        guard fixture.store.deviceOwnedTrip?.pathPoints.isEmpty == true else {
            result = "FAILED: empty-route precondition not met; no data was reset"
            return
        }
        running = true
        defer { running = false }
        let start = ProcessInfo.processInfo.systemUptime
        var rss = [GPSPersistenceFixture.rssMB()]
        var injected = 0
        var overlapping = 0
        var lastBucket = 0
        var lastProgressTick = -1
        let syncTask = Task { @MainActor in
            for _ in 0..<60 {
                fixture.sync.clearRetryCooldowns()
                do { try await fixture.sync.pushLocalTrips(vineyardId: fixture.vineyard) }
                catch { /* Expected simulated offline response, never an ACK. */ }
                try await Task.sleep(for: .seconds(1))
            }
        }
        defer { syncTask.cancel() }
        do {
            while ProcessInfo.processInfo.systemUptime - start < 120 {
                try Task.checkCancellation()
                if fixture.store.deviceOwnedTrip?.isPaused == false {
                    if fixture.transport.inFlight > 0 { overlapping += 1 }
                    fixture.append(injected)
                    injected += 1
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let bucket = Int(elapsed) / 10
                if bucket > lastBucket { rss.append(GPSPersistenceFixture.rssMB()); lastBucket = bucket }
                if Int(elapsed * 2) != lastProgressTick {
                    lastProgressTick = Int(elapsed * 2)
                    progress = "Recording \(Int(elapsed))/120s; injected=\(injected); sync attempts=\(fixture.transport.attempts); inFlight=\(fixture.transport.inFlight)"
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            syncTask.cancel()
            _ = await syncTask.result
            fixture.stopProbeTracking()
            let valid = fixture.verify() && overlapping > 0
            rss.append(GPSPersistenceFixture.rssMB())
            progress = "elapsed=\(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - start))s; injected=\(injected); route=\(fixture.store.deviceOwnedTrip?.pathPoints.count ?? 0); overlap=\(overlapping); attempts=\(fixture.transport.attempts)"
            result = "\(valid ? "PASS" : "FAILED") • fresh-store exact route + queue verification\n\(fixture.summary)\nRSS MB each ~10s=\(rss.map { String(format: "%.1f", $0) }.joined(separator: ","))\n\(fixture.controls.joined(separator: "\n"))\nService timings are NOT touch-to-render.\nSimulated empty server preflight; uploads fail offline. No live server acknowledgement.\nTwo-minute probe is not a leak, jetsam or all-day acceptance test."
            completed = valid
        } catch {
            fixture.stopProbeTracking()
            result = "FAILED: \(error.localizedDescription)"
        }
    }
}
#endif
