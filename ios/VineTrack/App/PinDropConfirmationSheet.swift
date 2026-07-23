import SwiftUI
import CoreLocation

/// Confirmation sheet shown when a Repair/Growth tile is tapped.
/// Mirrors the original PinDropView confirmation workflow but uses MigratedDataStore
/// and the new LocationService.
struct PinDropConfirmationSheet: View {
    enum Kind: Equatable {
        case button(ButtonConfig)
        case growthStage(GrowthStage)
    }

    let kind: Kind
    let initialSide: PinSide
    let onSaved: (_ title: String, _ subtitle: String) -> Void

    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(LocationService.self) private var locationService
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPaddockId: UUID?
    @State private var rowText: String = ""
    @State private var side: PinSide
    @State private var notes: String = ""
    @State private var manualLatText: String = ""
    @State private var manualLonText: String = ""
    @State private var useManualLocation: Bool = false
    @State private var errorMessage: String?

    init(
        kind: Kind,
        initialSide: PinSide = .right,
        onSaved: @escaping (_ title: String, _ subtitle: String) -> Void
    ) {
        self.kind = kind
        self.initialSide = initialSide
        self.onSaved = onSaved
        _side = State(initialValue: initialSide)
    }

    private var title: String {
        switch kind {
        case .button(let btn): return btn.name
        case .growthStage(let stage): return "EL \(stage.code)"
        }
    }

    private var subtitle: String {
        switch kind {
        case .button(let btn): return btn.mode == .repairs ? "Repair pin" : "Growth observation"
        case .growthStage(let stage): return stage.description
        }
    }

    private var color: Color {
        switch kind {
        case .button(let btn): return Color.fromString(btn.color)
        case .growthStage: return Color.fromString("darkgreen")
        }
    }

    private var iconName: String {
        switch kind {
        case .button(let btn): return ButtonIconMap.icon(for: btn.name)
        case .growthStage: return "leaf.fill"
        }
    }

    private var hasGPS: Bool { locationService.location != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(color.gradient)
                                .frame(width: 52, height: 52)
                            Image(systemName: iconName)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.headline.weight(.bold))
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                Section("Location") {
                    Picker("Block", selection: $selectedPaddockId) {
                        Text("None").tag(UUID?.none)
                        ForEach(store.paddocks) { paddock in
                            Text(paddock.name).tag(UUID?.some(paddock.id))
                        }
                    }
                    HStack {
                        Text("Row")
                        Spacer()
                        TextField("Optional", text: $rowText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    Picker("Side", selection: $side) {
                        Text("Left").tag(PinSide.left)
                        Text("Right").tag(PinSide.right)
                    }
                    .pickerStyle(.segmented)
                }

                Section("GPS") {
                    if let coord = locationService.location?.coordinate, !useManualLocation {
                        HStack(spacing: 8) {
                            Image(systemName: "location.fill")
                                .foregroundStyle(.green)
                            Text(String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
                                .font(.subheadline.monospacedDigit())
                            Spacer()
                            Button("Manual") {
                                manualLatText = String(format: "%.5f", coord.latitude)
                                manualLonText = String(format: "%.5f", coord.longitude)
                                useManualLocation = true
                            }
                            .font(.caption.weight(.semibold))
                        }
                    } else {
                        if !hasGPS {
                            Label("Waiting for GPS — enter coordinates manually below.", systemImage: "location.slash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Latitude")
                            Spacer()
                            TextField("e.g. -34.12345", text: $manualLatText)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 160)
                        }
                        HStack {
                            Text("Longitude")
                            Spacer()
                            TextField("e.g. 138.12345", text: $manualLonText)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 160)
                        }
                        if hasGPS {
                            Button("Use device GPS") {
                                useManualLocation = false
                            }
                            .font(.caption.weight(.semibold))
                        }
                    }
                }

                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Drop Pin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { handleSave() }
                        .fontWeight(.bold)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func resolveCoordinate() -> CLLocationCoordinate2D? {
        if !useManualLocation, let coord = locationService.location?.coordinate {
            return coord
        }
        let lat = Double(manualLatText.trimmingCharacters(in: .whitespacesAndNewlines))
        let lon = Double(manualLonText.trimmingCharacters(in: .whitespacesAndNewlines))
        if let lat, let lon,
           CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return nil
    }

    private func handleSave() {
        guard let coord = resolveCoordinate() else {
            errorMessage = "Enter valid coordinates or wait for GPS."
            return
        }
        let heading = locationService.heading?.trueHeading
        let rowNumber = Int(rowText.trimmingCharacters(in: .whitespacesAndNewlines))
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalNotes: String? = trimmedNotes.isEmpty ? nil : trimmedNotes

        switch kind {
        case .button(let btn):
            store.createPinFromButton(
                button: btn,
                coordinate: coord,
                heading: heading,
                side: side,
                paddockId: selectedPaddockId,
                rowNumber: rowNumber,
                createdBy: auth.userName,
                createdByUserId: auth.userId,
                notes: finalNotes
            )
            onSaved("Pin Dropped", "\(btn.name) \u{2022} \(side == .left ? "Left" : "Right")")

        case .growthStage(let stage):
            store.createGrowthStagePin(
                stageCode: stage.code,
                stageDescription: stage.description,
                coordinate: coord,
                heading: heading,
                side: side,
                paddockId: selectedPaddockId,
                rowNumber: rowNumber,
                createdBy: auth.userName,
                createdByUserId: auth.userId,
                notes: finalNotes
            )
            onSaved("Pin Dropped", "EL \(stage.code) \u{2022} \(stage.description)")
        }
        dismiss()
    }
}
