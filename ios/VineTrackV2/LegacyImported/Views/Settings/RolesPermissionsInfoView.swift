import SwiftUI

struct RolesPermissionsInfoView: View {
    var body: some View {
        List {
            Section {
                Text("Each team member has an assigned role. The role controls what they can see and do in the app. Some features, buttons and values are hidden automatically based on role.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Roles") {
                roleRow(
                    title: "Operator",
                    color: .green,
                    icon: "person.fill",
                    summary: "Field staff. Records daily work and runs Yield Estimation collections, but cannot delete records or see financial data."
                )
                roleRow(
                    title: "Supervisor",
                    color: .purple,
                    icon: "person.2.fill",
                    summary: "Day-to-day operations lead. Can manage and delete records but cannot see financial data."
                )
                roleRow(
                    title: "Manager",
                    color: .blue,
                    icon: "person.crop.circle.badge.checkmark",
                    summary: "Full access including financials, setup, team management and exports."
                )
                roleRow(
                    title: "Owner",
                    color: .orange,
                    icon: "crown.fill",
                    summary: "The vineyard creator. Same access as Manager and cannot be removed or changed."
                )
            }

            Section("What changes between roles") {
                bulletRow("Financial data (costs, rates, totals) is only visible to Managers and Owners.")
                bulletRow("Deleting records is limited to Supervisors and above.")
                bulletRow("Vineyard setup and team management are Manager-only.")
                bulletRow("Finalising and archiving records is limited to Managers and Owners.")
            }

            Section {
                Text("If a button or section is missing, it has been hidden for your role. Ask a Manager if you need access.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Roles & Permissions")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func roleRow(title: String, color: Color, icon: String, summary: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.gradient)
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(VineyardTheme.leafGreen)
                .padding(.top, 3)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
