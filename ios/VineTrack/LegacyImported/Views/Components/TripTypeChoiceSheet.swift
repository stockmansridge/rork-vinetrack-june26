import SwiftUI

enum TripType {
    case maintenance
    case spray
}

struct TripTypeChoiceSheet: View {
    let onSelect: (TripType) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 16) {
                    // Native art stays available offline; blue tractor and bright vines.
                    TripStartHeroArtwork()
                        .frame(height: 120)

                    VStack(spacing: 8) {
                        Text("Start a Trip")
                            .font(.title.bold())
                        Text("What type of trip are you starting?")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 40)

                VStack(spacing: 14) {
                    Button {
                        onSelect(.maintenance)
                    } label: {
                        HStack(spacing: 14) {
                            BrightToolIcon(
                                symbol: "wrench.and.screwdriver.fill",
                                colors: [VineyardTheme.earthBrown, .orange]
                            )

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Maintenance Trip")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("Track a general vineyard trip without spray data")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(.rect(cornerRadius: 12))
                    }

                    Button {
                        onSelect(.spray)
                    } label: {
                        HStack(spacing: 14) {
                            BrightToolIcon(
                                symbol: "sprinkler.and.droplets.fill",
                                colors: [VineyardTheme.leafGreen, .cyan]
                            )

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Spray Trip")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("Open the Spray Calculator to configure and start a spray job")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(.rect(cornerRadius: 12))
                    }
                }
                .padding(.horizontal, 20)

                Spacer()
                Spacer()
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}


/// Device-rendered replacement for the externally hosted Start Trip image.
private struct TripStartHeroArtwork: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TripStartVineArtwork()
            Image(systemName: "tractor")
                .resizable()
                .scaledToFit()
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.08, green: 0.38, blue: 0.85),
                            Color(red: 0.19, green: 0.56, blue: 0.98)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 132, height: 94)
                .accessibilityHidden(true)
            TripStartVineArtwork()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Blue tractor between bright green vineyard vines")
    }
}

private struct TripStartVineArtwork: View {
    private let leafGradient = LinearGradient(
        colors: [
            Color(red: 0.17, green: 0.79, blue: 0.28),
            Color(red: 0.58, green: 0.94, blue: 0.29)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color(red: 0.56, green: 0.39, blue: 0.23))
                .frame(width: 4, height: 84)
                .offset(y: 11)
            ForEach(0..<4, id: \.self) { level in
                HStack(spacing: 0) {
                    Image(systemName: "leaf.fill")
                        .resizable()
                        .scaledToFit()
                        .rotationEffect(.degrees(-35))
                    Image(systemName: "leaf.fill")
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(x: -1, y: 1)
                        .rotationEffect(.degrees(35))
                }
                .foregroundStyle(leafGradient)
                .frame(width: 58, height: 24)
                .offset(y: CGFloat(level) * 21 - 36)
            }
        }
        .frame(width: 62, height: 110)
        .accessibilityHidden(true)
    }
}
