import SwiftUI

struct BackendTeamAccessView: View {
    let vineyardId: UUID
    let vineyardName: String

    @Environment(NewBackendAuthService.self) private var auth
    @Environment(MigratedDataStore.self) private var store
    @State private var members: [BackendVineyardMember] = []
    @State private var pendingInvitations: [BackendInvitation] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var showInviteSheet: Bool = false
    @State private var memberToEdit: BackendVineyardMember?
    @State private var showEditMember: Bool = false
    @State private var showTransferSheet: Bool = false

    private let teamRepository: any TeamRepositoryProtocol = SupabaseTeamRepository()

    private var currentUserMember: BackendVineyardMember? {
        guard let userId = auth.userId else { return nil }
        return members.first { $0.userId == userId }
    }

    private var canManage: Bool {
        currentUserMember?.role.canInviteMembers ?? false
    }

    /// Owner/manager-only — gates operator category assignment, which is
    /// part of trip costing (private to managers).
    private var canAssignOperatorCategory: Bool {
        currentUserMember?.role.canViewCosting ?? false
    }

    private var vineyardOperatorCategories: [OperatorCategory] {
        store.operatorCategories.filter { $0.vineyardId == vineyardId }
    }

    private var isCurrentUserOwner: Bool {
        currentUserMember?.role == .owner
    }

