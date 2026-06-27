import SwiftUI
import MapKit

/// Minimal stand-in for the legacy BunchCountEntrySheet that wasn't imported in
/// Phase 6G. Provides a simple form to enter bunches-per-vine and recorder name.
struct BunchCountEntrySheet: View {
    let site: SampleSite
    let onSave: (Double, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var bunchesText: String = ""
    @State private var nameText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Sample Site") {
                    LabeledContent("Block", value: site.paddockName)
                    LabeledContent("Row", value: "\(site.rowNumber)")
                    LabeledContent("Site", value: "#\(site.siteIndex)")
                }

                Section("Bunch Count") {
                    HStack {
                        Text("Bunches / Vine")
                        Spacer()
                        TextField("0", text: $bunchesText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 120)
                    }
                    HStack {
                        Text("Recorded By")
                        Spacer()
                        TextField("Name", text: $nameText)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 180)
                    }
                }
            }
            .navigationTitle("Record Bunches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let count = Double(bunchesText.replacingOccurrences(of: ",", with: ".")) ?? 0
                        onSave(count, nameText)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(Double(bunchesText.replacingOccurrences(of: ",", with: ".")) == nil)
                }
            }
            .onAppear {
                if let entry = site.bunchCountEntry {
                    bunchesText = String(format: "%.2f", entry.bunchesPerVine)
                    nameText = entry.recordedBy
                }
            }
        }
    }
}

/// Minimal stand-in for the legacy FullScreenPathMapView. Shows the paddocks,
/// sample sites and the generated path on a Map. Real functionality (path
/// navigation, walking-mode, etc.) is deferred.
struct FullScreenPathMapView: View {
    let paddocks: [Paddock]
    let sampleSites: [SampleSite]
    let pathWaypoints: [CoordinatePoint]
    let blockColors: [Color]
    let colorForPaddock: (Paddock) -> Color
    let onSiteSelected: (SampleSite) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(NetworkMonitor.self) private var network
    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            Group {
                if network.isOnline {
                    hybridMap
                } else {
                    offlineMap
                }
            }
            .navigationTitle("Sampling Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var offlineMap: some View {
        OfflineVineyardMapView(
            paddocks: paddocks.map { paddock in
                OfflineVineyardMapView.Paddock(
                    id: paddock.id,
                    polygon: paddock.polygonPoints.map { $0.coordinate },
                    rows: paddock.rows.map { [$0.startPoint.coordinate, $0.endPoint.coordinate] },
                    strokeColor: colorForPaddock(paddock),
                    fillColor: colorForPaddock(paddock).opacity(0.25),
                    name: paddock.name
                )
            },
            trails: pathWaypoints.count >= 2
                ? [OfflineVineyardMapView.Trail(
                    id: 0,
                    coordinates: pathWaypoints.map { $0.coordinate },
                    color: VineyardTheme.info,
                    lineWidth: 3
                  )]
                : [],
            pins: sampleSites.map { site in
                OfflineVineyardMapView.Pin(
                    id: site.id,
                    coordinate: site.coordinate,
                    color: site.isRecorded ? .green : .red,
                    isCompleted: site.isRecorded,
                    name: "\(site.siteIndex)"
                )
            }
        )
    }

    private var hybridMap: some View {
        Map(position: $cameraPosition) {
                ForEach(paddocks) { paddock in
                    let coords = paddock.polygonPoints.map { $0.coordinate }
                    if coords.count >= 3 {
                        MapPolygon(coordinates: coords)
                            .foregroundStyle(colorForPaddock(paddock).opacity(0.25))
                            .stroke(colorForPaddock(paddock), lineWidth: 2)
                    }
                }

                ForEach(sampleSites) { site in
                    Annotation("#\(site.siteIndex)", coordinate: site.coordinate) {
                        Button {
                            onSiteSelected(site)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(site.isRecorded ? Color.green : Color.red)
                                    .frame(width: 22, height: 22)
                                Text("\(site.siteIndex)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if pathWaypoints.count >= 2 {
                    MapPolyline(coordinates: pathWaypoints.map { $0.coordinate })
                        .stroke(VineyardTheme.info, lineWidth: 3)
                }
            }
            .mapStyle(.hybrid)
    }
}
