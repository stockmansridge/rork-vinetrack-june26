import SwiftUI

/// System Admin → User Activity / Logins.
///
/// Read-only platform-admin view of every user's login recency, vineyard
/// memberships/roles and last-known device/app metadata. Backed by the
/// `admin_list_user_login_activity()` RPC (sql/094), which is gated on
/// `public.is_system_admin()`. Access is also gated client-side by
/// `SystemAdminService.isSystemAdmin`; the same RPC powers the web portal.
struct SystemAdminUserActivityView: View {
    @Environment(SystemAdminService.self) private var systemAdmin

    @State private var rows: [UserLoginActivity] = []
    @State private var isLoading: Bool = false
    @State private var loadError: String?

    @State private var searchText: String = ""
    @State private var statusFilter: StatusFilter = .all
    @State private var vineyardFilter: String = allValue
    @State private var roleFilter: String = allValue
    @State private var sortOrder: SortOrder = .lastLoginNewest

    private static let allValue = "__all__"

    // MARK: - Filter / sort models

    private enum StatusFilter: String, CaseIterable, Identifiable {
        case all
        case today
        case last7
        case last30
        case never
        case inactive30
        case inactive90

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all:        return "All"
            case .today:      return "Today"
            case .last7:      return "Last 7 days"
            case .last30:     return "Last 30 days"
            case .never:      return "Never logged in"
            case .inactive30: return "Inactive 30+ days"
            case .inactive90: return "Inactive 90+ days"
            }
        }
    }

    private enum SortOrder: String, CaseIterable, Identifiable {
        case lastLoginNewest
        case lastLoginOldest
        case createdNewest
        case nameAsc

        var id: String { rawValue }

        var label: String {
            switch self {
            case .lastLoginNewest: return "Last login (newest)"
            case .lastLoginOldest: return "Last login (oldest)"
            case .createdNewest:   return "Account created (newest)"
            case .nameAsc:         return "Name / email (A–Z)"
            }
        }
    }

    var body: some View {
        Group {
            if !systemAdmin.isSystemAdmin {
                noAccessView
            } else {
                content
            }
        }
        .navigationTitle("User Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if systemAdmin.isSystemAdmin {
                ToolbarItem(placement: .topBarTrailing) { sortMenu }
            }
        }
        .task { if systemAdmin.isSystemAdmin { await load() } }
    }

    // MARK: - No access

    private var noAccessView: some View {
        ContentUnavailableView {
            Label("No Access", systemImage: "lock.fill")
        } description: {
            Text("This screen is available to VineTrack system administrators only.")
        }
    }

    // MARK: - Main content

    private var content: some View {
        List {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                    Button("Retry") { Task { await load() } }
                }
            }

            summarySection
            filterSection

            Section {
                if filteredRows.isEmpty && !isLoading {
                    Text("No users match the current filters.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredRows) { row in
                        userRow(row)
                    }
                }
            } header: {
                Text("\(filteredRows.count) of \(rows.count) users")
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "Search name or email")
        .refreshable { await load() }
        .overlay {
            if isLoading && rows.isEmpty {
                ProgressView()
            }
        }
    }

    // MARK: - Summary

    private var summarySection: some View {
        Section {
            statRow("Total users", count: rows.count, color: .blue, symbol: "person.3.fill")
            statRow("Logged in today", count: countToday, color: .green, symbol: "sun.max.fill")
            statRow("Active last 7 days", count: countLast7, color: .teal, symbol: "bolt.fill")
            statRow("Active last 30 days", count: countLast30, color: .indigo, symbol: "calendar")
            statRow("Never logged in", count: countNever, color: .gray, symbol: "person.fill.questionmark")
            statRow("Inactive over 90 days", count: countInactive90, color: .orange, symbol: "moon.zzz.fill")
        } header: {
            Text("Overview")
        }
    }

    private func statRow(_ title: String, count: Int, color: Color, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 24)
            Text(title)
            Spacer()
            Text("\(count)")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Filters

    private var filterSection: some View {
        Section {
            Picker("Status", selection: $statusFilter) {
                ForEach(StatusFilter.allCases) { Text($0.label).tag($0) }
            }
            if availableVineyards.count > 1 {
                Picker("Vineyard", selection: $vineyardFilter) {
                    Text("All vineyards").tag(Self.allValue)
                    ForEach(availableVineyards, id: \.self) { Text($0).tag($0) }
                }
            }
            if availableRoles.count > 1 {
                Picker("Role", selection: $roleFilter) {
                    Text("All roles").tag(Self.allValue)
                    ForEach(availableRoles, id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
        } header: {
            Text("Filters")
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sortOrder) {
                ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func userRow(_ row: UserLoginActivity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.bestName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(row.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                statusBadge(row.status)
            }

            if !row.vineyardNames.isEmpty || !row.roles.isEmpty {
                HStack(spacing: 6) {
                    if !row.vineyardNames.isEmpty {
                        Label(row.vineyardNames.joined(separator: ", "),
                              systemImage: "leaf.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !row.roles.isEmpty {
                        Text(row.roles.map { $0.capitalized }.joined(separator: ", "))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                    }
                }
            }

            HStack(spacing: 12) {
                Label(lastLoginText(row), systemImage: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let created = row.accountCreatedAt {
                    Label("Joined \(created.formatted(.dateTime.month().day().year()))",
                          systemImage: "person.crop.circle.badge.plus")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if row.displayAppVersion != nil || row.displayDevice != nil {
                HStack(spacing: 12) {
                    if let version = row.displayAppVersion {
                        Label(version, systemImage: "app.badge")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let device = row.displayDevice {
                        Label(device, systemImage: "iphone")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func statusBadge(_ status: UserActivityStatus) -> some View {
        let color: Color = {
            switch status {
            case .activeRecent: return .green
            case .active30d:    return .teal
            case .inactive30d:  return .orange
            case .inactive90d:  return .red
            case .never:        return .gray
            }
        }()
        return Text(status.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func lastLoginText(_ row: UserLoginActivity) -> String {
        guard let last = row.lastSignInAt else { return "Never logged in" }
        let relative = last.formatted(.relative(presentation: .named))
        return "Last login \(relative)"
    }

    // MARK: - Derived data

    private var availableVineyards: [String] {
        var set = Set<String>()
        for row in rows { for name in row.vineyardNames { set.insert(name) } }
        return set.sorted()
    }

    private var availableRoles: [String] {
        var set = Set<String>()
        for row in rows { for role in row.roles { set.insert(role) } }
        return set.sorted()
    }

    private var startOfToday: Date {
        Calendar.current.startOfDay(for: Date())
    }

    private var countToday: Int {
        rows.filter { ($0.lastSignInAt ?? .distantPast) >= startOfToday }.count
    }

    private var countLast7: Int {
        rows.filter { $0.status == .activeRecent }.count
    }

    private var countLast30: Int {
        rows.filter { $0.status == .activeRecent || $0.status == .active30d }.count
    }

    private var countNever: Int {
        rows.filter { $0.status == .never }.count
    }

    private var countInactive90: Int {
        rows.filter { $0.status == .inactive90d }.count
    }

    private var filteredRows: [UserLoginActivity] {
        var result = rows

        // Status filter
        switch statusFilter {
        case .all:        break
        case .today:      result = result.filter { ($0.lastSignInAt ?? .distantPast) >= startOfToday }
        case .last7:      result = result.filter { $0.status == .activeRecent }
        case .last30:     result = result.filter { $0.status == .activeRecent || $0.status == .active30d }
        case .never:      result = result.filter { $0.status == .never }
        case .inactive30: result = result.filter { $0.status == .inactive30d || $0.status == .inactive90d }
        case .inactive90: result = result.filter { $0.status == .inactive90d }
        }

        // Vineyard filter
        if vineyardFilter != Self.allValue {
            result = result.filter { $0.vineyardNames.contains(vineyardFilter) }
        }

        // Role filter
        if roleFilter != Self.allValue {
            result = result.filter { $0.roles.contains(roleFilter) }
        }

        // Search
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            result = result.filter {
                $0.email.lowercased().contains(query)
                    || ($0.displayName?.lowercased().contains(query) ?? false)
            }
        }

        // Sort
        switch sortOrder {
        case .lastLoginNewest:
            result.sort { ($0.lastSignInAt ?? .distantPast) > ($1.lastSignInAt ?? .distantPast) }
        case .lastLoginOldest:
            result.sort { ($0.lastSignInAt ?? .distantFuture) < ($1.lastSignInAt ?? .distantFuture) }
        case .createdNewest:
            result.sort { ($0.accountCreatedAt ?? .distantPast) > ($1.accountCreatedAt ?? .distantPast) }
        case .nameAsc:
            result.sort { $0.bestName.lowercased() < $1.bestName.lowercased() }
        }

        return result
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let repo = SupabaseSystemAdminRepository()
            rows = try await repo.listUserLoginActivity()
        } catch {
            let raw = error.localizedDescription.lowercased()
            if raw.contains("system admin required") || raw.contains("42501") {
                loadError = "System admin required. Sign in as a system admin to continue."
            } else {
                loadError = error.localizedDescription
            }
        }
    }
}
