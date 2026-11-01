"""Production wiring guards for Review Spray Mix's operator-entered actuals.

These checks cover the UI -> start -> durable tank-commit connections that the
host amount/store tests cannot exercise. They do not simulate SwiftUI/Compose,
run a device, or replace the native acceptance tests. Assertions are scoped to
the responsible declaration/branch, rather than repository-wide token counts.
"""
from pathlib import Path
import re
import unittest

from test_spray_product_recursion import block, masked

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / "ios/VineTrack"
ANDROID = ROOT / "android-vinetrack/app/src/main/java/com/rork/vinetrack"


def read(root, relative):
    return (root / relative).read_text()


def routine(source, name):
    """Find a Swift/Kotlin body, skipping default closure parameters first."""
    clean = masked(source)
    declaration = re.search(r"\b(?:func|fun)\s+" + re.escape(name) + r"\s*\(", clean)
    if declaration is None:
        raise AssertionError(f"Missing production routine: {name}")
    depth = 1
    cursor = declaration.end()
    while depth and cursor < len(clean):
        depth += (clean[cursor] == "(") - (clean[cursor] == ")")
        cursor += 1
    if depth:
        raise AssertionError(f"Unclosed parameters: {name}")
    return block(source, cursor)


def branch(source, marker):
    return block(source, source.index(marker))


class SprayReviewActualsWiringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.calculator = read(IOS, "App/SprayCalculatorView.swift")
        cls.review = read(IOS, "App/SprayStartRateReview.swift")
        cls.saved_sheet = read(IOS, "App/SprayTripStartConfirmationSheet.swift")
        cls.tracking = read(IOS, "LegacyImported/Services/TripTrackingService.swift")
        cls.detail = read(IOS, "LegacyImported/Views/Trips/TripDetailView.swift")
        cls.android_calculator = read(ANDROID, "ui/screens/SprayCalculatorScreen.kt")
        cls.android_confirmation = read(ANDROID, "ui/screens/SprayTripStartConfirmation.kt")
        cls.android_vm = read(ANDROID, "ui/AppViewModel.kt")

    def assert_order(self, source, *markers):
        cursor = 0
        for marker in markers:
            found = source.find(marker, cursor)
            self.assertGreaterEqual(found, 0, f"Missing or out-of-order wiring: {marker}")
            cursor = found + len(marker)

    def assert_no_actual_checkbox(self, source):
        self.assertNotRegex(masked(source), r"\b(?:Toggle|Checkbox|Switch)\s*\(")
        self.assertNotIn("confirmActualRates", source)
        self.assertNotIn("confirmedActualRates", source)

    def test_ios_review_is_presented_with_its_complete_mix_snapshot(self):
        snapshot = branch(self.calculator, "private struct SprayMixReview:")
        for field in ("let tanks: [SprayTank]", "let geometry:", "let vineyardId:", "let userId:", "let formatter:"):
            self.assertIn(field, snapshot)
        sheet = branch(self.calculator, ".sheet(item: $pendingMixReview)")
        self.assertIn("startConfirmationSheet(review)", sheet)
        prepare = routine(self.calculator, "saveAndStartJob")
        self.assert_order(prepare, "initialTankInput = SprayInitialTankInput()", "pendingMixReview = SprayMixReview(tanks: tanks")
        self.assertIn("geometry: flow.snapshot", prepare)

    def test_ios_actual_entry_precedes_path_controls_and_is_not_path_gated(self):
        review = routine(self.calculator, "startConfirmationSheet")
        self.assert_order(review, "SprayInitialTankActualsEditor(", "confirmTripSetup", "confirmAndStartJob()")
        editor = review[review.index("SprayInitialTankActualsEditor("):review.index("confirmTripSetup")]
        self.assertIn("input: $initialTankInput", editor)
        self.assertIn(".disabled(isStartingJob || retainedStartActuals != nil)", editor)
        self.assertNotIn("trackingPattern", editor)
        self.assertNotIn("pathSequence", editor)
        self.assertIn("enteredInitialActuals == nil", review)
        self.assert_no_actual_checkbox(review)

    def test_ios_blank_operator_inputs_resolve_to_canonical_amounts(self):
        inputs = branch(self.review, "struct SprayInitialTankInput:")
        self.assertIn('var waterText: String = ""', inputs)
        self.assertIn("var chemicalTexts: [UUID: String] = [:]", inputs)
        resolve = routine(inputs, "resolved")
        self.assertIn("SprayEditingNumber.completeValue(waterText)", resolve)
        self.assertIn('SprayEditingNumber.completeValue(chemicalTexts[chemical.id] ?? "")', resolve)
        self.assertIn("chemical.unit.toBase(value)", resolve)
        self.assertIn("formatter.volumeToCanonical(displayWater)", resolve)
        self.assertNotIn("volumePerTank", resolve)
        self.assertNotIn("tank.waterVolume", resolve)
        editor = branch(self.review, "struct SprayInitialTankActualsEditor:")
        self.assertIn('identifier: "spray.actualWater"', editor)
        self.assertIn('identifier: "spray.actualChemical.', editor)
        self.assert_no_actual_checkbox(editor)

    def test_ios_new_start_freezes_entered_actuals_and_retries_original_identity(self):
        start = routine(self.calculator, "finalizeStartFromMixSummary")
        self.assert_order(start, "guard let amounts = enteredInitialActuals", "let record = retainedStartRecord ?? SprayRecord(",
                          "retainedStartActuals = amounts", "if let original = retainedStartTrip", "guard !hasAttemptedStart", "tracking.startTrip(")
        original = branch(start, "if let original = retainedStartTrip")
        self.assertIn("tracking.retryInitialSprayStart(tripId: original.id", original)
        self.assertIn("expectedAmounts: amounts, expectedRecordId: record.id", original)
        self.assertIn("tracking.activateSavedTrip(original", original)
        self.assertIn("initialTankActuals: amounts", original)
        self.assertIn("return", original)
        self.assertIn("initialTankActuals: amounts", start[start.index("tracking.startTrip("):])

    def test_ios_saved_start_threads_actuals_and_reports_failures(self):
        self.assertIn("onStart: (Double?, SprayInitialTankAmounts,", self.saved_sheet)
        self.assert_order(self.saved_sheet, "SprayInitialTankActualsEditor(", "guard let amounts = enteredActuals",
                          "retainedActuals = amounts", "onStart(parsedStartEngineHours, amounts)")
        self.assertIn("startError = message", self.saved_sheet)
        self.assert_no_actual_checkbox(self.saved_sheet)
        activate = routine(self.detail, "activateRateReviewedOriginal")
        self.assertIn("expectedAmounts: initialTankActuals", activate)
        self.assertIn("initialTankActuals: initialTankActuals", activate)
        self.assertIn("completion(", activate)

    def test_ios_stages_entered_actuals_before_async_activation(self):
        start = routine(self.tracking, "startTrip")
        planned = branch(start, "if !rowSequence.isEmpty")
        self.assert_order(planned, "store.saveSprayForLater(", "stageInitialTankMix(initialTankActuals", "finishPlannedActivation(")
        # Inspect the subsequent free-drive branch separately; a stage in the
        # occurrence branch alone cannot protect this asynchronous request.
        legacy = branch(start[start.index(planned) + len(planned):], "if isSpray, var record = sprayRecord")
        self.assert_order(legacy, "store.saveSprayForLater(", "stageInitialTankMix(initialTankActuals", "Task {", "await store.recoverLegacySprayReceipts()")
        saved = routine(self.tracking, "activateSavedTrip")
        self.assert_order(saved, "stageInitialTankMix(initialTankActuals", "Task {", "await repo.fetchTripForOccurrenceStart(")
        stage = routine(self.tracking, "stageInitialTankMix")
        for evidence in ("record.canonicalTripId == trip.id", "amounts.isValid(for: tank)",
                         "stageInitialMix(SprayInitialTankDraft(", "ownerId: owner", "sprayRecordId: record.id", "amounts: amounts"):
            self.assertIn(evidence, stage)

    def test_ios_completion_precedes_tracking_and_consumes_only_recorded_input(self):
        for name in ("finishLegacyTripStart", "finishPlannedActivation", "activateSavedTrip", "retryInitialSprayStart", "beginTracking"):
            with self.subTest(routine=name):
                body = routine(self.tracking, name)
                tracking_marker = "locationService.startUpdating()" if name == "beginTracking" else "beginTracking()"
                self.assert_order(body, "completeInitialTankMix(tripId:", tracking_marker)
        complete = routine(self.tracking, "completeInitialTankMix")
        self.assert_order(complete, "startTankCommitCoordinator.recover(", "confirmAndStartTank(pending:",
                          "draft.isRecorded(in: actuals.records, trip: committed)", "actuals.clearInitialMix(draft, trip: committed)")
        self.assertIn("actualWaterLitres: draft.amounts.waterLitres", complete)
        self.assertIn("actualChemicalBaseAmounts: draft.amounts.chemicalBaseAmounts", complete)
        retry = routine(self.tracking, "retryInitialSprayStart")
        self.assertIn("expectedRecordId == record.id", retry)
        self.assertIn("retained == expected", retry)
        self.assertIn("expected.isRecorded(", retry)
        self.assertNotIn("startTrip(", retry)

    def test_ios_actual_commit_rejects_missing_chemicals_without_planned_fallback(self):
        commit = routine(self.tracking, "confirmAndStartTank")
        self.assert_order(commit, "Set(actualChemicalBaseAmounts.keys) == Set(plannedTank.chemicals.map(\\.id))",
                          "actualAmountBase: actualChemicalBaseAmounts[chemical.id]!", "startTankCommitCoordinator.commit(")
        self.assertIn("waterVolumeL: actualWaterLitres", commit)
        self.assertNotRegex(commit, r"actualChemicalBaseAmounts\[[^\]]+\]\s*\?\?")
        self.assertNotIn("chemical.volumePerTank", commit)

    def test_android_entry_precedes_tracking_controls_and_draft_scope_excludes_route(self):
        review = routine(self.android_calculator, "SprayTankMixReview")
        self.assert_order(review, "actualAmounts()", "TrackingSetupContent(")
        scope = self.android_calculator.split("val actualScope =", 1)[1].split("val reviewedInput =", 1)[0]
        for identity in ("state.currentUserId", "state.selectedVineyardId", "SprayStartRateReview.evidence(currentReviewInput.tanks)"):
            self.assertIn(identity, scope)
        for route in ("trackingPattern", "startCandidateKey", "directionHigherFirst"):
            self.assertNotIn(route, scope)
        self.assertIn("SprayStartActualFields(reviewedInput.tanks, actualDraft, { updateActualDraft(it) }, enabled = !saving)", self.android_calculator)
        self.assertIn("actualsReady = actualAmounts != null && actualDraftSaved", self.android_calculator)

    def test_android_confirmation_delivers_typed_actuals_without_checkbox(self):
        confirmation = routine(self.android_confirmation, "SprayTripStartConfirmation")
        self.assertIn("SprayStartActualAmounts.parse(tanks, actualDraft, region::volumeToCanonical)", confirmation)
        self.assertIn("actuals != null && validRecipe", confirmation)
        self.assertIn("onStart(parsedHours, it)", confirmation)
        self.assert_no_actual_checkbox(confirmation)
        start = routine(self.android_calculator, "startJobNow")
        self.assertIn("input = reviewedInput", start)
        self.assertIn("startActuals = actuals", start)
        self.assertIn("startJobNow(hours, reviewedInput, entered, vm.sprayReviewDraft(actualDraftKey))", self.android_calculator)
        for path in ("ui/screens/SprayTripSetupScreen.kt", "ui/screens/SpraysScreen.kt"):
            self.assertRegex(read(ANDROID, path), r"vm\.startReviewedSprayJob\([^\n]+startHours, actuals\)")

    def test_android_amount_parser_cannot_substitute_calculated_quantities(self):
        amounts = read(ANDROID, "data/spray/SprayStartActualAmounts.kt")
        parse = routine(amounts, "parse")
        self.assertIn('number(text["water"].orEmpty(), locale)?.let(waterToLitres) ?: return null', parse)
        self.assertIn('number(text["chemical:$index"].orEmpty(), locale) ?: return null', parse)
        self.assertIn("chemicalUnitToBase(chemical.unit, amount)", parse)
        self.assertNotIn("volumePerTank", parse)
        self.assertNotIn("tank.waterVolume", parse)
        commit = routine(self.android_vm, "confirmAndStartTank")
        self.assert_order(commit, "actualChemicalBaseAmounts.keys != tank.chemicals.map { it.id }.toSet()",
                          "val amount = actualChemicalBaseAmounts[chemical.id] ?: return false", "actualAmountBase = amount",
                          "startTankCommitCoordinator.commit(")
        self.assertIn("waterVolumeL = actualWaterLitres", commit)
        self.assertNotIn("chemical.volumePerTank", commit)

    def test_android_persists_scoped_input_before_activation_and_checks_exact_commit(self):
        planned = routine(self.android_vm, "createQualifiedSpray")
        self.assert_order(planned, "retainInitialSprayActuals(planned.id, recordId, input.tanks, startActuals)",
                          "sprayCreateSync.enqueue(", "tripRepo.confirmPlannedStart(")
        saved = routine(self.android_vm, "startReviewedSprayJob")
        self.assert_order(saved, "retainInitialSprayActuals(tripId, record.id, record.tanks.orEmpty(), actuals)",
                          "startSprayJob(tripId, startHours, actuals.recipeEvidence)", "commitInitialSprayActuals(tripId, actuals)", "onResult(committed)")
        retain = routine(self.android_vm, "retainInitialSprayActuals")
        self.assertIn('SprayActualInputDraft("tank:$tripId:${tank.id}", owner, vineyard, text, tripId, tank.id, recordId)', retain)
        self.assertIn("existing?.let { return@runCatching it == draft }", retain)
        commit = routine(self.android_vm, "commitInitialSprayActuals")
        self.assertIn("actual.confirmedBy == owner && actual.waterVolumeL == entered.waterLitres", commit)
        self.assertIn("expectedAmounts[it.plannedChemicalId] == it.actualAmountBase", commit)
        self.assert_order(commit, "val draft = retainedDraft ?: return false", "confirmAndStartTank(pending, actuals.waterLitres, amounts)",
                          "!exactActualIsDurable()", "sprayTankActualStore.clearInputDraft(draft)")

    def test_android_legacy_start_and_retry_retain_actuals_before_request(self):
        legacy = routine(self.android_vm, "createSprayJobForLater")
        retained = branch(legacy, "if (retained != null)")
        self.assert_order(retained, "retainInitialSprayActuals(retained.trip.id, retained.recordId, retained.input.tanks, startActuals)",
                          "submitPreparedLegacySpray(retained)", "onReadyTrip(retained.trip.id)")
        new = legacy[legacy.index("val originalTimestamp ="):]
        self.assert_order(new, "retainInitialSprayActuals(originalTripId, originalRecordId, originalInput.tanks, startActuals)",
                          "legacySpraySaves.prepare(attempt)", "submitPreparedLegacySpray(attempt)")
        start = routine(self.android_vm, "startSprayJobNow")
        self.assertIn("createQualifiedSpray(input, paddockId, paddockIds, paddockName, rowPlan, true, startEngineHours, finish, startActuals)", start)
        self.assertIn("startActuals = startActuals, onResult = finish", start)

    def test_android_recording_waits_for_actuals_and_failed_start_retains_original(self):
        tracking = routine(self.android_vm, "beginTracking")
        review_guard = branch(tracking, "if (requiresFirstTankReview(trip))")
        self.assertIn("isTracking = false", review_guard)
        self.assertIn("return", review_guard)
        self.assert_order(tracking, "if (requiresFirstTankReview(trip))", "LocationTracker(", "isTracking = true")
        start = routine(self.android_vm, "startSprayJobNow")
        self.assertIn("commitInitialSprayActuals(active.id, startActuals)", start)
        self.assertIn("if (ok && active != null && actualsCommitted)", start)
        self.assertIn("active?.id?.takeIf { !actualsCommitted }", start)
        self.assertIn("owned.trip.id == original.trip.id", start)
        self.assertIn("legacySpraySaves.completeStart(original)", start)
        self.assertIn("inspectionTripIds = listOf(earlierQualified.id)", start)


if __name__ == "__main__":
    unittest.main()
