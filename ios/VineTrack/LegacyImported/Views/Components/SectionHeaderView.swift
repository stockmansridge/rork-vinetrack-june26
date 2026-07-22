import SwiftUI

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(VineyardTheme.olive)
    }
}

struct PaddockSectionHeader: View {
    let title: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            GrapeLeafIcon(size: 14)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(VineyardTheme.olive)
    }
}
