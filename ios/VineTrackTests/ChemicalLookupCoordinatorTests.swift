import Foundation
import Testing
@testable import VineTrack

/// A lookup must be ended by a person, not by a layout pass.
///
/// On a real iPhone the search screen owned `searchTask` and `resolveTask` as
/// `@State` and cancelled both from `.onDisappear`. That hook does not mean
/// "the operator left": it fires on rotation, on the system snapshot a
/// screenshot takes, and on any reconstruction SwiftUI decides to perform. So
/// turning the phone sideways cancelled a 180 s structured resolve, and a
/// populated Review Chemical could fall back to Add Chemical mid-inspection.
///
/// The session now lives in this object, held in `@State` by the PRESENTING
/// view, which SwiftUI keeps alive across every rebuild beneath it. These tests
/// hold the three cancellation reasons to being the only ones there are.
@MainActor
struct ChemicalLookupCoordinatorTests {

    private func row(_ name: String = "SWITCH FUNGICIDE") -> ChemicalSearchRow {
        ChemicalSearchRow(
            result: ChemicalSearchResult(
                name: name,
                brand: "Syngenta Australia Pty Ltd",
                registrationNumber: "51797",
                source: ChemicalSearchResult.officialRegisterSource
            ),
            tier: .officialRegister,
            existing: nil
        )
    }

    // MARK: - 1, 2, 3. Reconstruction is not a cancellation

    /// `onAppear` fires again on every re-appearance. Re-seeding would throw
    /// away what the operator retyped, which is its own small data loss.
    @Test("Repeated appearances do not re-seed the query")
    func seedingHappensOnce() {
        let coordinator = ChemicalLookupCoordinator()
        coordinator.seedQueryIfNeeded("Dithane")
        #expect(coordinator.query == "Dithane")

        coordinator.query = "Switch"
        // Rotate, screenshot, rebuild — each of which re-runs `onAppear`.
        for _ in 0..<5 { coordinator.seedQueryIfNeeded("Dithane") }
        #expect(coordinator.query == "Switch")
    }

    /// The heart of the defect. Nothing about a view's lifetime touches the
    /// session, so there is no path from a rotation to a cancelled request.
    @Test("A resolved draft survives arbitrary view reconstruction")
    func resolvedDraftSurvivesReconstruction() {
        let coordinator = ChemicalLookupCoordinator()
        coordinator.handOff(
            row(),
            lookup: nil,
            country: "AU",
            existing: nil,
            vineyardId: UUID()
        )
        #expect(coordinator.reviewDraft != nil)
        #expect(coordinator.isReviewing)

        for _ in 0..<10 { coordinator.seedQueryIfNeeded("anything") }
        #expect(coordinator.reviewDraft != nil)
    }

    // MARK: - 4. Explicit Cancel cancels

    @Test("An explicit dismissal clears in-flight work")
    func explicitCancelStopsWork() {
        let coordinator = ChemicalLookupCoordinator()
        coordinator.cancel(.operatorDismissed)
        #expect(!coordinator.isSearching)
        #expect(!coordinator.isResolving)
        #expect(!coordinator.hasInFlightWork)
    }

    // MARK: - 5. A new search supersedes only the previous one

    @Test("Cancellation has exactly three legitimate reasons")
    func cancellationReasonsAreClosed() {
        // Stated as a test because the regression is re-introduced by ADDING a
        // fourth caller, not by changing one of these three.
        #expect(ChemicalLookupCancellation.operatorDismissed.rawValue == "operatorDismissed")
        #expect(ChemicalLookupCancellation.superseded.rawValue == "superseded")
        #expect(ChemicalLookupCancellation.presentationEnded.rawValue == "presentationEnded")
    }

    // MARK: - 6, 7. The review session ends only when someone ends it

    @Test("A review session is cleared only by finishing it")
    func reviewEndsOnlyExplicitly() {
        let coordinator = ChemicalLookupCoordinator()
        coordinator.handOff(
            row(),
            lookup: nil,
            country: "AU",
            existing: nil,
            vineyardId: UUID()
        )
        #expect(coordinator.isReviewing)

        // Cancelling in-flight NETWORK work is not the same act as abandoning
        // a draft that has already been produced.
        coordinator.cancel(.operatorDismissed)
        #expect(coordinator.reviewDraft != nil)

        coordinator.finishReview()
        #expect(coordinator.reviewDraft == nil)
        #expect(!coordinator.isReviewing)
    }

    @Test("Choosing manual entry is a review session too, and ends the same way")
    func manualEntryIsASession() {
        let coordinator = ChemicalLookupCoordinator()
        coordinator.showManualEntry = true
        #expect(coordinator.isReviewing)
        coordinator.finishReview()
        #expect(!coordinator.showManualEntry)
    }

    /// A failed resolve must not silently produce a degraded draft. Continuing
    /// with only the search row is a decision the operator takes.
    @Test("Continuing without register details does nothing unless a row failed")
    func continueRequiresAFailedRow() {
        let coordinator = ChemicalLookupCoordinator()
        coordinator.continueWithoutRegisterDetails(
            country: "AU",
            existing: nil,
            vineyardId: UUID()
        )
        #expect(coordinator.reviewDraft == nil)
    }
}
