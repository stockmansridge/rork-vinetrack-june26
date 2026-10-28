import SwiftUI
import ImageIO

/// Account publications invalidate these rows, not the entire scrolling Form.
struct BackendSettingsAccountSection: View {
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(BiometricAuthService.self) private var biometric
    var body: some View {
        Section {
            NavigationLink { EditDisplayNameView() } label: {
                SettingsRow(title: "Name", subtitle: auth.userName ?? "—", symbol: "person.crop.circle.fill", color: .gray)
            }
            HStack(spacing: 12) {
                SettingsIconTile(symbol: "envelope.fill", color: .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Email").font(.subheadline.weight(.medium))
                    Text(auth.userEmail ?? "—").font(.caption).foregroundStyle(.secondary)
                }
            }
            NavigationLink { BiometricSettingsView() } label: {
                SettingsRow(title: "Face ID / Touch ID", subtitle: biometricSubtitle, symbol: biometricSymbol, color: VineyardTheme.leafGreen)
            }
        } header: {
            SettingsSectionHeader(title: "Account", symbol: "person.fill", color: .gray)
        }
    }
    private var biometricSubtitle: String {
        if !(biometric.deviceSupportsBiometrics || biometric.deviceSupportsAnyAuth) { return "Not available on this device" }
        return biometric.isEnabled ? "\(biometric.displayName) sign-in enabled" : "Sign in faster with \(biometric.displayName)"
    }
    private var biometricSymbol: String {
        switch biometric.biometry {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        case .none: return "lock.shield.fill"
        }
    }
}

/// Content-keyed, view-lifetime cache. Pixel preparation never occurs in body.
/// Changing either vineyard identity (parent .id) or logo bytes discards the old image.
struct SettingsVineyardThumbnail: View {
    let data: Data?
    @State private var prepared: CGImage?
    @State private var preparedData: Data?
    var body: some View {
        Group {
            if preparedData == data, let prepared {
                Image(decorative: prepared, scale: 3).resizable().scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(VineyardTheme.leafGreen.gradient)
                    GrapeLeafIcon(size: 20, color: .white)
                }
            }
        }
        .frame(width: 40, height: 40).clipShape(.rect(cornerRadius: 8))
        .task(id: data) {
            prepared = nil; preparedData = nil
            guard let data else { return }
            #if DEBUG
            SettingsRenderProbe.imageConstructions += 1
            #endif
            let image = await Task.detached(priority: .utility) { Self.prepare(data) }.value
            guard !Task.isCancelled else { return }
            prepared = image; preparedData = data
        }
    }
    nonisolated static func prepare(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 120,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}
