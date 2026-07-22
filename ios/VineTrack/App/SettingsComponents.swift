import SwiftUI

struct SettingsIconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(color.gradient)
                .frame(width: size, height: size)
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
    }
}

struct SettingsRow: View {
    let title: String
    var subtitle: String? = nil
    let symbol: String
    let color: Color
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: 12) {
            SettingsIconTile(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let trailing {
                Spacer()
                trailing
            }
        }
    }
}

struct SettingsSectionHeader: View {
    let title: String
    var symbol: String? = nil
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .font(.caption)
            }
            Text(title)
        }
    }
}
