import SwiftUI

struct FertigationApplicationHistoryView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(SystemAdminService.self) private var admin
    @Environment(NewBackendAuthService.self) private var auth
    let stepId: UUID
    @State private var applications: [FertigationDomain.Application] = []
    @State private var error: String?
    var body: some View {
        List {
            if admin.isSystemAdmin {
                ForEach(applications) { application in
                    FertigationApplicationView(application: application, formatter: store.settings.regionFormatter, showSession: true)
                }
                if applications.isEmpty { Text(error ?? "No applications yet.").foregroundStyle(.secondary) }
            }
        }.navigationTitle("Application History")
            .task(id: store.selectedVineyardId) {
                applications = []
                guard admin.isSystemAdmin, let vineyard = store.selectedVineyardId else { return }
                let owner = auth.userId
                do {
                    let result = try await SupabaseFertigationRepository().applications(vineyardId: vineyard, programStepId: stepId, includeReversed: true)
                    guard owner == auth.userId, vineyard == store.selectedVineyardId, admin.isSystemAdmin else { return }
                    applications = result
                } catch { self.error = "Application History could not be loaded." }
            }
    }
}
