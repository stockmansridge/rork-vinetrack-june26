import SwiftUI

/// Picker sheet shown after Davis Test Connection succeeds and there are
/// multiple stations on the WeatherLink account.
struct DavisStationPickerSheet: View {
    let stations: [DavisStation]
    let selectedStationId: String?
    let onSelect: (DavisStation) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if stations.isEmpty {
                    Section {
                        Text("No stations available. Re-run Test Connection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(stations) { station in
                            Button {
                                onSelect(station)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.subheadline)
                                        .foregroundStyle(.indigo)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(station.name)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text("ID \(station.stationId)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if let lat = station.latitude, let lon = station.longitude {
                                            Text(String(format: "%.4f, %.4f", lat, lon))
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    Spacer()
                                    if station.stationId == selectedStationId {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Choose your vineyard station")
                    } footer: {
                        Text("VineTrack will use this station's current conditions and any leaf wetness sensors for disease risk modelling.")
                    }
                }
            }
            .navigationTitle("Davis Stations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
