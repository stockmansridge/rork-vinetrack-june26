import SwiftUI

/// Displays only recorded identities, verified members or unambiguous finished linked Trip operators.
struct WorkTaskAttributionView: View {
    let task: WorkTask
    var showsAssignment: Bool = false
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth
    @State private var members: [BackendVineyardMember] = []
    @State private var resources: [VineyardExternalResource] = []

    private func person(_ id: UUID) -> String {
        let member = members.first { $0.userId == id && $0.vineyardId == task.vineyardId }
        return member?.fullName ?? member?.displayName ?? member?.email ?? "Recorded person (name unavailable)"
    }
    private var assigned: String {
        if let id = task.assignedTo { return person(id) }
        if let id = task.assignedExternalResourceId {
            guard let resource = resources.first(where: { $0.id == id && $0.vineyardId == task.vineyardId }) else { return "Historical resource (name unavailable)" }
            return resource.name + (resource.isActive && resource.deletedAt == nil ? "" : " · Inactive")
        }
        return "Unassigned"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if task.isFinalized {
                Text("Completed").foregroundStyle(Color.green)
                if let user = WorkTaskPlanning.completingUser(task, trips: store.trips, verifiedMemberIDs: Set(members.filter { $0.vineyardId == task.vineyardId }.map(\.userId))) {
                    Text("Completed by \(person(user))")
                } else { Text("Completed by unknown") }
                if showsAssignment { Text("Assigned to: \(assigned)") }
            } else {
                Text("To Do")
                Text("Assigned to: \(assigned)")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .task(id: "\(auth.userId?.uuidString ?? "")-\(task.vineyardId)") {
            guard let user = auth.userId else { members = []; resources = []; return }
            do {
                let directory = try await WorkTaskIdentityDirectory.shared.load(user: user, vineyard: task.vineyardId)
                guard auth.userId == user else { return }
                members = directory.0; resources = directory.1
            } catch { members = []; resources = [] }
        }
    }
}

/// Coalesces card reads within an account/vineyard; short-lived and never used for write permission.
@MainActor
private final class WorkTaskIdentityDirectory {
    static let shared = WorkTaskIdentityDirectory()
    private var requests: [String: (Date, Task<([BackendVineyardMember], [VineyardExternalResource]), Error>)] = [:]
    func load(user: UUID, vineyard: UUID) async throws -> ([BackendVineyardMember], [VineyardExternalResource]) {
        let key = "\(user)-\(vineyard)"
        if let cached = requests[key], Date().timeIntervalSince(cached.0) < 60 { return try await cached.1.value }
        let task = Task {
            async let members = SupabaseTeamRepository().listMembers(vineyardId: vineyard)
            async let resources = SupabaseExternalResourceRepository().list(vineyardId: vineyard)
            return try await (members, resources)
        }
        requests[key] = (Date(), task)
        do { return try await task.value } catch { requests.removeValue(forKey: key); throw error }
    }
}
