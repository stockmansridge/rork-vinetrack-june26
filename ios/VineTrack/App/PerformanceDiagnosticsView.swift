import SwiftUI

/// Report controls remain inaccessible when platform-admin verification is absent or revoked.
struct PerformanceDiagnosticsView: View {
    @Environment(SystemAdminService.self) private var admin
    @Environment(NewBackendAuthService.self) private var auth
    @State private var enabled: Bool = false
    @State private var report: String = ""

    var body: some View {
        Group {
            if auth.isSignedIn && admin.isSystemAdmin && !admin.isLoading {
                Form {
                    Section("Timing capture") {
                        Toggle("Capture performance timings", isOn: Binding(
                            get: { enabled },
                            set: { value in
                                enabled = value
                                PerformanceCapture.shared.setEnabled(value)
                                refreshReport()
                            }
                        ))
                        Text("Enable, return to Home, then open Trip and Program. Return here and refresh the report. For launch capture, leave enabled and reopen the app; measurement resumes only after admin verification.")
                            .font(.footnote)
                        Text("Captures operation durations and foreground main-queue delays. Async durations include network waiting. This is not a stack trace or an Instruments replacement.")
                            .font(.footnote)
                    }
                    Section {
                        Button("Refresh report", action: refreshReport)
                        if !report.isEmpty {
                            ShareLink(item: report) {
                                Label("Share timing report", systemImage: "square.and.arrow.up")
                            }
                            Text(report)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Button("Clear timing report", role: .destructive) {
                            PerformanceCapture.shared.clear()
                            refreshReport()
                        }
                    } header: {
                        Text("Report")
                    } footer: {
                        Text("Up to 2,000 events kept in memory. Reports do not survive force-quit and are never uploaded automatically. Only the capture preference survives restart. No record values, names, IDs or credentials are collected.")
                    }
                }
            } else {
                ContentUnavailableView("System admin required", systemImage: "lock.shield")
            }
        }
        .navigationTitle("Performance Diagnostics")
        .onAppear {
            enabled = PerformanceCapture.shared.isEnabled
            refreshReport()
        }
        .onChange(of: admin.isSystemAdmin) { _, allowed in
            if !allowed { report = ""; enabled = false }
        }
        .onChange(of: auth.userId) { _, _ in report = ""; enabled = false }
    }

    private func refreshReport() {
        guard auth.isSignedIn, admin.isSystemAdmin else { report = ""; return }
        report = PerformanceCapture.shared.report() ?? ""
    }
}
