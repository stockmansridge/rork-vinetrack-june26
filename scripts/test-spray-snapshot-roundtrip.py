#!/usr/bin/env python3
"""Run bounded production Swift snapshot/tank codecs and recipe matching.
Only unexercised metadata types/formatting are stubs. Not a SwiftUI/native app test.
"""
from pathlib import Path
import argparse, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(); p.add_argument('--swiftc', default='swiftc'); args = p.parse_args()
def read(path): return (ROOT / path).read_text()
snapshot_path = 'ios/VineTrack/App/ChemicalIntelligence/ChemicalLineSnapshot.swift'
snapshot = read(snapshot_path).split('    /// Records what was actually applied')[0]
snapshot += read(snapshot_path).split('    /// Whether this snapshot carries anything')[1].split('    /// Freeze a saved chemical')[0].split('\n',1)[1] + '\n}\n'
tanks = read('ios/VineTrack/LegacyImported/Models/SprayRecord.swift').split('nonisolated struct SprayTank:')[1].split('nonisolated enum WindDirection:')[0]
tanks = 'nonisolated struct SprayTank:' + tanks
units = read('ios/VineTrack/LegacyImported/Models/SavedChemical.swift').split('nonisolated enum ChemicalRateBasis:')[0]
basis = read('ios/VineTrack/App/SprayEngine/SprayProductRateBasis.swift').split('/// The measured application')[0]
helper = read('ios/VineTrack/LegacyImported/Models/SprayInitialTankAmounts.swift').split('/// Retained handoff')[0]
stubs = '''
import Foundation
nonisolated struct ChemicalActiveIngredient: Codable, Sendable, Hashable { var name: String }
nonisolated enum ChemicalVerificationStatus: String, Codable, Sendable { case unverified, verified }
nonisolated enum ChemicalResistanceState: String, Codable, Sendable { case classified, unresolved; case notApplicable = "not_applicable" }
nonisolated struct ChemicalLabelRate: Codable, Sendable, Hashable { var id: String }
nonisolated struct ChemicalRegisteredUse: Codable, Sendable, Hashable { var id: String }
nonisolated enum ChemicalIntelligence { static let currentSchemaVersion = 1 }
nonisolated enum AuthoritativeActivityGroups { static let tableVersion = 1 }
nonisolated enum StoredChemicalDefaultRate { static let entryManual = "manual" }
nonisolated struct RegionFormatter { func formatSprayRate(perHectare: Double, unitLabel: String) -> String { "unused" } }
'''
tests = '''
var checks = 0
func check(_ passed: Bool, _ message: String) { precondition(passed, message); checks += 1 }
var chemical = SprayChemical(name: "Frozen product", volumePerTank: 701.592075893, unit: .kilograms,
    chemicalSnapshot: ChemicalLineSnapshot(resistanceClassificationState: .classified,
        capturedAt: Date(timeIntervalSince1970: 1790000000.123456)))
let tank = SprayTank(tankNumber: 1, waterVolume: 343.8, chemicals: [chemical])
let bytes = try JSONEncoder().encode(tank)
let loaded = try JSONDecoder().decode(SprayTank.self, from: bytes)
check(tank != loaded, "Reproduce Date precision difference across production codec")
check(loaded.chemicals[0].chemicalSnapshot?.resistanceClassificationState == .classified, "Classification persisted")
check(SprayInitialTankAmounts.samePersistedRecipe(tank, loaded), "Same persisted recipe")
check(SprayInitialTankAmounts.samePersistedRecipe(loaded, tank), "Symmetric comparison")
check(!SprayInitialTankAmounts.samePersistedRecipe(nil, loaded), "Missing recipe denied")
var changed = loaded; changed.waterVolume += 0.001
check(!SprayInitialTankAmounts.samePersistedRecipe(tank, changed), "Water change denied")
changed = loaded; changed.chemicals[0].volumePerTank += 0.001
check(!SprayInitialTankAmounts.samePersistedRecipe(tank, changed), "Chemical change denied")
changed = loaded; changed.chemicals[0].chemicalSnapshot?.resistanceClassificationState = nil
check(!SprayInitialTankAmounts.samePersistedRecipe(tank, changed), "Dropped classification not masked")
changed = loaded; changed.chemicals[0].chemicalSnapshot?.capturedAt?.addTimeInterval(0.01)
check(!SprayInitialTankAmounts.samePersistedRecipe(tank, changed), "Different capture time denied")
changed = loaded; changed.chemicals[0].name = "Other"
check(!SprayInitialTankAmounts.samePersistedRecipe(tank, changed), "Name change denied")
let otherID = SprayTank(waterVolume: loaded.waterVolume, chemicals: loaded.chemicals)
check(!SprayInitialTankAmounts.samePersistedRecipe(tank, otherID), "Other tank denied")
let legacy = try JSONDecoder().decode(ChemicalLineSnapshot.self, from: Data("{}".utf8))
check(legacy.resistanceClassificationState == nil, "Legacy remains unknown")
let zero = SprayInitialTankAmounts(tankId: tank.id, tankNumber: 1, waterLitres: 344, chemicalBaseAmounts: [chemical.id: 0])
check(zero.isValid(for: loaded), "Explicit zero chemical remains valid")
let missing = SprayInitialTankAmounts(tankId: tank.id, tankNumber: 1, waterLitres: 344, chemicalBaseAmounts: [:])
check(!missing.isValid(for: loaded), "Missing quantity remains invalid")
print("\\(checks) production-codec checks passed")
'''
with tempfile.TemporaryDirectory(prefix='spray-codec-') as tmp:
    src = Path(tmp)/'main.swift'; exe = Path(tmp)/'run'
    src.write_text(stubs + units + basis + snapshot + tanks + helper + tests)
    subprocess.run([args.swiftc, '-swift-version', '5', str(src), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
