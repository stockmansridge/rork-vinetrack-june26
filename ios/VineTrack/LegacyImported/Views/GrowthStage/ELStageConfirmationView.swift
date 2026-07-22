import SwiftUI

struct ELStageConfirmationView: View {
    @Environment(MigratedDataStore.self) private var store
    let stage: GrowthStage
    let onConfirm: () -> Void
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                imageSection
                infoSection
                actionsSection
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var imageSection: some View {
        Group {
            if let resolved = store.resolvedELStageImage(for: stage) {
                Image(uiImage: resolved)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .frame(height: 220)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }

    private var infoSection: some View {
        VStack(spacing: 8) {
            Text(stage.code)
                .font(.title.weight(.bold))
                .foregroundStyle(.green)
            Text(stage.description)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var actionsSection: some View {
        VStack(spacing: 12) {
            Button(action: onConfirm) {
                Text("Confirm \(stage.code)")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.green.gradient)
                    .foregroundStyle(.white)
                    .clipShape(.rect(cornerRadius: 12))
            }
            Button(action: onBack) {
                Text("Back")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .foregroundStyle(.primary)
                    .clipShape(.rect(cornerRadius: 12))
            }
        }
    }
}
