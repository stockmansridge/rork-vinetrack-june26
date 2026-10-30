#!/usr/bin/env python3
"""Focused release-blocker regressions, without native app builds.

Source guards verify the production UI wiring. Swift/Kotlin host probes execute
unchanged production canopy/volume models (plus Swift planning validation).
Only unrelated platform/storage boundaries are omitted. These are NOT native
SwiftUI/Compose or physical-device acceptance tests; those journeys live in the
existing MobileSprayUXParityUITests/SprayPhase1CalculatorAndroidTest suites.

Run: python3 -m unittest discover -s scripts/tests -p test_spray_flow_human_testing.py -v
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile
import unittest

from test_spray_product_recursion import block, masked

ROOT = Path(os.environ.get('VINETRACK_SOURCE_ROOT', Path(__file__).resolve().parents[2]))
IOS = 'ios/VineTrack/App/'
ANDROID = 'android-vinetrack/app/src/main/java/com/rork/vinetrack/'


def read(path):
    return (ROOT / path).read_text()


def declaration(source, marker):
    start = source.index(marker)
    body = block(source, start)
    opening = masked(source).index('{', start)
    return source[start:opening + len(body) + 2]


class SprayFlowSourceTests(unittest.TestCase):
    def test_ios_operation_has_truthful_unselected_state(self):
        source = read(IOS + 'SprayCalculatorView.swift')
        section = block(source, source.index('private var operationTypeSection:'))
        summary = block(source, source.index('private var applicationSummary:'))
        self.assertIn('isApplicationResolved ? operationType.rawValue : "Tap to select operation"', section)
        self.assertIn('if isApplicationResolved && operationType == type', section)
        self.assertIn('guard isApplicationResolved else { return "Select operation" }', summary)
        self.assertIn('isApplicationResolved = true', section)
        self.assertIn('@State private var isApplicationResolved = false', source)

    def test_android_operation_has_truthful_unselected_state(self):
        source = read(ANDROID + 'ui/screens/SprayCalculatorScreen.kt')
        self.assertIn('value = if (isApplicationResolved) operationType else "Tap to select operation"', source)
        self.assertIn('val applicationSummary = if (!isApplicationResolved) "Select operation"', source)
        self.assertIn('isApplicationResolved = true // Also resolves a tap', source)
        self.assertNotIn('even if Foliar Spray is already displayed', source)

    def test_ios_full_tank_is_not_hidden_for_new_drafts(self):
        view = read(IOS + 'SprayCalculatorView.swift')
        cards = read(IOS + 'SprayPlanningCardsView.swift')
        self.assertNotIn('showsFullTankOption', view + cards)
        self.assertIn('Picker("Planning method", selection: $method)', cards)
        self.assertIn('SprayPlanningMethod.allCases', cards)
        self.assertIn('LegacySpraySetup.fullTankMessage', cards)
        self.assertIn('Planning only', cards)

    def test_android_full_tank_is_not_hidden_for_new_drafts(self):
        view = read(ANDROID + 'ui/screens/SprayCalculatorScreen.kt')
        cards = read(ANDROID + 'ui/components/SprayPlanningCards.kt')
        self.assertNotIn('showsFullTankOption', view + cards)
        self.assertIn('SprayPlanningMethod.entries.forEachIndexed', cards)
        self.assertIn('LegacySpraySetup.FULL_TANK_MESSAGE', cards)
        self.assertIn('Planning only', cards)

    def test_ios_pass_help_is_inline_and_cards_share_width(self):
        cards = read(IOS + 'SprayPlanningCardsView.swift')
        self.assertIn('HStack(spacing: 0)', cards)
        row = block(cards, cards.index('HStack(spacing: 0)'))
        self.assertIn('row equivalent per pass', row)
        self.assertIn('SprayFieldHelp(title: "Controller rates"', row)
        self.assertIn('VStack(alignment: .leading, spacing: 14)', cards)
        self.assertEqual(cards.count('.frame(maxWidth: .infinity, alignment: .leading)'), 2)

    def test_android_pass_help_is_inline_and_cards_share_width(self):
        cards = read(ANDROID + 'ui/components/SprayPlanningCards.kt')
        self.assertIn('Text(when (configuration)', cards)
        start = cards.index('Text(when (configuration)')
        row_start = cards.rfind('Row(', 0, start)
        row = block(cards, row_start)
        self.assertIn('row equivalent per pass', row)
        self.assertIn('SprayInfoHelp("Controller rate explanation"', row)
        self.assertEqual(cards.count('Column(Modifier.fillMaxWidth().padding(14.dp)'), 2)

    def test_ios_confirmation_is_normal_action_then_success_state(self):
        source = read(IOS + 'SprayCanopyControls.swift')
        prompt = block(source, source.index('private var confirmPrompt:'))
        self.assertIn('if selection.isConfirmed', prompt)
        self.assertIn('Label("Canopy confirmed"', prompt)
        self.assertIn('selection.confirm()', prompt)
        self.assertIn('Text("Confirm canopy")', prompt)
        self.assertIn('.buttonStyle(.borderedProminent)', prompt)
        self.assertNotIn('.orange', prompt)
        self.assertNotIn('Text(selection.confirmationMessage)', source)

    def test_android_confirmation_is_normal_action_then_success_state(self):
        source = read(ANDROID + 'ui/components/SprayCanopySelector.kt')
        self.assertIn('if (isConfirmed)', source)
        self.assertIn('Text("Canopy confirmed"', source)
        self.assertIn('Text("Confirm canopy"', source)
        self.assertIn('onClick = onConfirm', source)
        self.assertNotIn('VineColors.Orange.copy', source)
        self.assertNotIn('Text(selection.confirmationMessage', source)

    def test_disabled_continue_names_confirmation_without_bypassing_gate(self):
        ios = read(IOS + 'SprayCalculatorView.swift')
        android = read(ANDROID + 'ui/screens/SprayCalculatorScreen.kt')
        for source in (ios, android):
            self.assertIn('Confirm canopy above', source)
            self.assertIn('flow.isComplete(step) && flow.isUnlocked(next)', source)
        self.assertIn('flow.blocker(for: step) == .canopyConfirmationRequired', ios)
        self.assertIn('flow.blocker(step) == SprayGuidedBlocker.CanopyConfirmationRequired', android)
        self.assertIn('sprayVolumeChoiceControls(decision)', ios)
        self.assertIn('focusVolumeQuestion = true', android)

    def test_full_tank_from_manual_displays_effective_basis_without_erasing_draft(self):
        ios = read(IOS + 'SprayCalculatorView.swift')
        binding = block(ios, ios.index('private var carrierChoiceBinding:'))
        self.assertIn('get: { flow.effectiveCarrierBasis }', binding)
        self.assertIn('changeRateDisplay(basis: $0, configuration: passConfiguration)', binding)
        self.assertIn('method: $planningMethod', ios)
        self.assertIn('method = planningMethod, onMethod = { planningMethod = it; result = null }',
                      read(ANDROID + 'ui/screens/SprayCalculatorScreen.kt'))


SWIFT_PROBE = r'''
import Foundation
var scenarios = 0
var readings: [[String: Any]] = []
func decision(_ canopy: SprayCanopySelection, _ choice: SprayVolumeChoice,
              _ rate: Double? = nil, _ basis: SprayCarrierBasis = .litresPerHectare) -> SprayVolumeDecision {
    SprayVolumeDecisionResolver.decide(canopy: canopy, settings: .defaults,
        rowSpacingMetres: 2.8, choice: choice, customRate: rate, customBasis: basis)
}
precondition(!SprayCanopySelection.unconfirmed.isConfirmed)
precondition(decision(.unconfirmed, .undecided).recommendation == nil)
for type in CanopyType.allCases {
    for size in CanopySize.allCases {
        for density in CanopyDensity.allCases {
            var canopy = SprayCanopySelection.unconfirmed
            canopy.choose(type: type); canopy.choose(size: size); canopy.choose(density: density)
            precondition(!canopy.isConfirmed)
            precondition(decision(canopy, .undecided).recommendation == nil)
            canopy.confirm()
            precondition(canopy.isConfirmed)
            precondition(decision(canopy, .undecided).recommendation != nil)
            precondition(!decision(canopy, .undecided).isResolved)
            let recommended = decision(canopy, .useRecommended)
            precondition(recommended.isResolved && recommended.concentrationFactor == 1)
            readings.append(["type": type.rawValue, "size": size.rawValue,
                "density": density.rawValue, "per100m": recommended.recommendedLitresPer100Metres!])
            for basis in [SprayCarrierBasis.litresPerHectare, .litresPer100Metres] {
                for invalid: Double? in [nil, 0, -1, .nan, .infinity] {
                    precondition(!decision(canopy, .useCustomSprayerRate, invalid, basis).isResolved)
                    scenarios += 1
                }
                let actual = decision(canopy, .useCustomSprayerRate, basis == .litresPerHectare ? 600 : 16.8, basis)
                precondition(actual.isResolved)
                precondition(abs(actual.actualLitresPerHectare! - 600) < 0.000001)
                precondition(abs(actual.actualLitresPer100Metres! - 16.8) < 0.000001)
                scenarios += 1
            }
            canopy.choose(type: type); canopy.choose(size: size); canopy.choose(density: density)
            precondition(canopy.isConfirmed, "Reselecting an unchanged value must retain confirmation")
            canopy.choose(density: density == .low ? .high : .low)
            precondition(!canopy.isConfirmed && decision(canopy, .undecided).recommendation == nil)
            canopy.confirm(); precondition(canopy.isConfirmed)
            canopy.choose(size: size == .small ? .medium : .small)
            precondition(!canopy.isConfirmed)
            canopy.confirm(); canopy.choose(type: type == .vsp ? .sprawl : .vsp)
            precondition(!canopy.isConfirmed)
            scenarios += 1
        }
    }
}
precondition(!SprayCarrierBasis.manualTotalVolume.usesCanopyRecommendation)
for configuration in SprayPassConfiguration.allCases {
    for specification in SprayFullTankSpecification.allCases {
        let intent = SprayPlanningIntent(configuration: configuration, method: .fullTank,
            fullTankSpecification: specification, intendedTankLitres: 600, targetAreaHa: 1,
            calibratedLitresPerHectare: 600)
        let resolution = intent.resolve(selectedAreaHa: 2, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 700)!
        precondition(resolution.intendedLitres == 600 && resolution.plannedAreaHa == 1)
        precondition(abs(resolution.controllerLitresPer100mTravel! - 16.8 * configuration.rowEquivalents) < 0.000001)
        precondition(intent.fullTankExecutionBlocker(resolution: resolution, selectedGrossAreaHa: 2) == nil)
        var invalid = intent; invalid.intendedTankLitres = nil
        precondition(invalid.resolve(selectedAreaHa: 2, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 700) == nil)
        precondition(invalid.fullTankExecutionBlocker(resolution: nil, selectedGrossAreaHa: 2) != nil)
        scenarios += 1
    }
}
print("SWIFT_SCENARIOS=\(scenarios)")
print("READINGS=" + String(data: try JSONSerialization.data(withJSONObject: readings, options: [.sortedKeys]), encoding: .utf8)!)
'''

KOTLIN_PROBE = r'''
import com.rork.vinetrack.data.CanopyWaterRates
import com.rork.vinetrack.data.SprayCalculator
import com.rork.vinetrack.data.spray.*
fun main() {
    var scenarios = 0
    fun decision(canopy: SprayCanopySelection, choice: SprayVolumeChoice,
                 rate: Double? = null, basis: SprayCarrierBasis = SprayCarrierBasis.LITRES_PER_HECTARE): SprayVolumeDecision =
        SprayVolumeDecisionResolver.decide(canopy, canopy.isConfirmed, CanopyWaterRates.defaults,
            2.8, choice, rate, basis)
    check(!SprayCanopySelection.unconfirmed.isConfirmed)
    check(decision(SprayCanopySelection.unconfirmed, SprayVolumeChoice.UNDECIDED).recommendation == null)
    for (type in SprayCalculator.CanopyType.entries) {
        for (size in SprayCalculator.CanopySize.entries) {
            for (density in SprayCalculator.CanopyDensity.entries) {
                var canopy = SprayCanopySelection.unconfirmed.chooseType(type).chooseSize(size).chooseDensity(density)
                check(!canopy.isConfirmed)
                check(decision(canopy, SprayVolumeChoice.UNDECIDED).recommendation == null)
                canopy = canopy.confirm()
                check(canopy.isConfirmed)
                check(decision(canopy, SprayVolumeChoice.UNDECIDED).recommendation != null)
                check(!decision(canopy, SprayVolumeChoice.UNDECIDED).isResolved)
                val recommended = decision(canopy, SprayVolumeChoice.USE_RECOMMENDED)
                check(recommended.isResolved && recommended.concentrationFactor == 1.0)
                println("READING=${type.label}|${size.label}|${density.label}|${recommended.recommendedLitresPer100Metres}")
                for (basis in listOf(SprayCarrierBasis.LITRES_PER_HECTARE, SprayCarrierBasis.LITRES_PER_100_METRES)) {
                    for (invalid in listOf(null, 0.0, -1.0, Double.NaN, Double.POSITIVE_INFINITY)) {
                        check(!decision(canopy, SprayVolumeChoice.USE_CUSTOM_SPRAYER_RATE, invalid, basis).isResolved)
                        scenarios++
                    }
                    val actual = decision(canopy, SprayVolumeChoice.USE_CUSTOM_SPRAYER_RATE,
                        if (basis == SprayCarrierBasis.LITRES_PER_HECTARE) 600.0 else 16.8, basis)
                    check(actual.isResolved)
                    check(kotlin.math.abs(actual.actualLitresPerHectare!! - 600) < 0.000001)
                    check(kotlin.math.abs(actual.actualLitresPer100Metres!! - 16.8) < 0.000001)
                    scenarios++
                }
                canopy = canopy.chooseType(type).chooseSize(size).chooseDensity(density)
                check(canopy.isConfirmed)
                canopy = canopy.chooseDensity(if (density == SprayCalculator.CanopyDensity.LOW) SprayCalculator.CanopyDensity.HIGH else SprayCalculator.CanopyDensity.LOW)
                check(!canopy.isConfirmed && decision(canopy, SprayVolumeChoice.UNDECIDED).recommendation == null)
                canopy = canopy.confirm(); check(canopy.isConfirmed)
                canopy = canopy.chooseSize(if (size == SprayCalculator.CanopySize.SMALL) SprayCalculator.CanopySize.MEDIUM else SprayCalculator.CanopySize.SMALL)
                check(!canopy.isConfirmed)
                canopy = canopy.confirm().chooseType(if (type == SprayCalculator.CanopyType.VSP) SprayCalculator.CanopyType.SPRAWL else SprayCalculator.CanopyType.VSP)
                check(!canopy.isConfirmed)
                scenarios++
            }
        }
    }
    check(!SprayCanopyRequirement.usesSharedModel(SprayCarrierBasis.MANUAL_TOTAL_VOLUME))
    println("KOTLIN_SCENARIOS=$scenarios")
}
'''


class SprayFlowHostTests(unittest.TestCase):
    def test_production_confirmation_volume_models_and_cross_platform_parity(self):
        swift = shutil.which('swiftc')
        kotlin = shutil.which('kotlinc')
        java = shutil.which('java')
        if not all((swift, kotlin, java)):
            self.skipTest('Swift/Kotlin/JVM required; native acceptance remains separate')
        with tempfile.TemporaryDirectory(prefix='vinetrack-spray-human-') as directory:
            temp = Path(directory)
            carrier = read(IOS + 'SprayEngine/SprayCarrierVolume.swift')
            (temp / 'CarrierBasis.swift').write_text('import Foundation\n' + declaration(carrier, 'nonisolated enum SprayCarrierBasis:'))
            # Only the unused record-compliance adapter needs a storage boundary.
            (temp / 'StorageBoundary.swift').write_text('''
struct SprayChemical { let rateBasis: String?; let ratePer100L: Double; let ratePerHa: Double; let name: String }
struct SprayTank { let chemicals: [SprayChemical] }
''')
            (temp / 'main.swift').write_text(SWIFT_PROBE)
            swift_files = [ROOT / 'ios/VineTrack/LegacyImported/Models/CanopyModels.swift'] + [
                ROOT / IOS / 'SprayEngine' / name for name in (
                    'SprayCanopySelection.swift', 'SprayVolumeDecision.swift',
                    'SprayCarrierConversion.swift', 'SprayPlanningIntent.swift')]
            compiled = subprocess.run([swift, *map(str, swift_files), str(temp / 'CarrierBasis.swift'),
                str(temp / 'StorageBoundary.swift'), str(temp / 'main.swift'), '-o', str(temp / 'swift-probe')],
                capture_output=True, text=True, timeout=90)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(temp / 'swift-probe')], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            swift_readings = json.loads(next(line.removeprefix('READINGS=') for line in result.stdout.splitlines() if line.startswith('READINGS=')))
            self.assertIn('SWIFT_SCENARIOS=212', result.stdout)

            rates = read(ANDROID + 'data/CanopyWaterRatesStore.kt')
            calc = read(ANDROID + 'data/SprayCalculator.kt')
            calc_prefix = calc[calc.index('object SprayCalculator {'):calc.index('    /** Whether an operation type uses')]
            (temp / 'CanopyTable.kt').write_text('package com.rork.vinetrack.data\n' +
                declaration(rates, 'data class CanopyWaterRates(') + '\n' + calc_prefix + '\n}\n')
            basis = read(ANDROID + 'data/spray/SprayCarrierVolume.kt')
            operation = read(ANDROID + 'data/spray/SprayTarget.kt')
            (temp / 'HostEnums.kt').write_text('package com.rork.vinetrack.data.spray\nimport kotlinx.serialization.*\n' +
                declaration(basis, 'enum class SprayCarrierBasis(') + '\n' +
                declaration(operation, 'enum class SprayOperationType('))
            (temp / 'SerializationBoundary.kt').write_text('package kotlinx.serialization\nannotation class SerialName(val value: String)\nannotation class Serializable\n')
            (temp / 'Probe.kt').write_text(KOTLIN_PROBE)
            kotlin_files = [ROOT / ANDROID / 'data/spray' / name for name in ('SprayCanopySelection.kt', 'SprayVolumeDecision.kt')]
            compiled = subprocess.run([kotlin, *map(str, kotlin_files), *map(str, temp.glob('*.kt')),
                '-include-runtime', '-d', str(temp / 'kotlin-probe.jar')], capture_output=True, text=True, timeout=90)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([java, '-jar', str(temp / 'kotlin-probe.jar')], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('KOTLIN_SCENARIOS=208', result.stdout)
            kotlin_readings = {}
            for line in result.stdout.splitlines():
                if line.startswith('READING='):
                    kind, size, density, value = line.removeprefix('READING=').split('|')
                    kotlin_readings[(kind, size, density)] = float(value)
            self.assertEqual(len(swift_readings), 16)
            self.assertEqual(len(kotlin_readings), 16)
            for reading in swift_readings:
                self.assertEqual(reading['per100m'], kotlin_readings[(reading['type'], reading['size'], reading['density'])])
            print('Verified 212 Swift + 208 Kotlin model scenarios; all 16 canopy recommendations match. UI/device acceptance not claimed.')


if __name__ == '__main__':
    unittest.main()