    private var transferEligibleMembers: [BackendVineyardMember] {
        members.filter { $0.userId != auth.userId && $0.role != .owner }
    }

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                if members.isEmpty && !isLoading {
                    Text("No members yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(members, id: \.userId) { member in
                        memberRow(member)
                    }
                }
            } header: {
                HStack {
                    Text("Members")
                    Spacer()
                    if isLoading {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            if !pendingInvitations.isEmpty {
                Section("Pending Invitations") {
                    ForEach(pendingInvitations, id: \.id) { invitation in
                        invitationRow(invitation)
                    }
                }
            }

            if isCurrentUserOwner {
                Section {
                    Button {
                        showTransferSheet = true
                    } label: {
                        Label("Transfer Ownership", systemImage: "crown")
                    }
                    .disabled(transferEligibleMembers.isEmpty)
                } footer: {
                    if transferEligibleMembers.isEmpty {
                        Text("Add another active member before you can transfer ownership.")
                    } else {
                        Text("Make another member the owner of this vineyard. You will become Manager.")
                    }
                }
            }

            Section {
                NavigationLink {
                    RolesPermissionsInfoView()
                } label: {
                    Label("Roles & Permissions", systemImage: "person.badge.shield.checkmark.fill")
                }
            }
        }
        .navigationTitle("Team & Access")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManage {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showInviteSheet = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showInviteSheet) {
            BackendInviteMemberSheet(vineyardId: vineyardId, vineyardName: vineyardName) {
                Task { await reload() }
            }
        }
        .sheet(isPresented: $showEditMember) {
            if let member = memberToEdit {
                EditMemberRoleSheet(
                    member: member,
                    canManage: canManage,
                    canAssignOperatorCategory: canAssignOperatorCategory,
                    operatorCategories: vineyardOperatorCategories,
                    onSave: { newRole, newOperatorCategoryId in
                        showEditMember = false
                        Task { await updateMember(member: member, newRole: newRole, newOperatorCategoryId: newOperatorCategoryId) }
                    },
                    onRemove: {
                        showEditMember = false
                        Task { await removeMember(member) }
                    }
                )
            }
        }
        .sheet(isPresented: $showTransferSheet) {
            TransferOwnershipSheet(
                vineyardName: vineyardName,
                eligibleMembers: transferEligibleMembers,
                onTransfer: { newOwnerId, removeOldOwner in
                    showTransferSheet = false
                    Task { await transferOwnership(newOwnerId: newOwnerId, removeOldOwner: removeOldOwner) }
                }
            )
        }
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func memberRow(_ member: BackendVineyardMember) -> some View {
        Button {
            if canManage && member.role != .owner {
                memberToEdit = member
                showEditMember = true
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(roleColor(member.role).gradient)
                        .frame(width: 36, height: 36)
                    Image(systemName: roleIcon(member.role))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(memberPrimaryName(member))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    if let email = memberSecondaryEmail(member) {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack(spacing: 6) {
                        Text(member.role.rawValue.capitalized)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(roleColor(member.role))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(roleColor(member.role).opacity(0.12), in: Capsule())
                        if let categoryName = member.operatorCategoryName, !categoryName.isEmpty {
                            Text(categoryName)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                    }
                }
                Spacer()
                if member.userId == auth.userId {
                    Text("You")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(VineyardTheme.leafGreen)
                }
                if canManage && member.role != .owner {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!canManage || member.role == .owner)
    }

    private func invitationRow(_ invitation: BackendInvitation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(invitation.email)
                .font(.subheadline.weight(.medium))
            HStack(spacing: 6) {
                Text(invitation.role.rawValue.capitalized)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(VineyardTheme.leafGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(VineyardTheme.leafGreen.opacity(0.12), in: Capsule())
                Text(invitation.status.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            members = try await teamRepository.listMembers(vineyardId: vineyardId)
        } catch {
            errorMessage = error.localizedDescription
        }
        do {
            let all = try await teamRepository.listPendingInvitations()
            let filtered = all.filter { $0.vineyardId == vineyardId && $0.status.lowercased() == "pending" }
            var seenEmails = Set<String>()
            var deduped: [BackendInvitation] = []
            for invitation in filtered.sorted(by: { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }) {
                let key = invitation.email.lowercased()
                if seenEmails.contains(key) { continue }
                seenEmails.insert(key)
                deduped.append(invitation)
            }
            pendingInvitations = deduped
        } catch {
            // Non-fatal — members still display.
        }
    }

    private func updateMember(member: BackendVineyardMember, newRole: BackendRole, newOperatorCategoryId: UUID?) async {
        do {
            if newRole != member.role {
                try await teamRepository.updateMemberRole(vineyardId: vineyardId, userId: member.userId, role: newRole)
            }
            if newOperatorCategoryId != member.operatorCategoryId {
                try await teamRepository.updateMemberOperatorCategory(
                    vineyardId: vineyardId,
                    userId: member.userId,
                    operatorCategoryId: newOperatorCategoryId
                )
            }
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeMember(_ member: BackendVineyardMember) async {
        do {
            try await teamRepository.removeMember(vineyardId: vineyardId, userId: member.userId)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func transferOwnership(newOwnerId: UUID, removeOldOwner: Bool) async {
        do {
            try await teamRepository.transferOwnership(
                vineyardId: vineyardId,
                newOwnerId: newOwnerId,
                removeOldOwner: removeOldOwner
            )
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Display priority: profiles.full_name → vineyard_members.display_name →
    /// email → "Member". Matches the resolved display name returned by the
    /// `get_vineyard_team_members` RPC.
    private func memberPrimaryName(_ member: BackendVineyardMember) -> String {
        if let fullName = member.fullName?.trimmingCharacters(in: .whitespacesAndNewlines), !fullName.isEmpty {
            return fullName
        }
        if let displayName = member.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !displayName.isEmpty {
            return displayName
        }
        if let email = member.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            return email
        }
        return "Member"
    }

    /// Returns the email when it would add information not already shown as the
    /// primary line — avoids duplicating the email as both name and subtitle.
    private func memberSecondaryEmail(_ member: BackendVineyardMember) -> String? {
        guard let email = member.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
            return nil
        }
        return email == memberPrimaryName(member) ? nil : email
    }

    private func roleColor(_ role: BackendRole) -> Color {
        switch role {
        case .owner: return .orange
        case .manager: return .blue
        case .supervisor: return .purple
        case .operator: return .green
        }
    }

    private func roleIcon(_ role: BackendRole) -> String {
        switch role {
        case .owner: return "crown.fill"
        case .manager: return "person.crop.circle.badge.checkmark"
        case .supervisor: return "person.2.fill"
        case .operator: return "person.fill"
        }
    }
}

private struct EditMemberRoleSheet: View {
    let member: BackendVineyardMember
    let canManage: Bool
    /// Owner/manager-only — controls visibility of the Operator Category
    /// picker (which is a costing-related setting).
    let canAssignOperatorCategory: Bool
    let operatorCategories: [OperatorCategory]
    let onSave: (BackendRole, UUID?) -> Void
    let onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedRole: BackendRole
    @State private var selectedOperatorCategoryId: UUID?

    init(
        member: BackendVineyardMember,
        canManage: Bool,
        canAssignOperatorCategory: Bool,
        operatorCategories: [OperatorCategory],
        onSave: @escaping (BackendRole, UUID?) -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.member = member
        self.canManage = canManage
        self.canAssignOperatorCategory = canAssignOperatorCategory
        self.operatorCategories = operatorCategories
        self.onSave = onSave
        self.onRemove = onRemove
        self._selectedRole = State(initialValue: member.role)
        self._selectedOperatorCategoryId = State(initialValue: member.operatorCategoryId)
    }

    private var availableRoles: [BackendRole] {
        BackendRole.allCases.filter { $0 != .owner }
    }

    private var memberDisplayName: String {
        if let fullName = member.fullName?.trimmingCharacters(in: .whitespacesAndNewlines), !fullName.isEmpty {
            return fullName
        }
        if let displayName = member.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !displayName.isEmpty {
            return displayName
        }
        if let email = member.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            return email
        }
        return "—"
    }

    private var hasChanges: Bool {
        selectedRole != member.role || selectedOperatorCategoryId != member.operatorCategoryId
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Member") {
                    LabeledContent("Name", value: memberDisplayName)
                    if let email = member.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
                        LabeledContent("Email", value: email)
                    }
                    LabeledContent("Current Role", value: member.role.rawValue.capitalized)
                }

                Section("Change Role") {
                    Picker("Role", selection: $selectedRole) {
                        ForEach(availableRoles, id: \.self) { r in
                            Text(r.rawValue.capitalized).tag(r)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                if canAssignOperatorCategory {
                    Section {
                        Picker("Worker Type", selection: $selectedOperatorCategoryId) {
                            Text("None").tag(UUID?.none)
                            ForEach(operatorCategories) { cat in
                                Text(cat.name).tag(UUID?.some(cat.id))
                            }
                        }
                        .disabled(!canManage)
                    } header: {
                        Text("Worker Type")
                    } footer: {
                        if operatorCategories.isEmpty {
                            Text("Create worker types in Spray Management → Worker Types to assign hourly rates for trip cost calculations.")
                        } else {
                            Text("Used as the default for this member's labour cost on trips. Visible to owners and managers only.")
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Label("Remove from Vineyard", systemImage: "person.badge.minus")
                    }
                    .disabled(!canManage)
                }
            }
            .navigationTitle("Edit Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(selectedRole, selectedOperatorCategoryId)
                    }
                    .disabled(!canManage || !hasChanges)
                }
            }
        }
    }
}

private struct TransferOwnershipSheet: View {
    let vineyardName: String
    let eligibleMembers: [BackendVineyardMember]
    let onTransfer: (UUID, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedMemberId: UUID?
    @State private var removeOldOwner: Bool = false
    @State private var showConfirm: Bool = false

    private var selectedMember: BackendVineyardMember? {
        eligibleMembers.first { $0.userId == selectedMemberId }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Transferring ownership of **\(vineyardName)** is permanent. The new owner gains full control of the vineyard, including team management and deletion.")
                        .font(.callout)
                } header: {
                    Text("Transfer Ownership")
                }

                Section("New Owner") {
                    if eligibleMembers.isEmpty {
                        Text("No eligible members. Pending invitations cannot become owner until accepted.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(eligibleMembers, id: \.userId) { member in
                            Button {
                                selectedMemberId = member.userId
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(member.displayName ?? "Member")
                                            .foregroundStyle(.primary)
                                        Text(member.role.rawValue.capitalized)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedMemberId == member.userId {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    Toggle("Also remove me from this vineyard", isOn: $removeOldOwner)
                } footer: {
                    Text(removeOldOwner
                         ? "You will lose access to this vineyard after the transfer."
                         : "You will become Manager of this vineyard after the transfer.")
                }
            }
            .navigationTitle("Transfer Ownership")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Transfer") {
                        showConfirm = true
                    }
                    .disabled(selectedMember == nil)
                }
            }
            .alert("Confirm Transfer", isPresented: $showConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Transfer", role: .destructive) {
                    if let member = selectedMember {
                        onTransfer(member.userId, removeOldOwner)
                    }
                }
            } message: {
                if let member = selectedMember {
                    Text("This will make \(member.displayName ?? "this member") the owner of \(vineyardName). " +
                         (removeOldOwner ? "You will be removed from the vineyard." : "You will become Manager."))
                }
            }
        }
    }
}
