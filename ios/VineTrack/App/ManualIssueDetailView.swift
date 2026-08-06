import SwiftUI
import MapKit

/// Manual Issue detail: map location, full fields, and the status actions
/// (edit, assign via edit, start progress, complete, reopen, cancel,
/// delete). No cost, labour or machinery sections — a manual issue is never
/// pruning or Work Task data.
struct ManualIssueDetailView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(ManualIssueSyncService.self) private var issueService
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(\.dismiss) private var dismiss

    let issueId: UUID

    @State private var showEdit = false
    @State private var confirmCancel = false
    @State private var confirmDelete = false
    @State private var members: [BackendVineyardMember] = []

    private var issue: ManualIssueRecord? {
        issueService.issues.first { $0.id == issueId }
    }

    var body: some View {
        Group {
            if let issue {
                content(issue)
            } else {
                ContentUnavailableView("Issue not found", systemImage: "mappin.slash")
            }
        }
        .navigationTitle("Manual Issue")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let vineyardId = store.selectedVineyardId else { return }
            do {
                members = try await SupabaseTeamRepository().listMembers(vineyardId: vineyardId)
            } catch {}
        }
    }

    private func content(_ issue: ManualIssueRecord) -> some View {
        List {
            if let latitude = issue.latitude, let longitude = issue.longitude {
                Section {
                    issueMap(issue: issue, latitude: latitude, longitude: longitude)
                        .listRowInsets(EdgeInsets())
                }
            }

            Section("Issue") {
                LabeledContent("Title", value: issue.title)
                if let description = issue.description, !description.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Description")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(description)
                    }
                }
                LabeledContent("Category", value: issue.categoryValue.label)
                LabeledContent("Priority", value: issue.priorityValue.label)
                LabeledContent("Status", value: issue.statusValue.label)
            }

            Section("Location") {
                LabeledContent("Applies to", value: issue.scopeValue.label)
                if let blockName {
                    LabeledContent("Block", value: blockName)
                }
                LabeledContent("Where", value: issue.locationSummary)
            }

            Section("People & dates") {
                LabeledContent("Assigned to", value: assigneeName ?? "Unassigned")
                if let dueDate = issue.dueDate {
                    LabeledContent("Due date", value: dueDate)
                }
                LabeledContent("Created by", value: creatorName ?? "—")
                if let createdAt = issue.createdAt {
                    LabeledContent("Created", value: shortDate(createdAt))
                }
                if issue.statusValue == .completed {
                    LabeledContent("Completed", value: issue.completedAt.map(shortDate) ?? "—")
                    if let completedBy = issue.completedBy {
                        LabeledContent("Completed by", value: completedBy)
                    }
                }
            }

            Section("Actions") {
                Button {
                    showEdit = true
                } label: {
                    Label("Edit / Reassign", systemImage: "pencil")
                }
                statusActions(issue)
                Button(role: .destructive) {
                    confirmCancel = true
                } label: {
                    Label("Cancel Issue", systemImage: "xmark.circle")
                }
                .disabled(issue.statusValue == .cancelled)
                // Soft delete matches soft_delete_pin: owner/manager/supervisor.
                if accessControl.canDeleteOperationalRecords {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .sheet(isPresented: $showEdit) {
            ManualIssueComposerView(existing: issue)
        }
        .confirmationDialog("Cancel this issue?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel Issue", role: .destructive) {
                Task { await issueService.cancelOrDelete(issueId: issueId, action: "cancel") }
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The issue stays in history as cancelled.")
        }
        .confirmationDialog("Delete this issue?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await issueService.cancelOrDelete(issueId: issueId, action: "delete")
                    dismiss()
                }
            }
            Button("Keep", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func statusActions(_ issue: ManualIssueRecord) -> some View {
        switch issue.statusValue {
        case .open:
            Button {
                Task { await issueService.setStatus(issueId: issueId, status: .inProgress) }
            } label: {
                Label("Start Progress", systemImage: "play.circle")
            }
            Button {
                Task { await issueService.setStatus(issueId: issueId, status: .completed) }
            } label: {
                Label("Complete", systemImage: "checkmark.circle")
            }
        case .inProgress:
            Button {
                Task { await issueService.setStatus(issueId: issueId, status: .completed) }
            } label: {
                Label("Complete", systemImage: "checkmark.circle")
            }
            Button {
                Task { await issueService.setStatus(issueId: issueId, status: .open) }
            } label: {
                Label("Back to Open", systemImage: "arrow.uturn.left.circle")
            }
        case .completed, .cancelled:
            Button {
                Task { await issueService.setStatus(issueId: issueId, status: .open) }
            } label: {
                Label("Reopen", systemImage: "arrow.uturn.left.circle")
            }
        }
    }

    private func issueMap(issue: ManualIssueRecord, latitude: Double, longitude: Double) -> some View {
        // Canonical snapped point when available, otherwise the marker.
        let coordinate: CLLocationCoordinate2D = {
            if issue.snappedToRow == true, let lat = issue.snappedLatitude, let lon = issue.snappedLongitude {
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }()
        return Map(initialPosition: .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
        ))) {
            Annotation(issue.title, coordinate: coordinate) {
                Image(systemName: "mappin.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white, issue.statusValue.isActive ? .orange : .gray)
            }
        }
        .mapStyle(.hybrid)
        .frame(height: 200)
        .allowsHitTesting(false)
    }

    private var blockName: String? {
        guard let paddockId = issue?.paddockId else { return nil }
        return store.paddocks.first { $0.id == paddockId }?.name
    }

    private var assigneeName: String? {
        guard let id = issue?.assignedUserId else { return nil }
        return members.first { $0.userId == id }?.displayName ?? "Member"
    }

    private var creatorName: String? {
        guard let id = issue?.createdBy else { return nil }
        return members.first { $0.userId == id }?.displayName ?? "Member"
    }

    private func shortDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso) ?? fallback.date(from: iso) else {
            return String(iso.prefix(10))
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
