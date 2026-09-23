import SwiftUI

struct ChangeTripRouteSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(TripTrackingService.self) private var tracking
    @Environment(\.dismiss) private var dismiss
    @State private var pattern: TrackingPattern = .sequential
    @State private var startPath: Double = 0.5
    @State private var higherFirst: Bool = true
    @State private var errorMessage: String?

    private var trip: Trip? { tracking.activeTrip }
    private var paddocks: [Paddock] {
        guard let trip else { return [] }
        let ids = Set(trip.paddockIds + (trip.paddockId.map { [$0] } ?? []))
        return store.paddocks.filter { ids.contains($0.id) }.sorted(by: TripRowSequencePlanner.rowOrderSort)
    }
    private var paths: [Double] { TripRowSequencePlanner.availablePaths(in: paddocks) }
    private var visited: Set<Double> { Set((trip?.completedPaths ?? []) + (trip?.skippedPaths ?? [])) }
    private var proposed: [Double] {
        TripRowSequencePlanner.generateSequence(
            paddocks: paddocks, pattern: pattern, startPath: startPath, directionHigherFirst: higherFirst
        ).filter { !visited.contains($0) }
    }
    private var startIsVisited: Bool { pattern != .freeDrive && visited.contains(startPath) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tracking Pattern") {
                    Picker("Tracking Pattern", selection: $pattern) {
                        ForEach(TrackingPattern.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                }
                if pattern != .freeDrive {
                    Section("Starting path / row") {
                        Picker("Starting path", selection: $startPath) {
                            ForEach(paths, id: \.self) { path in
                                Text(TripRowSequencePlanner.pathMenuLabel(path, paddocks: paddocks)).tag(path)
                            }
                        }
                        if startIsVisited {
                            Text("This path is already completed or skipped. Choose an unfinished path to keep earlier coverage.")
                                .foregroundStyle(.red)
                        }
                    }
                    Section("Direction") {
                        Picker("Direction", selection: $higherFirst) {
                            Text("Lower → Higher").tag(true)
                            Text("Higher → Lower").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section("Proposed remaining route") {
                    if pattern == .freeDrive {
                        Text("Free Drive — no planned current or next path. Existing coverage and GPS history stay intact.")
                    } else {
                        Text(TripRowSequencePlanner.sequencePreviewText(proposed))
                        Text("\(proposed.count) paths remaining · completed and skipped paths are kept.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Change Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try tracking.changeActiveRoute(pattern: pattern, startPath: startPath, higherFirst: higherFirst)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(startIsVisited || (pattern != .freeDrive && proposed.isEmpty))
                }
            }
            .alert("Couldn't change route", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) { errorMessage = nil } } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                guard let trip else { return }
                pattern = trip.trackingPattern
                startPath = trip.rowSequence.indices.contains(trip.sequenceIndex)
                    ? trip.rowSequence[trip.sequenceIndex] : (paths.first ?? 0.5)
                let sequence = Array(trip.rowSequence.dropFirst(trip.sequenceIndex))
                if let first = sequence.first, let next = sequence.dropFirst().first, first != next {
                    higherFirst = next > first
                }
            }
        }
    }
}
