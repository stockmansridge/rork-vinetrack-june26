import Foundation

/// Names the one vineyard in which a protected Trip queue entry can be resumed.
///
/// Legacy Trip upload metadata is keyed by Trip ID only, so a Trip whose saved
/// snapshot belongs to another vineyard is never uploaded while a different
/// vineyard is selected. That fence is correct and stays exactly as it is.
/// What was missing is any way to see WHICH vineyard owns the Trip, so the
/// original Trip looked "protected" with no way forward.
///
/// This helper only answers "which vineyard should be selected to continue?".
/// It is pure and read-only: it never uploads, replays, acknowledges, clears or
/// reassigns anything. Resuming means the owner selects that vineyard and the
/// ordinary, fully gated sync then runs under that vineyard's own identity.
nonisolated struct TripResumeTarget: Equatable, Hashable, Sendable {
    let vineyardId: UUID
    let vineyardName: String

    /// Shown when the vineyard has no usable name.
    static let unnamedVineyard = "the other vineyard"

    /// - Parameters:
    ///   - persistedSnapshots: every locally saved Trip as (trip id, vineyard id),
    ///     including the selected vineyard's loaded Trips.
    ///   - accountVineyards: the vineyards currently listed for the signed-in
    ///     account. A vineyard outside this list is never offered.
    /// - Returns: nil unless exactly one saved snapshot owns the Trip, that
    ///   vineyard is not the selected one, and the account belongs to it.
    static func resolve(
        tripId: UUID,
        selectedVineyardId: UUID,
        persistedSnapshots: [(tripId: UUID, vineyardId: UUID)],
        accountVineyards: [(id: UUID, name: String)]
    ) -> TripResumeTarget? {
        let owners = Set(persistedSnapshots.filter { $0.tripId == tripId }.map(\.vineyardId))
        // Two snapshots under different vineyards is ambiguous ownership: offer nothing.
        guard owners.count == 1, let owner = owners.first, owner != selectedVineyardId,
              let vineyard = accountVineyards.first(where: { $0.id == owner }) else { return nil }
        let name = vineyard.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return TripResumeTarget(vineyardId: owner, vineyardName: name.isEmpty ? unnamedVineyard : name)
    }
}
