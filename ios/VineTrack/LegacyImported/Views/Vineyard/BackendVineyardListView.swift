import SwiftUI

/// Phase 6A backend-aware vineyard list. Uses `SupabaseVineyardRepository` to list
/// and create vineyards on the new backend, then mirrors the result into
/// `MigratedDataStore` so the rest of the (still-local) legacy app can use them.
struct BackendVineyardListView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth

    private let vineyardRepository: any VineyardRepositoryProtocol
    private let teamRepository: any TeamRepositoryProtocol
    private let logoStorage: VineyardLogoStorageService

    @State private var showAddVineyard: Bool = false
    @State private var isRefreshing: Bool = false
    @State private var errorMessage: String?
    @State private var vineyardPendingDeletion: Vineyard?
    @State private var rolesByVineyardId: [UUID: BackendRole] = [:]
    @State private var isLoadingRoles: Bool = false
    @State private var refreshStatus: String?
    @State private var processingInvitationId: UUID?
    @State private var showWaitingForInvite: Bool = false

    init(
        vineyardRepository: any VineyardRepositoryProtocol = SupabaseVineyardRepository(),
        teamRepository: any TeamRepositoryProtocol = SupabaseTeamRepository(),
        logoStorage: VineyardLogoStorageService = VineyardLogoStorageService()
    ) {
        self.vineyardRepository = vineyardRepository
        self.teamRepository = teamRepository
        self.logoStorage = logoStorage
    }

    private var visiblePendingInvitations: [BackendInvitation] {
        let userEmail = (auth.userEmail ?? "").lowercased()
        let memberIds = Set(store.vineyards.map { $0.id })
        var seenVineyards = Set<UUID>()
        return auth.pendingInvitations
            .filter { $0.status.lowercased() == "pending" }
            .filter { userEmail.isEmpty || $0.email.lowercased() == userEmail }
            .filter { !memberIds.contains($0.vineyardId) }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            .filter { seenVineyards.insert($0.vineyardId).inserted }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.vineyards.isEmpty && visiblePendingInvitations.isEmpty {
                    emptyState
                } else {
                    vineyardList
                }
            }
            .navigationTitle("Vineyards")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        if isRefreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddVineyard = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .refreshable { await refresh() }
            .sheet(isPresented: $showAddVineyard) {
                EditVineyardSheet(vineyard: nil, vineyardRepository: vineyardRepository)
            }
            .navigationDestination(isPresented: $showWaitingForInvite) {
                WaitingForInviteView(
                    onCheckForInvites: { await refresh() },
                    onCreateVineyard: { showAddVineyard = true }
                )
            }
            .task { await refresh() }
            .alert("Vineyards", isPresented: errorBinding, presenting: errorMessage) { _ in
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { message in
                Text(message)
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func refresh() async {
        isRefreshing = true
        refreshStatus = nil
        defer { isRefreshing = false }
        do {
            let backendVineyards = try await vineyardRepository.listMyVineyards()
            store.mapBackendVineyardsIntoLocal(backendVineyards)
            await auth.loadPendingInvitations()
            await fetchMissingLogos()
            await fetchRoles()
            let count = visiblePendingInvitations.count
            refreshStatus = count > 0
                ? "\(count) pending invitation\(count == 1 ? "" : "s")"
                : "No pending invitations"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func accept(_ invitation: BackendInvitation) async {
        processingInvitationId = invitation.id
        defer { processingInvitationId = nil }
        await auth.acceptInvitation(invitation)
        do {
            let backendVineyards = try await vineyardRepository.listMyVineyards()
            store.mapBackendVineyardsIntoLocal(backendVineyards)
            if let newVineyard = backendVineyards.first(where: { $0.id == invitation.vineyardId }),
               let local = store.vineyards.first(where: { $0.id == newVineyard.id }) {
                store.selectVineyard(local)
                if auth.defaultVineyardId == nil {
                    _ = await auth.setDefaultVineyard(local.id)
                }
            }
            await auth.loadPendingInvitations()
            await fetchMissingLogos()
            await fetchRoles()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func decline(_ invitation: BackendInvitation) async {
        processingInvitationId = invitation.id
        defer { processingInvitationId = nil }
        await auth.declineInvitation(invitation)
        await auth.loadPendingInvitations()
    }

    private func fetchRoles() async {
        guard let userId = auth.userId else { return }
        isLoadingRoles = true
        defer { isLoadingRoles = false }
        var updated: [UUID: BackendRole] = [:]
        await withTaskGroup(of: (UUID, BackendRole?).self) { group in
            for vineyard in store.vineyards {
                let vineyardId = vineyard.id
                let repo = teamRepository
                group.addTask {
                    do {
                        let members = try await repo.listMembers(vineyardId: vineyardId)
                        return (vineyardId, members.first { $0.userId == userId }?.role)
                    } catch {
                        return (vineyardId, nil)
                    }
                }
            }
            for await (id, role) in group {
                if let role { updated[id] = role }
            }
        }
        rolesByVineyardId = updated
    }

    private func fetchMissingLogos() async {
        for vineyard in store.vineyards {
            guard let path = vineyard.logoPath else { continue }
            let key = SharedImageCacheKey.vineyardLogo(vineyardId: vineyard.id)

            // First hydrate any in-memory `logoData` from disk cache so the UI
            // can show the existing image immediately.
            if vineyard.logoData == nil,
               let cached = SharedImageCache.shared.cachedImageData(for: key),
               var current = store.vineyards.first(where: { $0.id == vineyard.id }) {
                current.logoData = cached
                store.upsertLocalVineyard(current)
            }

            // Then only download if the cache is missing or known stale.
            let isCurrent = SharedImageCache.shared.isCacheCurrent(
                for: key,
                remotePath: path,
                remoteUpdatedAt: vineyard.logoUpdatedAt
            )
            let hasCachedBytes = SharedImageCache.shared.cachedImageData(for: key) != nil
            if isCurrent && hasCachedBytes { continue }

            do {
                let data = try await logoStorage.downloadLogo(
                    path: path,
                    vineyardId: vineyard.id,
                    remoteUpdatedAt: vineyard.logoUpdatedAt
                )
                if var current = store.vineyards.first(where: { $0.id == vineyard.id }) {
                    current.logoData = data
                    store.upsertLocalVineyard(current)
                }
            } catch {
                #if DEBUG
                print("[VineyardLogo] download failed for \(vineyard.name):", error.localizedDescription)
                #endif
                // Keep showing whatever was in cache; do not clear local logoData.
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle()
                    .fill(VineyardTheme.primaryAccent.opacity(0.12))
                    .frame(width: 96, height: 96)
                GrapeLeafIcon(size: 48, color: VineyardTheme.primaryAccent)
            }
            VStack(spacing: 12) {
                brandedText("Welcome to VineTrack")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(VineyardTheme.textPrimary)
                Text("You don\u{2019}t currently have access to any vineyards. You can create a vineyard if you are an owner or manager, or wait for an invite if you are joining an existing team.")
                    .font(.subheadline)
                    .foregroundStyle(VineyardTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            VStack(spacing: 12) {
                Button {
                    showAddVineyard = true
                } label: {
                    Label("Create a Vineyard", systemImage: "plus")
                }
                .buttonStyle(.vineyardPrimary)

                Button {
                    showWaitingForInvite = true
                } label: {
                    Label("I\u{2019}m waiting for an invite", systemImage: "envelope")
                }
                .buttonStyle(.vineyardSecondary)
            }
            .padding(.horizontal, 32)
            .padding(.top, 4)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(VineyardTheme.destructive)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(VineyardTheme.appBackground)
    }

    private var vineyardList: some View {
        List {
            if !visiblePendingInvitations.isEmpty {
                Section {
                    ForEach(visiblePendingInvitations, id: \.id) { invitation in
                        invitationRow(invitation)
                    }
                } header: {
                    Text("Pending Invitations")
                } footer: {
                    Text("You've been invited to join these vineyards. Accept to add them to your list.")
                        .font(.caption)
                }
            }

            Section {
                if store.vineyards.isEmpty {
                    Text("No vineyards yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.vineyards) { vineyard in
                        BackendVineyardCardRow(
                            vineyard: vineyard,
                            isSelected: vineyard.id == store.selectedVineyardId,
                            isDefault: vineyard.id == auth.defaultVineyardId,
                            role: rolesByVineyardId[vineyard.id],
                            isLoadingRole: isLoadingRoles && rolesByVineyardId[vineyard.id] == nil,
                            vineyardRepository: vineyardRepository,
                            onMakeDefault: { Task { await auth.setDefaultVineyard(vineyard.id) } },
                            onClearDefault: { Task { await auth.setDefaultVineyard(nil) } }
                        )
                    }
                }
            } header: {
                HStack {
                    Text("My Vineyards")
                    Spacer()
                    if let refreshStatus, !isRefreshing {
                        Text(refreshStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func invitationRow(_ invitation: BackendInvitation) -> some View {
        let isProcessing = processingInvitationId == invitation.id
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(VineyardTheme.leafGreen.gradient)
                        .frame(width: 36, height: 36)
                    Image(systemName: "envelope.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(invitation.vineyardName ?? "Vineyard invitation")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("Invited as \(invitation.email)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            HStack(spacing: 6) {
                Text(invitation.role.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VineyardTheme.leafGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(VineyardTheme.leafGreen.opacity(0.12), in: Capsule())
                if let createdAt = invitation.createdAt {
                    Text(createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Button {
                    Task { await accept(invitation) }
                } label: {
                    HStack(spacing: 6) {
                        if isProcessing {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        Text("Accept")
                    }
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(VineyardTheme.leafGreen, in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(isProcessing)

                Button {
                    Task { await decline(invitation) }
                } label: {
                    Text("Decline")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .disabled(isProcessing)
            }
        }
        .padding(.vertical, 4)
    }
}

struct BackendVineyardCardRow: View {
    let vineyard: Vineyard
    let isSelected: Bool
    let isDefault: Bool
    let role: BackendRole?
    let isLoadingRole: Bool
    let vineyardRepository: any VineyardRepositoryProtocol
    let onMakeDefault: () -> Void
    let onClearDefault: () -> Void
    @Environment(MigratedDataStore.self) private var store
    @State private var showDetail: Bool = false

    var body: some View {
        Button {
            store.selectVineyard(vineyard)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? VineyardTheme.leafGreen.gradient : Color(.tertiarySystemFill).gradient)
                        .frame(width: 44, height: 44)

                    GrapeLeafIcon(size: 22)
                        .foregroundStyle(isSelected ? .white : VineyardTheme.leafGreen)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(vineyard.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if isDefault {
                            Label("Default", systemImage: "star.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                        }
                    }

                    HStack(spacing: 8) {
                        if !vineyard.country.isEmpty {
                            Label(vineyard.country, systemImage: "globe")
                        }
                        if isSelected {
                            Text("Active")
                                .fontWeight(.medium)
                                .foregroundStyle(VineyardTheme.leafGreen)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    roleBadge
                }

                Spacer()

                Button {
                    showDetail = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showDetail) {
            BackendVineyardDetailSheet(vineyard: vineyard, vineyardRepository: vineyardRepository)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if isDefault {
                Button {
                    onClearDefault()
                } label: {
                    Label("Clear Default", systemImage: "star.slash")
                }
                .tint(.gray)
            } else {
                Button {
                    onMakeDefault()
                } label: {
                    Label("Make Default", systemImage: "star.fill")
                }
                .tint(.orange)
            }
        }
        .contextMenu {
            if isDefault {
                Button {
                    onClearDefault()
                } label: {
                    Label("Clear Default", systemImage: "star.slash")
                }
            } else {
                Button {
                    onMakeDefault()
                } label: {
                    Label("Make Default", systemImage: "star.fill")
                }
            }
        }
    }

    @ViewBuilder
    private var roleBadge: some View {
        if let role {
            HStack(spacing: 6) {
                Label {
                    Text(role.displayName)
                        .fontWeight(.semibold)
                } icon: {
                    Image(systemName: role.iconName)
                }
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .foregroundStyle(role.tintColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(role.tintColor.opacity(0.15), in: Capsule())

                Text(role.permissionSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if isLoadingRole {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading access…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Label("No access", systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private extension BackendRole {
    var displayName: String {
        switch self {
        case .owner: return "Owner"
        case .manager: return "Manager"
        case .supervisor: return "Supervisor"
        case .operator: return "Operator"
        }
    }

    var iconName: String {
        switch self {
        case .owner: return "crown.fill"
        case .manager: return "person.badge.shield.checkmark.fill"
        case .supervisor: return "person.2.fill"
        case .operator: return "wrench.and.screwdriver.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .owner: return .purple
        case .manager: return .blue
        case .supervisor: return .teal
        case .operator: return .orange
        }
    }

    var permissionSummary: String {
        switch self {
        case .owner: return "Full access"
        case .manager: return "Financials & settings"
        case .supervisor: return "Edit & delete records"
        case .operator: return "Field operations only"
        }
    }
}
