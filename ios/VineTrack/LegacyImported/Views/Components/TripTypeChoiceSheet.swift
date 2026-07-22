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
                    AsyncImage(url: URL(string: "https://r2-pub.rork.com/projects/u8ega94cbdz6azh6dulre/assets/9c0a966b-50ac-4bf5-990e-15701eb5616b.png")) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            Color.clear
                        }
                    }
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
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .font(.title2)
                                .foregroundStyle(VineyardTheme.earthBrown)
                                .frame(width: 44, height: 44)
                                .background(VineyardTheme.earthBrown.opacity(0.12))
                                .clipShape(.rect(cornerRadius: 10))

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
                            Image(systemName: "sprinkler.and.droplets.fill")
                                .font(.title2)
                                .foregroundStyle(VineyardTheme.leafGreen)
                                .frame(width: 44, height: 44)
                                .background(VineyardTheme.leafGreen.opacity(0.12))
                                .clipShape(.rect(cornerRadius: 10))

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
