import SwiftUI

/// Platform-admin Feature Flags / Diagnostics controls.
///
/// Visible only inside the Admin section, which is itself gated by
/// `SystemAdminService.isSystemAdmin`. Toggles write through
/// `set_system_feature_flag` in Supabase and the flags are read by both
/// iOS and the Lovable portal.
struct SystemFeatureFlagsView: View {
    @Environment(SystemAdminService.self) private var systemAdmin

    @State private var pendingKey: String?
    @State private var localError: String?

    var body: some View {
        Form {
            if !systemAdmin.isSystemAdmin {
                Section {
                    Label("You are not a system administrator.", systemImage: "lock.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }

            if let error = localError ?? systemAdmin.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }

            ForEach(groupedCategories, id: \.self) { category in
                Section {
                    ForEach(flags(for: category)) { flag in
                        flagRow(flag)
                    }
                } header: {
                    Text(headerTitle(for: category))
                } footer: {
                    Text(footerText(for: category))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if systemAdmin.flags.isEmpty && !systemAdmin.isLoading {
                Section {
                    Text("No feature flags configured.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Last refreshed") {
                    if let date = systemAdmin.lastLoadedAt {
                        Text(date, format: .relative(presentation: .named))
                    } else {
                        Text("—")
                    }
                }
            } header: {
                Text("Status")
            } footer: {
                Text("Flags are stored in Supabase and shared with the Lovable portal. Changes apply on next refresh in each client.")
            }
        }
        .navigationTitle("Feature Flags")
        .navigationBarTitleDisplayMode(.inline)
        .task { await systemAdmin.refresh() }
        .refreshable { await systemAdmin.refresh() }
        .overlay {
            if systemAdmin.isLoading && systemAdmin.flags.isEmpty {
                ProgressView()
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func flagRow(_ flag: SystemFeatureFlag) -> some View {
        let binding = Binding<Bool>(
            get: { flag.isEnabled },
            set: { newValue in
                Task { await toggle(flag: flag, to: newValue) }
            }
        )

        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: binding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(flag.displayLabel)
                        .font(.subheadline.weight(.medium))
                    Text(flag.key)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            .disabled(!systemAdmin.isSystemAdmin || pendingKey == flag.key)

            if let description = flag.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private var groupedCategories: [String] {
        let categories = Set(systemAdmin.sortedFlags.map { $0.category ?? "other" })
        return categories.sorted()
    }

    private func flags(for category: String) -> [SystemFeatureFlag] {
        systemAdmin.sortedFlags.filter { ($0.category ?? "other") == category }
    }

    private func headerTitle(for category: String) -> String {
        switch category {
        case "diagnostics": return "Diagnostics"
        case "beta":        return "Beta Features"
        case "other":       return "Other"
        default:            return category.capitalized
        }
    }

    private func footerText(for category: String) -> String {
        switch category {
        case "diagnostics":
            return "Diagnostic / debug panels are hidden by default. Enable a flag to expose its tooling to all signed-in clients."
        case "beta":
            return "Opt-in experimental features."
        default:
            return ""
        }
    }

    private func toggle(flag: SystemFeatureFlag, to newValue: Bool) async {
        pendingKey = flag.key
        defer { pendingKey = nil }
        localError = nil
        let ok = await systemAdmin.setFlag(key: flag.key, isEnabled: newValue)
        if !ok {
            localError = systemAdmin.lastError ?? "Failed to update flag."
        }
    }
}
