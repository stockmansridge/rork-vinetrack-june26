import SwiftUI

/// Non-dismissable only while an online policy confirms the installed build is unsupported.
struct RequiredReleaseUpdateView: View {
    let policy: AppReleasePolicy
    let openStore: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("VineTrack update required")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(policy.displayMessage)
                .multilineTextAlignment(.center)
            Text("Your version of VineTrack is no longer supported. Update to continue.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Text("Installed: \(AppBuildInfo.version) (\(AppBuildInfo.buildNumber))\nLatest: \(policy.latestVersion) (\(policy.latestBuild))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Update VineTrack", action: openStore)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
