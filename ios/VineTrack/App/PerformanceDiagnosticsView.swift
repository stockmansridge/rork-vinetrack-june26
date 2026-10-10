import SwiftUI

/// Report controls require fresh platform-admin verification; opt-in never grants access.
struct PerformanceDiagnosticsView: View {
    @Environment(SystemAdminService.self) private var admin
    @Environment(NewBackendAuthService.self) private var auth
    @State private var enabled: Bool = false
    @State private var report: String = ""
    @State private var isVerifying: Bool = false
    @State private var isSharing: Bool = false

    var body: some View {
        Group {
            if auth.isSignedIn && admin.isSystemAdmin && !admin.isLoading {
                Form {
                    Section("Timing capture") {
                        Toggle("Capture performance timings", isOn: Binding(
                            get: { enabled },
                            set: { value in
                                Task {
                                    guard await verifyAccess() else { return }
                                    PerformanceCapture.shared.setEnabled(value)
                                    enabled = PerformanceCapture.shared.isEnabled
                                    report = PerformanceCapture.shared.report() ?? ""
                                }
                            }
                        ))
                        .disabled(isVerifying)
                        Text("Enable, return to Home, then open Trip and Program. For launch capture, leave enabled and reopen the app. A bounded numeric buffer can capture early launch; viewing and export still require fresh admin verification.")
                            .font(.footnote)
                        Text("Captures elapsed operation durations and foreground main-queue delays. Async spans include network waits, not CPU attribution or peak memory.")
                            .font(.footnote)
                    }
                    Section {
                        Button("Refresh report") { Task { await refreshReport() } }
                            .disabled(isVerifying)
                        if !report.isEmpty {
                            Button {
                                Task {
                                    guard await verifyAccess() else { return }
                                    report = PerformanceCapture.shared.report() ?? ""
                                    if !report.isEmpty { isSharing = true }
                                }
                            } label: {
                                Label("Share timing report", systemImage: "square.and.arrow.up")
                            }
                            .disabled(isVerifying)
                            Text(report)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Button("Clear timing report", role: .destructive) {
                            PerformanceCapture.shared.clear()
                            report = ""
                        }
                    } header: {
                        Text("Report")
                    } footer: {
                        Text("Up to 2,000 events kept in memory; lost on termination. Never uploaded automatically. Only the opt-in preference survives restart. No record values, names, IDs or credentials are collected.")
                    }
                }
            } else if isVerifying {
                ProgressView("Verifying system-admin access…")
            } else {
                ContentUnavailableView("System admin required", systemImage: "lock.shield")
            }
        }
        .navigationTitle("Performance Diagnostics")
        .task { await refreshReport() }
        .sheet(isPresented: $isSharing) {
            if auth.isSignedIn && admin.isSystemAdmin && !admin.isLoading {
                PerformanceTimingShareSheet(report: report)
            }
        }
        .onChange(of: admin.isSystemAdmin) { _, allowed in
            if !allowed { report = ""; enabled = false; isSharing = false }
        }
        .onChange(of: auth.userId) { _, _ in
            report = ""; enabled = false; isSharing = false
        }
    }

    private func verifyAccess() async -> Bool {
        guard !isVerifying, auth.isSignedIn else { return false }
        let account = auth.userId
        isVerifying = true
        defer { isVerifying = false }
        await admin.refresh()
        guard auth.isSignedIn, auth.userId == account, admin.isSystemAdmin else {
            report = ""; enabled = false; isSharing = false
            return false
        }
        return true
    }

    private func refreshReport() async {
        guard await verifyAccess() else { return }
        enabled = PerformanceCapture.shared.isEnabled
        report = PerformanceCapture.shared.report() ?? ""
    }
}
