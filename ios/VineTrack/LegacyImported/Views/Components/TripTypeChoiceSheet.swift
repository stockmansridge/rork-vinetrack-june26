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
                    // Transparent offline artwork blends into the sheet background.
                    Image("TripStartHero")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(height: 170)
                        .accessibilityHidden(true)

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
