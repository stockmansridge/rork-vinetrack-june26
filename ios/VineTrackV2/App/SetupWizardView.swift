import SwiftUI

struct SetupWizardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store

    @AppStorage("setupWizardEnabled") private var wizardEnabled: Bool = true

    @State private var step: Int = 0
    @State private var showAddPaddock: Bool = false
    @State private var showAddTractor: Bool = false
    @State private var showAddRig: Bool = false

    private var hasBlock: Bool { !store.paddocks.isEmpty }
    private var hasTractor: Bool { !store.tractors.isEmpty }
    private var hasRig: Bool { !store.sprayEquipment.isEmpty }

    private var totalSteps: Int { 3 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    progressIndicator
                    stepCard
                    Spacer(minLength: 8)
                    toggleCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Setup Wizard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showAddPaddock, onDismiss: advanceIfComplete) {
                EditPaddockSheet(paddock: nil)
            }
            .sheet(isPresented: $showAddTractor, onDismiss: advanceIfComplete) {
                TractorFormSheet(tractor: nil)
            }
            .sheet(isPresented: $showAddRig, onDismiss: advanceIfComplete) {
                EquipmentFormSheet(equipment: nil)
            }
            .onAppear { jumpToFirstIncompleteStep() }
        }
    }

    // MARK: - Progress

    private var progressIndicator: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Step \(step + 1) of \(totalSteps)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(stepStatusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stepIsComplete ? VineyardTheme.leafGreen : .secondary)
            }
            HStack(spacing: 6) {
                ForEach(0..<totalSteps, id: \.self) { index in
                    Capsule()
                        .fill(barColor(for: index))
                        .frame(height: 6)
                }
            }
        }
    }

    private var stepStatusLabel: String {
        stepIsComplete ? "Completed" : "Pending"
    }

    private var stepIsComplete: Bool {
        switch step {
        case 0: return hasBlock
        case 1: return hasTractor
        case 2: return hasRig
        default: return false
        }
    }

    private func barColor(for index: Int) -> Color {
        let complete: Bool
        switch index {
        case 0: complete = hasBlock
        case 1: complete = hasTractor
        case 2: complete = hasRig
        default: complete = false
        }
        if complete { return VineyardTheme.leafGreen }
        return index == step ? Color.accentColor : Color(.systemGray5)
    }

    // MARK: - Step Card

    @ViewBuilder
    private var stepCard: some View {
        switch step {
        case 0:
            stepContent(
                icon: "square.grid.2x2.fill",
                tint: VineyardTheme.leafGreen,
                title: "Add a Block",
                description: "Blocks define the sections of your vineyard — boundaries, rows, and varieties. You need at least one block before you can plan sprays, log jobs, or estimate yield.",
                tip: "Tip: You can fine-tune row layout, irrigation flow rates, and varieties later from Vineyard Setup.",
                actionTitle: hasBlock ? "Add Another Block" : "Add Block",
                actionIcon: "plus",
                isComplete: hasBlock,
                completedMessage: "\(store.paddocks.count) block\(store.paddocks.count == 1 ? "" : "s") added",
                action: { showAddPaddock = true }
            )
        case 1:
            stepContent(
                icon: "truck.pickup.side.fill",
                tint: VineyardTheme.earthBrown,
                title: "Add a Tractor",
                description: "Tractors are linked to spray records and trips so you can track fuel usage and run-time per job. Add the brand, model, and an estimated fuel use in litres per hour.",
                tip: "Tip: Use the Estimate Fuel Use button (when AI Suggestions are enabled) to get a quick approximation from the brand and model.",
                actionTitle: hasTractor ? "Add Another Tractor" : "Add Tractor",
                actionIcon: "plus",
                isComplete: hasTractor,
                completedMessage: "\(store.tractors.count) tractor\(store.tractors.count == 1 ? "" : "s") added",
                action: { showAddTractor = true }
            )
        case 2:
            stepContent(
                icon: "drop.fill",
                tint: .teal,
                title: "Add a Spray Rig",
                description: "Spray rigs (sprayers and tanks) feed the Spray Calculator. Enter a name and tank capacity in litres so the app can work out chemical loads, full tank counts, and water volumes.",
                tip: "Tip: You can add multiple rigs and switch between them inside the Spray Calculator.",
                actionTitle: hasRig ? "Add Another Spray Rig" : "Add Spray Rig",
                actionIcon: "plus",
                isComplete: hasRig,
                completedMessage: "\(store.sprayEquipment.count) spray rig\(store.sprayEquipment.count == 1 ? "" : "s") added",
                action: { showAddRig = true }
            )
        default:
            EmptyView()
        }
    }

    private func stepContent(
        icon: String,
        tint: Color,
        title: String,
        description: String,
        tip: String,
        actionTitle: String,
        actionIcon: String,
        isComplete: Bool,
        completedMessage: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(tint.opacity(0.15))
                        .frame(width: 56, height: 56)
                    Image(systemName: icon)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                    if isComplete {
                        Label(completedMessage, systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(VineyardTheme.leafGreen)
                    } else {
                        Text("Required")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
            }

            Text(description)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(.yellow)
                    .font(.subheadline)
                Text(tip)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 10))

            Button(action: action) {
                HStack {
                    Image(systemName: actionIcon)
                        .font(.body.weight(.semibold))
                    Text(actionTitle)
                        .font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(tint, in: .rect(cornerRadius: 12))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            navigationRow
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    private var navigationRow: some View {
        HStack {
            Button {
                withAnimation { step = max(0, step - 1) }
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .disabled(step == 0)
            .opacity(step == 0 ? 0.4 : 1)

            Spacer()

            if step < totalSteps - 1 {
                Button {
                    withAnimation { step = min(totalSteps - 1, step + 1) }
                } label: {
                    HStack(spacing: 4) {
                        Text(stepIsComplete ? "Next" : "Skip")
                        Image(systemName: "chevron.right")
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
            } else if isAllComplete {
                Button {
                    dismiss()
                } label: {
                    Label("Finish", systemImage: "checkmark")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Toggle Card

    private var toggleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $wizardEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show Setup Wizard")
                        .font(.body.weight(.semibold))
                    Text("Turn off to hide the wizard button on the home screen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))

            if isAllComplete {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(VineyardTheme.leafGreen)
                    Text("Setup complete — the wizard will hide automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Logic

    private var isAllComplete: Bool { hasBlock && hasTractor && hasRig }

    private func jumpToFirstIncompleteStep() {
        if !hasBlock { step = 0 }
        else if !hasTractor { step = 1 }
        else if !hasRig { step = 2 }
        else { step = 0 }
    }

    private func advanceIfComplete() {
        guard step < totalSteps - 1, stepIsComplete else { return }
        withAnimation { step += 1 }
    }
}
