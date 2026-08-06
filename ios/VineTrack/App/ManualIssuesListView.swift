import SwiftUI

/// Manual Issues list — active issues by default, with search plus block,
/// status, priority and assignee filters. Reached from the Quick Action
/// (which opens the composer immediately) and from pin navigation.
struct ManualIssuesListView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(ManualIssueSyncService.self) private var issueService

    /// True when opened from the "Add Manual Issue" Quick Action — the
    /// composer is presented immediately; the list is the success flow.
    var initialCompose: Bool = false

    @State private var showComposer = false
    @State private var searchText = ""
    @State private var includeFinished = false
    @State private var statusFilter: ManualIssueStatus?
    @State private var priorityFilter: ManualIssuePriority?
    @State private var blockFilter: UUID?
    @State private var assigneeFilter: UUID?
    @State private var members: [BackendVineyardMember] = []
    @State private var didAutoCompose = false

    private var vineyardIssues: [ManualIssueRecord] {
        guard let vineyardId = store.selectedVineyardId else { return [] }
        return issueService.issues.filter { $0.vineyardId == vineyardId && $0.deletedAt == nil }
    }

    private var filteredIssues: [ManualIssueRecord] {
        vineyardIssues.filter { issue in
            if let statusFilter {
                if issue.statusValue != statusFilter { return false }
            } else if !includeFinished && !issue.statusValue.isActive {
                return false
            }
            if let priorityFilter, issue.priorityValue != priorityFilter { return false }
            if let blockFilter, issue.paddockId != blockFilter { return false }
            if let assigneeFilter, issue.assignedUserId != assigneeFilter { return false }
            if !searchText.isEmpty {
                let haystack = "\(issue.title) \(issue.description ?? "")".lowercased()
                if !haystack.contains(searchText.lowercased()) { return false }
            }
            return true
        }
    }

    var body: some View {
        List {
            if !issueService.pendingOps.isEmpty {
                Section {
                    Label("\(issueService.pendingCount) change(s) waiting to sync", systemImage: "arrow.triangle.2.circlepath")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                if filteredIssues.isEmpty {
                    ContentUnavailableView(
                        "No manual issues",
                        systemImage: "mappin.slash",
                        description: Text(includeFinished || statusFilter != nil
                            ? "Nothing matches these filters."
                            : "Open and in-progress issues appear here.")
                    )
                } else {
                    ForEach(filteredIssues) { issue in
                        NavigationLink {
                            ManualIssueDetailView(issueId: issue.id)
                        } label: {
                            ManualIssueRowView(
                                issue: issue,
                                blockName: blockName(issue.paddockId),
                                assigneeName: memberName(issue.assignedUserId),
                                isPending: issueService.isPending(issue.id)
                            )
                        }
                    }
                }
            } header: {
                filterRow
            }
        }
        .navigationTitle("Manual Issues")
        .searchable(text: $searchText, prompt: "Search issues")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showComposer = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showComposer) {
            ManualIssueComposerView()
        }
        .task {
            issueService.store = store
            if initialCompose && !didAutoCompose {
                didAutoCompose = true
                showComposer = true
            }
            await refresh()
            await loadMembers()
        }
        .refreshable { await refresh() }
        .onChange(of: includeFinished) { _, _ in Task { await refresh() } }
        .onChange(of: showComposer) { _, isShowing in
            if !isShowing { Task { await refresh() } }
        }
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Button("Active (default)") { statusFilter = nil; includeFinished = false }
                    Button("All statuses") { statusFilter = nil; includeFinished = true }
                    Divider()
                    ForEach(ManualIssueStatus.allCases, id: \.self) { status in
                        Button(status.label) {
                            statusFilter = status
                            if !status.isActive { includeFinished = true }
                        }
                    }
                } label: {
                    filterChipLabel(statusFilter?.label ?? (includeFinished ? "All statuses" : "Active"), active: statusFilter != nil || includeFinished)
                }
                Menu {
                    Button("Any priority") { priorityFilter = nil }
                    ForEach(ManualIssuePriority.allCases, id: \.self) { priority in
                        Button(priority.label) { priorityFilter = priority }
                    }
                } label: {
                    filterChipLabel(priorityFilter?.label ?? "Priority", active: priorityFilter != nil)
                }
                Menu {
                    Button("All blocks") { blockFilter = nil }
                    ForEach(store.paddocks) { paddock in
                        Button(paddock.name) { blockFilter = paddock.id }
                    }
                } label: {
                    filterChipLabel(blockName(blockFilter) ?? "Block", active: blockFilter != nil)
                }
                Menu {
                    Button("Anyone") { assigneeFilter = nil }
                    ForEach(members) { member in
                        Button(member.displayName ?? "Member") { assigneeFilter = member.userId }
                    }
                } label: {
                    filterChipLabel(memberName(assigneeFilter) ?? "Assignee", active: assigneeFilter != nil)
                }
            }
            .textCase(nil)
        }
    }

    private func filterChipLabel(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(active ? Color.orange : Color(.tertiarySystemBackground), in: .capsule)
            .foregroundStyle(active ? .white : .primary)
    }

    private func blockName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return store.paddocks.first { $0.id == id }?.name
    }

    private func memberName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return members.first { $0.userId == id }?.displayName ?? "Member"
    }

    private func refresh() async {
        guard let vineyardId = store.selectedVineyardId else { return }
        issueService.store = store
        await issueService.refresh(vineyardId: vineyardId, includeFinished: includeFinished || statusFilter?.isActive == false)
    }

    private func loadMembers() async {
        guard let vineyardId = store.selectedVineyardId else { return }
        do {
            members = try await SupabaseTeamRepository().listMembers(vineyardId: vineyardId)
        } catch {
            // Filters degrade gracefully without member names.
        }
    }
}

/// One list line: title, location/block summary, priority + status capsules,
/// assignee and due date when present.
struct ManualIssueRowView: View {
    let issue: ManualIssueRecord
    let blockName: String?
    let assigneeName: String?
    let isPending: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(priorityColor)
                    .frame(width: 8, height: 8)
                Text(issue.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if isPending {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(issue.statusValue.label)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.15), in: .capsule)
                    .foregroundStyle(statusColor)
            }
            HStack(spacing: 6) {
                if let blockName {
                    Text(blockName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(issue.locationSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 10) {
                Text(issue.priorityValue.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(priorityColor)
                if let assigneeName {
                    Label(assigneeName, systemImage: "person")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let dueDate = issue.dueDate {
                    Label(dueDate, systemImage: "calendar")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var priorityColor: Color {
        switch issue.priorityValue {
        case .low: return .gray
        case .normal: return .blue
        case .high: return .orange
        case .urgent: return .red
        }
    }

    private var statusColor: Color {
        switch issue.statusValue {
        case .open: return .orange
        case .inProgress: return .blue
        case .completed: return .green
        case .cancelled: return .gray
        }
    }
}
