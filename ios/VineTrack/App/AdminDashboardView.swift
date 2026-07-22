import SwiftUI
import MapKit

private enum AdminUserFilter: Hashable {
    case active7
    case active30
    case new30
}

private enum AdminDestination: Identifiable, Hashable {
    case allUsers
    case usersFiltered(AdminUserFilter, String)
    case vineyards
    case blocks
    case invitations
    case pins
    case sprayRecords
    case workTasks
    case userDetail(AdminUserRow)
    case vineyardDetail(AdminVineyardRow)
    case paddockDetail(AdminVineyardPaddockRow)

    var id: String {
        switch self {
        case .allUsers: return "allUsers"
        case .usersFiltered(let f, _): return "usersFiltered-\(f)"
        case .vineyards: return "vineyards"
        case .blocks: return "blocks"
        case .invitations: return "invitations"
        case .pins: return "pins"
        case .sprayRecords: return "sprayRecords"
        case .workTasks: return "workTasks"
        case .userDetail(let u): return "user-\(u.id.uuidString)"
        case .vineyardDetail(let v): return "vineyard-\(v.id.uuidString)"
        case .paddockDetail(let p): return "paddock-\(p.id.uuidString)"
        }
    }
}

struct AdminDashboardView: View {
    @State private var summary: AdminEngagementSummary?
    @State private var users: [AdminUserRow] = []
    @State private var totalBlocks: Int?
    @State private var platformScale: AdminPlatformScale?
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var searchText: String = ""
    @State private var selectedDestination: AdminDestination?
    private let repository = SupabaseAdminRepository()

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }

            platformScaleSection
            engagementSection
            usersSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Admin")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search users")
        .refreshable { await loadAll() }
        .task { await loadAll() }
        .overlay {
            if isLoading && summary == nil {
                ProgressView()
            }
        }
        .navigationDestination(item: $selectedDestination) { destination in
            destinationView(for: destination)
        }
    }

    @ViewBuilder
    private func destinationView(for destination: AdminDestination) -> some View {
        switch destination {
        case .allUsers:
            AdminUsersListView(title: "All Users", users: users, onSelect: { user in
                selectedDestination = .userDetail(user)
            })
        case .usersFiltered(let filter, let title):
            AdminUsersListView(title: title, users: filtered(by: filter), onSelect: { user in
                selectedDestination = .userDetail(user)
            })
        case .vineyards:
            AdminVineyardsListView(onSelect: { v in
                selectedDestination = .vineyardDetail(v)
            })
        case .blocks:
            AdminAllBlocksListView(
                onSelectBlock: { paddock in selectedDestination = .paddockDetail(paddock) },
                onCountLoaded: { count in totalBlocks = count }
            )
        case .invitations:
            AdminInvitationsListView()
        case .pins:
            AdminPinsListView()
        case .sprayRecords:
            AdminSprayRecordsListView()
        case .workTasks:
            AdminWorkTasksListView()
        case .userDetail(let user):
            AdminUserDetailView(user: user, onSelectVineyard: { v in
                selectedDestination = .vineyardDetail(v)
            })
        case .vineyardDetail(let vineyard):
            AdminVineyardDetailView(vineyard: vineyard, onSelectPaddock: { p in
                selectedDestination = .paddockDetail(p)
            })
        case .paddockDetail(let paddock):
            AdminPaddockDetailView(paddock: paddock)
        }
    }

    /// Formats a hectare value: 1 decimal under 1,000 ha, comma-grouped above.
    private func formatHectares(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return (formatter.string(from: NSNumber(value: value)) ?? "0.0") + " ha"
    }

    private var platformScaleSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "globe.asia.australia.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(VineyardTheme.leafGreen.gradient, in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Total hectares under management")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(platformScale.map { formatHectares($0.totalHectaresUnderManagement) } ?? "—")
                            .font(.title.weight(.bold))
                            .foregroundStyle(.primary)
                            .contentTransition(.numericText())
                    }
                    Spacer()
                }
                Text("Across active vineyards and blocks")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let scale = platformScale {
                    Divider().padding(.vertical, 2)
                    HStack(spacing: 0) {
                        scaleStat("\(scale.totalVineyards)", "Vineyards")
                        Divider().frame(height: 28)
                        scaleStat("\(scale.totalActivePaddocks)", "Active blocks")
                        Divider().frame(height: 28)
                        scaleStat(formatHectares(scale.averageHectaresPerVineyard), "Avg / vineyard")
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Platform Scale")
        } footer: {
            Text("Internal reporting metric. Area is derived from active block map geometry.")
        }
    }

    @ViewBuilder
    private func scaleStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var engagementSection: some View {
        Section {
            if let summary {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    tile("Total Users", "\(summary.totalUsers)", "person.3.fill", .blue, value: .allUsers)
                    tile("Vineyards", "\(summary.totalVineyards)", "building.2.fill", VineyardTheme.leafGreen, value: .vineyards)
                    tile("Blocks", totalBlocks.map { "\($0)" } ?? "—", "square.grid.2x2.fill", .purple, value: .blocks)
                    tile("Active 7d", "\(summary.signedInLast7Days)", "bolt.fill", .orange, value: .usersFiltered(.active7, "Active in last 7 days"))
                    tile("Active 30d", "\(summary.signedInLast30Days)", "calendar", .indigo, value: .usersFiltered(.active30, "Active in last 30 days"))
                    tile("New 30d", "\(summary.newUsersLast30Days)", "person.fill.badge.plus", .pink, value: .usersFiltered(.new30, "New users (30d)"))
                    tile("Pending Invites", "\(summary.pendingInvitations)", "envelope.badge.fill", .red, value: .invitations)
                    tile("Pins", "\(summary.totalPins)", "mappin.and.ellipse", .teal, value: .pins)
                    tile("Spray Records", "\(summary.totalSprayRecords)", "drop.fill", .cyan, value: .sprayRecords)
                    tile("Work Tasks", "\(summary.totalWorkTasks)", "checkmark.circle.fill", .green, value: .workTasks)
                }
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            } else if !isLoading {
                Text("No engagement data available.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Engagement")
        } footer: {
            if summary != nil {
                Text("Tap any tile to see the underlying records. Active = signed in within the period.")
            }
        }
    }

    @ViewBuilder
    private func tile(_ title: String, _ value: String, _ symbol: String, _ color: Color, value destination: AdminDestination) -> some View {
        Button {
            selectedDestination = destination
        } label: {
            StatTile(title: title, value: value, symbol: symbol, color: color)
        }
        .buttonStyle(.plain)
    }

    private var filteredUsers: [AdminUserRow] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return users }
        return users.filter {
            $0.email.lowercased().contains(q) ||
            ($0.fullName?.lowercased().contains(q) ?? false)
        }
    }

    private func filtered(by filter: AdminUserFilter) -> [AdminUserRow] {
        let cal = Calendar.current
        let now = Date()
        switch filter {
        case .active7:
            let cutoff = cal.date(byAdding: .day, value: -7, to: now) ?? now
            return users.filter { ($0.lastSignInAt ?? .distantPast) >= cutoff }
        case .active30:
            let cutoff = cal.date(byAdding: .day, value: -30, to: now) ?? now
            return users.filter { ($0.lastSignInAt ?? .distantPast) >= cutoff }
        case .new30:
            let cutoff = cal.date(byAdding: .day, value: -30, to: now) ?? now
            return users.filter { ($0.createdAt ?? .distantPast) >= cutoff }
        }
    }

    private var usersSection: some View {
        Section {
            if filteredUsers.isEmpty && !isLoading {
                Text(users.isEmpty ? "No users found." : "No matches.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(filteredUsers) { user in
                Button {
                    selectedDestination = .userDetail(user)
                } label: {
                    AdminUserRowView(user: user)
                }
                .buttonStyle(.plain)
            }
        } header: {
            HStack {
                Text("Users")
                Spacer()
                if !users.isEmpty {
                    Text("\(filteredUsers.count) of \(users.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @MainActor
    private func loadAll() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let summaryTask = repository.fetchEngagementSummary()
            async let usersTask = repository.fetchAllUsers()
            let (s, u) = try await (summaryTask, usersTask)
            summary = s
            users = u
        } catch {
            errorMessage = error.localizedDescription
        }
        // Block count is loaded separately because it requires a per-vineyard
        // fan-out and shouldn't block the main dashboard from appearing.
        Task { await loadBlockCount() }
        Task { await loadPlatformScale() }
    }

    @MainActor
    private func loadPlatformScale() async {
        do {
            platformScale = try await repository.fetchPlatformScale()
        } catch {
            // Non-fatal; the hero card shows "—" if the RPC is unavailable.
        }
    }

    @MainActor
    private func loadBlockCount() async {
        do {
            totalBlocks = try await repository.fetchBlocksCount()
        } catch {
            // Fallback: try the per-vineyard fan-out so the tile still has a
            // chance to populate on older backends without `admin_blocks_count`.
            do {
                let rows = try await repository.fetchAllPaddocks()
                totalBlocks = rows.filter { $0.paddock.deletedAt == nil }.count
            } catch {
                // Non-fatal; leave totalBlocks nil so the tile shows "—"
            }
        }
    }
}

// MARK: - All Blocks (across vineyards)

private struct AdminAllBlocksListView: View {
    let onSelectBlock: (AdminVineyardPaddockRow) -> Void
    var onCountLoaded: ((Int) -> Void)? = nil

    @State private var rows: [(vineyard: AdminVineyardRow, paddock: AdminVineyardPaddockRow)] = []
    @State private var isLoading: Bool = false
    @State private var loadError: String?
    @State private var query: String = ""
    @State private var showArchived: Bool = false

    private let repository = SupabaseAdminRepository()

    private var filtered: [(AdminVineyardRow, AdminVineyardPaddockRow)] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.filter { item in
            if !showArchived && item.paddock.deletedAt != nil { return false }
            guard !q.isEmpty else { return true }
            return item.paddock.name.lowercased().contains(q) ||
                   item.vineyard.name.lowercased().contains(q)
        }
    }

    private var activeCount: Int {
        rows.filter { $0.paddock.deletedAt == nil }.count
    }

    private var grouped: [(vineyard: AdminVineyardRow, blocks: [AdminVineyardPaddockRow])] {
        var dict: [UUID: (AdminVineyardRow, [AdminVineyardPaddockRow])] = [:]
        for item in filtered {
            if var existing = dict[item.0.id] {
                existing.1.append(item.1)
                dict[item.0.id] = existing
            } else {
                dict[item.0.id] = (item.0, [item.1])
            }
        }
        return dict.values
            .map { (vineyard: $0.0, blocks: $0.1.sorted { $0.name.lowercased() < $1.name.lowercased() }) }
            .sorted { $0.vineyard.name.lowercased() < $1.vineyard.name.lowercased() }
    }

    var body: some View {
        List {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.footnote)
                }
            }

            Section {
                Toggle("Show archived", isOn: $showArchived)
            } footer: {
                Text("\(activeCount) active block\(activeCount == 1 ? "" : "s") across \(Set(rows.filter { $0.paddock.deletedAt == nil }.map { $0.vineyard.id }).count) vineyard\(Set(rows.filter { $0.paddock.deletedAt == nil }.map { $0.vineyard.id }).count == 1 ? "" : "s").")
            }

            if grouped.isEmpty && !isLoading {
                Section {
                    Text(rows.isEmpty ? "No blocks found." : "No matches.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            ForEach(grouped, id: \.vineyard.id) { group in
                Section {
                    ForEach(group.blocks) { p in
                        Button {
                            onSelectBlock(p)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: p.polygonPoints.count >= 3 ? "map.fill" : "square.grid.2x2")
                                    .foregroundStyle(p.polygonPoints.count >= 3 ? Color.green : Color.secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(p.name)
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)
                                        if p.deletedAt != nil {
                                            Text("ARCHIVED")
                                                .font(.caption2.weight(.bold))
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(Color.secondary.opacity(0.15), in: Capsule())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Text("\(p.rowCount) row\(p.rowCount == 1 ? "" : "s")\(p.polygonPoints.count >= 3 ? "" : " • no map")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text(group.vineyard.name)
                        Spacer()
                        Text("\(group.blocks.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Blocks")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search blocks or vineyards")
        .overlay { if isLoading && rows.isEmpty { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
    }

    @MainActor
    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let fetched = try await repository.fetchAllPaddocks()
            rows = fetched
            onCountLoaded?(fetched.filter { $0.paddock.deletedAt == nil }.count)
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Tile

private struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: 7))
            }
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - User Row

private struct AdminUserRowView: View {
    let user: AdminUserRow

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.blue.gradient)
                    .frame(width: 36, height: 36)
                Text(initials)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(user.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    if user.vineyardCount > 0 {
                        Label("\(user.vineyardCount)", systemImage: "building.2.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(VineyardTheme.leafGreen)
                    }
                    if user.blockCount > 0 {
                        Label("\(user.blockCount)", systemImage: "square.grid.2x2.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.purple)
                    }
                }
                if let last = user.lastSignInAt {
                    Text(last, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if let created = user.createdAt {
                    Text(created, format: .dateTime.month(.abbreviated).day().year())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var initials: String {
        let source = user.fullName?.isEmpty == false ? user.fullName! : user.email
        let parts = source.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map { String($0) }.joined()
        return letters.isEmpty ? String(source.prefix(1)).uppercased() : letters.uppercased()
    }
}

// MARK: - Users list

private struct AdminUsersListView: View {
    let title: String
    let users: [AdminUserRow]
    let onSelect: (AdminUserRow) -> Void
    @State private var query: String = ""

    private var filtered: [AdminUserRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return users }
        return users.filter {
            $0.email.lowercased().contains(q) ||
            ($0.fullName?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        List {
            Section {
                if filtered.isEmpty {
                    Text("No users.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(filtered) { user in
                    Button {
                        onSelect(user)
                    } label: {
                        AdminUserRowView(user: user)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("\(filtered.count) of \(users.count)")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search")
    }
}

// MARK: - User detail

private struct AdminUserDetailView: View {
    let user: AdminUserRow
    var onSelectVineyard: ((AdminVineyardRow) -> Void)? = nil
    @Environment(\.openURL) private var openURL
    @State private var vineyards: [AdminUserVineyardRow] = []
    @State private var isLoading: Bool = false
    @State private var loadError: String?

    private let repository = SupabaseAdminRepository()

    var body: some View {
        Form {
            Section {
                LabeledContent("Name", value: user.fullName ?? "—")
                LabeledContent("Email", value: user.email)
                LabeledContent("Vineyards", value: "\(user.vineyardCount)")
                LabeledContent("Owned", value: "\(user.ownedCount)")
                LabeledContent("Blocks", value: "\(user.blockCount)")
                if let created = user.createdAt {
                    LabeledContent("Joined") {
                        Text(created, format: .dateTime.month(.abbreviated).day().year())
                    }
                }
                if let last = user.lastSignInAt {
                    LabeledContent("Last Sign-In") {
                        Text(last, format: .relative(presentation: .named))
                    }
                } else if let updated = user.updatedAt {
                    LabeledContent("Last Active") {
                        Text(updated, format: .relative(presentation: .named))
                    }
                }
            } header: {
                Text("Profile")
            }

            Section {
                if isLoading && vineyards.isEmpty {
                    HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                } else if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                } else if vineyards.isEmpty {
                    Text("No vineyards.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(vineyards) { v in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(v.name).font(.subheadline.weight(.semibold))
                                if v.isOwner {
                                    Text("OWNER")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(VineyardTheme.leafGreen.opacity(0.15), in: Capsule())
                                        .foregroundStyle(VineyardTheme.leafGreen)
                                } else if let role = v.role {
                                    Text(role.uppercased())
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.12), in: Capsule())
                                        .foregroundStyle(.blue)
                                }
                                Spacer()
                                if v.deletedAt != nil {
                                    Text("ARCHIVED")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 12) {
                                Label("\(v.memberCount)", systemImage: "person.2.fill")
                                if let c = v.country, !c.isEmpty { Text(c) }
                                if let d = v.createdAt {
                                    Text(d, format: .dateTime.month(.abbreviated).day().year())
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Vineyards (\(vineyards.count))")
            }

            Section {
                Button {
                    sendEmail(subject: "VineTrack Support", body: "Hi \(user.fullName ?? ""),\n\n")
                } label: {
                    Label("Email Support Reply", systemImage: "envelope.fill")
                }
                Button {
                    sendEmail(subject: "VineTrack — Welcome & Onboarding", body: "Hi \(user.fullName ?? ""),\n\nWelcome to VineTrack! ")
                } label: {
                    Label("Send Welcome Email", systemImage: "hand.wave.fill")
                }
                Button {
                    UIPasteboard.general.string = user.email
                } label: {
                    Label("Copy Email Address", systemImage: "doc.on.doc")
                }
                Button {
                    UIPasteboard.general.string = user.id.uuidString
                } label: {
                    Label("Copy User ID", systemImage: "number")
                }
            } header: {
                Text("Support Actions")
            }

            Section {
                Text(user.id.uuidString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } header: {
                Text("User ID")
            }
        }
        .navigationTitle(user.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadVineyards() }
        .refreshable { await loadVineyards() }
    }

    @MainActor
    private func loadVineyards() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            vineyards = try await repository.fetchUserVineyards(userId: user.id)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func sendEmail(subject: String, body: String) {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = user.email
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        if let url = components.url {
            openURL(url)
        }
    }
}

// MARK: - Vineyards list

private struct AdminVineyardsListView: View {
    let onSelect: (AdminVineyardRow) -> Void
    @State private var vineyards: [AdminVineyardRow] = []
    @State private var isLoading: Bool = false
    @State private var loadError: String?
    @State private var query: String = ""

    private let repository = SupabaseAdminRepository()

    private var filtered: [AdminVineyardRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return vineyards }
        return vineyards.filter {
            $0.name.lowercased().contains(q) ||
            ($0.ownerEmail?.lowercased().contains(q) ?? false) ||
            ($0.ownerFullName?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        List {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.footnote)
                }
            }
            Section {
                if filtered.isEmpty && !isLoading {
                    Text("No vineyards.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(filtered) { v in
                    Button {
                        onSelect(v)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(v.name).font(.subheadline.weight(.semibold))
                                Spacer()
                                if v.deletedAt != nil {
                                    Text("ARCHIVED").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                                }
                            }
                            Text(v.ownerDisplay).font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                Label("\(v.memberCount)", systemImage: "person.2.fill")
                                if v.pendingInvites > 0 {
                                    Label("\(v.pendingInvites)", systemImage: "envelope.badge.fill")
                                        .foregroundStyle(.orange)
                                }
                                if let d = v.createdAt {
                                    Text(d, format: .dateTime.month(.abbreviated).day().year())
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("\(filtered.count) of \(vineyards.count)")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Vineyards")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search vineyards or owners")
        .overlay { if isLoading && vineyards.isEmpty { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
    }

    @MainActor
    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            vineyards = try await repository.fetchAllVineyards()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct AdminVineyardDetailView: View {
    let vineyard: AdminVineyardRow
    var onSelectPaddock: ((AdminVineyardPaddockRow) -> Void)? = nil

    @State private var paddocks: [AdminVineyardPaddockRow] = []
    @State private var isLoadingPaddocks: Bool = false
    @State private var paddockError: String?
    private let repository = SupabaseAdminRepository()

    private var mappablePaddocks: [AdminVineyardPaddockRow] {
        paddocks.filter { $0.deletedAt == nil && $0.polygonPoints.count >= 3 }
    }

    var body: some View {
        Form {
            Section("Vineyard Map") {
                AdminVineyardMapSection(
                    paddocks: mappablePaddocks,
                    isLoading: isLoadingPaddocks,
                    errorMessage: paddockError,
                    totalPaddocks: paddocks.count
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section("Vineyard") {
                LabeledContent("Name", value: vineyard.name)
                LabeledContent("Owner", value: vineyard.ownerDisplay)
                if let email = vineyard.ownerEmail { LabeledContent("Owner Email", value: email) }
                if let c = vineyard.country, !c.isEmpty { LabeledContent("Country", value: c) }
                LabeledContent("Members", value: "\(vineyard.memberCount)")
                LabeledContent("Pending Invites", value: "\(vineyard.pendingInvites)")
                LabeledContent("Blocks", value: "\(paddocks.count)")
                if let d = vineyard.createdAt {
                    LabeledContent("Created") { Text(d, format: .dateTime.month(.abbreviated).day().year()) }
                }
                if vineyard.deletedAt != nil {
                    LabeledContent("Status", value: "Archived")
                }
            }

            if !paddocks.isEmpty {
                Section("Blocks") {
                    ForEach(paddocks) { p in
                        Button {
                            onSelectPaddock?(p)
                        } label: {
                            HStack {
                                Image(systemName: p.polygonPoints.count >= 3 ? "map.fill" : "map")
                                    .foregroundStyle(p.polygonPoints.count >= 3 ? Color.green : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).font(.subheadline.weight(.medium))
                                    Text("\(p.rowCount) rows\(p.polygonPoints.count >= 3 ? "" : " • no map")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if p.deletedAt != nil {
                                    Text("Archived").font(.caption2).foregroundStyle(.orange)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Vineyard ID") {
                Text(vineyard.id.uuidString).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(vineyard.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: vineyard.id) {
            await loadPaddocks()
        }
        .refreshable {
            await loadPaddocks()
        }
    }

    private func loadPaddocks() async {
        isLoadingPaddocks = true
        paddockError = nil
        do {
            paddocks = try await repository.fetchVineyardPaddocks(vineyardId: vineyard.id)
        } catch {
            paddockError = error.localizedDescription
        }
        isLoadingPaddocks = false
    }
}

private struct AdminVineyardMapSection: View {
    let paddocks: [AdminVineyardPaddockRow]
    let isLoading: Bool
    let errorMessage: String?
    let totalPaddocks: Int

    @State private var position: MapCameraPosition = .automatic
    @State private var hasSetInitialPosition: Bool = false
    @State private var displayMode: MapDisplayMode = .topDown

    private enum MapDisplayMode: String, CaseIterable {
        case topDown = "Top-down"
        case overview3D = "3D Overview"
    }

    /// Pitch used for the 3D Overview camera (degrees).
    private let overviewPitch: CGFloat = 50

    private var paddockIDs: [UUID] { paddocks.map(\.id) }

    private func regionForContent() -> MKCoordinateRegion? {
        var lats: [Double] = []
        var lons: [Double] = []
        for p in paddocks {
            for pt in p.polygonPoints {
                lats.append(pt.latitude)
                lons.append(pt.longitude)
            }
        }
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return nil }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.5, 0.002),
            longitudeDelta: max((maxLon - minLon) * 1.5, 0.002)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    /// Derives a tilted MapKit camera from the current content region so the 3D
    /// Overview keeps a similar centre and zoom feel to the top-down view.
    private func overviewCamera(from region: MKCoordinateRegion) -> MapCamera {
        // Approximate the region's north-south extent in metres, then scale it
        // into a camera distance that frames roughly the same area while tilted.
        let metresPerDegreeLat = 111_000.0
        let extentMetres = region.span.latitudeDelta * metresPerDegreeLat
        let distance = max(extentMetres * 1.6, 300)
        return MapCamera(
            centerCoordinate: region.center,
            distance: distance,
            heading: 0,
            pitch: overviewPitch
        )
    }

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
                .frame(height: 280)
                .overlay {
                    if !paddocks.isEmpty {
                        Map(position: $position) {
                            ForEach(paddocks) { p in
                                MapPolygon(coordinates: p.polygonPoints.map { $0.coordinate })
                                    .foregroundStyle(Color.green.opacity(0.18))
                                    .stroke(Color.green, lineWidth: 2)
                                Annotation("", coordinate: p.polygonPoints.centroid) {
                                    Text(p.name)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.green.opacity(0.85), in: .rect(cornerRadius: 6))
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                        .mapStyle(.hybrid)
                        .allowsHitTesting(true)
                        .overlay(alignment: .topTrailing) {
                            Picker("Map view", selection: $displayMode) {
                                ForEach(MapDisplayMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .fixedSize()
                            .padding(6)
                            .background(.ultraThinMaterial, in: .rect(cornerRadius: 8))
                            .padding(8)
                        }
                    } else {
                        VStack(spacing: 8) {
                            if isLoading {
                                ProgressView()
                                Text("Loading map…").font(.caption).foregroundStyle(.secondary)
                            } else if let errorMessage {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.title2)
                                    .foregroundStyle(.orange)
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                            } else {
                                Image(systemName: "map")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                                Text(totalPaddocks == 0 ? "No blocks have been created for this vineyard." : "No blocks have map geometry yet.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                            }
                        }
                    }
                }
        }
        .frame(height: 280)
        .clipShape(.rect(cornerRadius: 12))
        .onAppear { applyInitialRegionIfNeeded() }
        .onChange(of: paddockIDs) { _, _ in
            hasSetInitialPosition = false
            applyInitialRegionIfNeeded()
        }
        .onChange(of: displayMode) { _, _ in
            applyDisplayMode()
        }
    }

    private func applyInitialRegionIfNeeded() {
        guard !hasSetInitialPosition, let region = regionForContent() else { return }
        position = .region(region)
        hasSetInitialPosition = true
    }

    /// Switches the camera between flat top-down and tilted 3D Overview while
    /// keeping the same content centre and a comparable zoom level.
    private func applyDisplayMode() {
        guard let region = regionForContent() else { return }
        withAnimation(.easeInOut(duration: 0.4)) {
            switch displayMode {
            case .topDown:
                position = .region(region)
            case .overview3D:
                position = .camera(overviewCamera(from: region))
            }
        }
    }
}

// MARK: - Invitations

private struct AdminInvitationsListView: View {
    @State private var rows: [AdminInvitationRow] = []
    @State private var isLoading: Bool = false
    @State private var loadError: String?

    private let repository = SupabaseAdminRepository()

    var body: some View {
        List {
            if let loadError {
                Section { Label(loadError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.footnote) }
            }
            Section {
                if rows.isEmpty && !isLoading {
                    Text("No invitations.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(rows) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(r.email).font(.subheadline.weight(.semibold))
                            Spacer()
                            statusBadge(r.status)
                        }
                        HStack(spacing: 8) {
                            Text(r.role.capitalized).font(.caption.weight(.medium))
                            if let v = r.vineyardName { Text("• \(v)").font(.caption).foregroundStyle(.secondary) }
                        }
                        if let d = r.createdAt {
                            Text(d, format: .dateTime.month(.abbreviated).day().year())
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Text("\(rows.count) invitations")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Invitations")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if isLoading && rows.isEmpty { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func statusBadge(_ status: String) -> some View {
        let color: Color = {
            switch status.lowercased() {
            case "pending": return .orange
            case "accepted": return .green
            case "declined", "expired", "cancelled": return .gray
            default: return .blue
            }
        }()
        Text(status.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    @MainActor
    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do { rows = try await repository.fetchInvitations() }
        catch { loadError = error.localizedDescription }
    }
}

// MARK: - Pins

private struct AdminPinsListView: View {
    @State private var rows: [AdminPinRow] = []
    @State private var isLoading: Bool = false
    @State private var loadError: String?

    private let repository = SupabaseAdminRepository()

    var body: some View {
        List {
            if let loadError {
                Section { Label(loadError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.footnote) }
            }
            Section {
                if rows.isEmpty && !isLoading {
                    Text("No pins.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(rows) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(r.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer()
                            if r.isCompleted {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                        HStack(spacing: 8) {
                            if let v = r.vineyardName { Text(v).font(.caption).foregroundStyle(.secondary) }
                            if let c = r.category { Text("• \(c)").font(.caption).foregroundStyle(.secondary) }
                        }
                        if let d = r.createdAt {
                            Text(d, format: .dateTime.month(.abbreviated).day().year())
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Text("\(rows.count) pins")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Pins")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if isLoading && rows.isEmpty { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
    }

    @MainActor
    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do { rows = try await repository.fetchPins() }
        catch { loadError = error.localizedDescription }
    }
}

// MARK: - Spray Records

private struct AdminSprayRecordsListView: View {
    @State private var rows: [AdminSprayRow] = []
    @State private var isLoading: Bool = false
    @State private var loadError: String?

    private let repository = SupabaseAdminRepository()

    var body: some View {
        List {
            if let loadError {
                Section { Label(loadError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.footnote) }
            }
            Section {
                if rows.isEmpty && !isLoading {
                    Text("No spray records.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(rows) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(r.sprayReference?.isEmpty == false ? r.sprayReference! : (r.operationType ?? "Spray"))
                                .font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer()
                            if let op = r.operationType { Text(op).font(.caption2).foregroundStyle(.secondary) }
                        }
                        if let v = r.vineyardName { Text(v).font(.caption).foregroundStyle(.secondary) }
                        if let d = r.date ?? r.createdAt {
                            Text(d, format: .dateTime.month(.abbreviated).day().year())
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Text("\(rows.count) spray records")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Spray Records")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if isLoading && rows.isEmpty { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
    }

    @MainActor
    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do { rows = try await repository.fetchSprayRecords() }
        catch { loadError = error.localizedDescription }
    }
}

// MARK: - Work Tasks

private struct AdminWorkTasksListView: View {
    @State private var rows: [AdminWorkTaskRow] = []
    @State private var isLoading: Bool = false
    @State private var loadError: String?

    private let repository = SupabaseAdminRepository()

    var body: some View {
        List {
            if let loadError {
                Section { Label(loadError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.footnote) }
            }
            Section {
                if rows.isEmpty && !isLoading {
                    Text("No work tasks.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(rows) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(r.taskType?.isEmpty == false ? r.taskType! : "Task")
                                .font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer()
                            if let h = r.durationHours, h > 0 {
                                Text(String(format: "%.1fh", h)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 8) {
                            if let v = r.vineyardName { Text(v).font(.caption).foregroundStyle(.secondary) }
                            if let p = r.paddockName, !p.isEmpty { Text("• \(p)").font(.caption).foregroundStyle(.secondary) }
                        }
                        if let d = r.date ?? r.createdAt {
                            Text(d, format: .dateTime.month(.abbreviated).day().year())
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Text("\(rows.count) work tasks")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Work Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if isLoading && rows.isEmpty { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
    }

    @MainActor
    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do { rows = try await repository.fetchWorkTasks() }
        catch { loadError = error.localizedDescription }
    }
}

// MARK: - Paddock detail (admin)

private struct AdminPaddockDetailView: View {
    let paddock: AdminVineyardPaddockRow

    @State private var position: MapCameraPosition = .automatic
    @State private var showRowNumbers: Bool = true
    @State private var hasSetInitialPosition: Bool = false

    private var sortedRows: [PaddockRow] {
        paddock.rows.sorted { $0.number < $1.number }
    }

    private var hasGeometry: Bool {
        paddock.polygonPoints.count >= 3 || !paddock.rows.isEmpty
    }

    private func regionForContent() -> MKCoordinateRegion? {
        var lats: [Double] = []
        var lons: [Double] = []
        for pt in paddock.polygonPoints {
            lats.append(pt.latitude); lons.append(pt.longitude)
        }
        for row in paddock.rows {
            lats.append(row.startPoint.latitude); lons.append(row.startPoint.longitude)
            lats.append(row.endPoint.latitude);   lons.append(row.endPoint.longitude)
        }
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return nil }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.0008),
            longitudeDelta: max((maxLon - minLon) * 1.4, 0.0008)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    var body: some View {
        Form {
            Section("Map") {
                ZStack {
                    Color(.secondarySystemBackground)
                        .frame(height: 320)
                        .overlay {
                            if hasGeometry {
                                Map(position: $position) {
                                    if paddock.polygonPoints.count >= 3 {
                                        MapPolygon(coordinates: paddock.polygonPoints.map(\.coordinate))
                                            .foregroundStyle(Color.green.opacity(0.15))
                                            .stroke(Color.green, lineWidth: 2)
                                    }
                                    ForEach(sortedRows) { row in
                                        MapPolyline(coordinates: [row.startPoint.coordinate, row.endPoint.coordinate])
                                            .stroke(Color.yellow, lineWidth: 2)
                                        if showRowNumbers {
                                            Annotation("", coordinate: row.startPoint.coordinate) {
                                                Text("\(row.number)")
                                                    .font(.caption2.weight(.bold))
                                                    .foregroundStyle(.black)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background(Color.yellow.opacity(0.95), in: Capsule())
                                                    .allowsHitTesting(false)
                                            }
                                        }
                                    }
                                }
                                .mapStyle(.hybrid)
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "map")
                                        .font(.title2)
                                        .foregroundStyle(.secondary)
                                    Text("No polygon or row geometry available for this paddock.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal)
                                }
                            }
                        }
                }
                .frame(height: 320)
                .clipShape(.rect(cornerRadius: 12))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                Toggle("Show row numbers", isOn: $showRowNumbers)
            }

            Section("Block") {
                LabeledContent("Name", value: paddock.name)
                LabeledContent("Polygon points", value: "\(paddock.polygonPoints.count)")
                LabeledContent("Rows", value: "\(paddock.rowCount)")
                if let dir = paddock.rowDirection {
                    LabeledContent("Row direction", value: String(format: "%.1f°", dir))
                }
                if let w = paddock.rowWidth {
                    LabeledContent("Row width", value: String(format: "%.2f m", w))
                }
                if let s = paddock.vineSpacing {
                    LabeledContent("Vine spacing", value: String(format: "%.2f m", s))
                }
                if let d = paddock.createdAt {
                    LabeledContent("Created") { Text(d, format: .dateTime.month(.abbreviated).day().year()) }
                }
                if let d = paddock.updatedAt {
                    LabeledContent("Updated") { Text(d, format: .dateTime.month(.abbreviated).day().year().hour().minute()) }
                }
                if paddock.deletedAt != nil {
                    LabeledContent("Status", value: "Archived")
                }
            }

            Section("Rows (\(sortedRows.count))") {
                if sortedRows.isEmpty {
                    Text("No rows have been recorded for this block.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedRows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Row \(row.number)")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(String(format: "%.1f m", rowLength(row)))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Text("Start  \(coordString(row.startPoint))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text("End    \(coordString(row.endPoint))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Block ID") {
                Text(paddock.id.uuidString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(paddock.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { applyInitialRegionIfNeeded() }
    }

    private func applyInitialRegionIfNeeded() {
        guard !hasSetInitialPosition, let region = regionForContent() else { return }
        position = .region(region)
        hasSetInitialPosition = true
    }

    private func coordString(_ p: CoordinatePoint) -> String {
        String(format: "%.6f, %.6f", p.latitude, p.longitude)
    }

    private func rowLength(_ row: PaddockRow) -> Double {
        let a = CLLocation(latitude: row.startPoint.latitude, longitude: row.startPoint.longitude)
        let b = CLLocation(latitude: row.endPoint.latitude, longitude: row.endPoint.longitude)
        return a.distance(from: b)
    }
}
