"""Regression guards for the iOS in-progress spray's incorrect Start Trip route.

These assert production navigation wiring only. The native route scenarios are
in SprayProgramResumeRouteTests.swift; neither set substitutes for device UI QA.
"""
from pathlib import Path
import unittest

from test_spray_product_recursion import block

ROOT = Path(__file__).resolve().parents[2]


class SprayResumeWiringTests(unittest.TestCase):
    def setUp(self):
        self.source = (ROOT / "ios/VineTrack/App/SprayTripSetupSheet.swift").read_text()

    def test_resume_picker_cannot_activate_a_trip_again(self):
        # The reported defect called activateSavedTrip for an isActive record;
        # the service rejected it and the sheet ignored that failure.
        self.assertNotIn("activateSavedTrip(", self.source)
        self.assertNotIn("SprayTripStartConfirmationSheet(", self.source)
        self.assertNotIn("claimDeviceTrip(", self.source)
        self.assertNotIn("startTrip(", self.source)

    def test_resume_has_live_and_saved_destinations_with_visible_failure(self):
        sheet = block(self.source, self.source.index("private struct SprayInProgressTripSheet:"))
        self.assertIn("SprayProgramResumeRoute.resolve(", sheet)
        self.assertIn("ActiveTripView(trip: active)", sheet)
        self.assertIn("TripDetailView(trip: trip)", sheet)
        self.assertIn("Label(message, systemImage:", sheet)
        self.assertIn('ContentUnavailableView("Spray unavailable"', sheet)
        # Merely viewing a paused trip cannot change its recorded state.
        self.assertNotIn("resumeTrip(", sheet)
        self.assertNotIn("updateTrip(", sheet)
        self.assertNotIn("startTank(", sheet)

    def test_route_is_rechecked_against_current_link_scope_and_ownership(self):
        sheet = block(self.source, self.source.index("private struct SprayInProgressTripSheet:"))
        for evidence in (
            "store.sprayRecords.first", "record?.canonicalTripId", "store.trips.first",
            "store.selectedVineyardId", "store.deviceActiveTripId", "store.isDeviceTripOwner",
            "tracking.activeTrip?.id",
        ):
            self.assertIn(evidence, sheet)

    def test_picker_finishes_dismissal_before_presenting_existing_trip(self):
        self.assertIn(".sheet(isPresented: $showResumeProgram, onDismiss:", self.source)
        self.assertIn("resumedRecord = pendingResumeRecord", self.source)
        self.assertIn(".sheet(item: $resumedRecord", self.source)
        self.assertNotIn("DispatchQueue.main.async { startTripFromRecord(record) }", self.source)


if __name__ == "__main__":
    unittest.main()
