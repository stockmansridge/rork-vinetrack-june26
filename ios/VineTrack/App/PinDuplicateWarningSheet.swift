import SwiftUI
import CoreLocation

/// Warning sheet shown when a user is about to drop a pin near an existing
/// one. Allows viewing the existing pin, creating anyway, or cancelling.
struct PinDuplicateWarningSheet: View {
    let existingPin: VinePin
    let distance: Double
    let radius: Double
    let onCreateAnyway: () -> Void
    let onViewExisting: () -> Void
    let onCancel: () -> Void

    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var paddockName: String {
        guard let id = existingPin.paddockId else { return "—" }
        return store.paddocks.first { $0.id == id }?.name ?? "—"
    }

    private var distanceText: String {
        if distance < 1 { return String(format: "%.0f cm away", distance * 100) }
        return String(format: "%.1f m away", distance)
    }

    private var attachmentLabel: String? {
        PinAttachmentFormatter.attachmentLine(existingPin)
    }

    private var drivingPathLabel: String? {
        PinAttachmentFormatter.drivingPathLine(existingPin)
    }

    private var headlineText: String {
        if let pinRow = existingPin.pinRowNumber {
            return "Possible duplicate pin nearby on Row \(pinRow)"
        }
        if let row = existingPin.rowNumber {
            return "Possible duplicate pin nearby on Row \(row).5"
        }
        return "Possible duplicate pin nearby"
    }

    private var fullFacing: String {
        PinAttachmentFormatter.fullCompassName(degrees: existingPin.heading)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(.orange)
                        .padding(.top, 8)

                    Text(headlineText)
                        .font(.title3.weight(.bold))
                        .multilineTextAlignment(.center)

                    if let attachmentLabel {
                        Text("On \(attachmentLabel)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if let drivingPathLabel {
                        Text(drivingPathLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Text("There's already a pin within \(String(format: "%.1f m", radius)) of this location. You can view it, create another anyway, or cancel.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.vertical, 16)

                Form {
                    Section("Existing Pin") {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.fromString(existingPin.buttonColor).gradient)
                                .frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(existingPin.buttonName)
                                    .font(.headline)
                                Text(existingPin.mode.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(distanceText)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.orange)
                                .monospacedDigit()
                        }
                        LabeledContent("Status", value: existingPin.isCompleted ? "Completed" : "Active")
                        LabeledContent("Block", value: paddockName)
                        if existingPin.pinRowNumber != nil || existingPin.drivingRowNumber != nil {
                            if let pinRow = existingPin.pinRowNumber {
                                LabeledContent("On Row", value: "Row \(pinRow)")
                            }
                            if let drivingPath = existingPin.drivingRowNumber {
                                let side = (existingPin.pinSide ?? existingPin.side).rawValue
                                LabeledContent(
                                    "Driving path",
                                    value: "Row \(String(format: "%.1f", drivingPath)) — \(side) hand side facing \(fullFacing)"
                                )
                            }
                        } else if let row = existingPin.rowNumber {
                            LabeledContent("Row", value: "\(row).5")
                            LabeledContent("Side", value: "\(existingPin.side.rawValue) hand side")
                        }
                        LabeledContent(
                            "Created",
                            value: existingPin.timestamp.formatted(date: .abbreviated, time: .shortened)
                        )
                    }

                    Section {
                        Button {
                            onViewExisting()
                            dismiss()
                        } label: {
                            Label("View existing pin", systemImage: "mappin.circle.fill")
                        }
                        Button {
                            onCreateAnyway()
                            dismiss()
                        } label: {
                            Label("Create new pin anyway", systemImage: "plus.circle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle("Duplicate?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
            }
        }
    }
}
