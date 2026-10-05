"""Focused pricing-authority source guards; does not deploy SQL or exercise native UI."""
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
android = root / 'android-vinetrack/app/src/main/java/com/rork/vinetrack'
ios = root / 'ios/VineTrack'

def text(base, path):
    return (base / path).read_text()

screen = text(android, 'ui/screens/SpraysScreen.kt')
for forbidden in ['Text("Cost per unit")', 'saved.costPerUnit', 'chem.costPerTank', 'tank.totalChemicalCost', 'record.totalChemicalCost', 'chem.costPerUnit']:
    assert forbidden not in screen, forbidden
assert 'SprayChemicalPricingPolicy.roundTripLegacyCost' in screen
assert 'historicalCostPerUnit' in screen and 'costPerUnit.toString()' in screen
assert 'productUnchanged = savedChemicalId == loadedSavedChemicalId' in screen
assert 'quantitiesUnchanged = ratePerHa == loadedRate && volumePerTank == loadedVolume' in screen
assert 'isNewApplication = refreshSnapshots' in screen
assert 'TripCostEstimator.estimate' in screen and 'chemicalPrices = chemicalPrices' in screen
assert 'chem.pricingBases.joinToString' in screen
assert 'loadTripChemicalPrices' in screen
print('PASS Android editor: no price input/prefill; exact historical compatibility preservation policy; detail uses estimator and pricing provenance.')

for base, folder, suffix in [(ios, 'LegacyImported/Exports', '*.swift'), (android, 'data', '*Exporter.kt')]:
    for path in (base / folder).rglob(suffix):
        contents = path.read_text()
        for forbidden in ['chemical.costPerUnit', 'chem.costPerUnit', 'chemical.costPerTank', 'record.totalChemicalCost', 'record.costPerHectare', 'saved.costPerUnit', 'saved.purchase']:
            assert forbidden not in contents, (path, forbidden)
print('PASS export boundaries: no direct stored spray/library financial reads.')

pdf = text(ios, 'LegacyImported/Exports/Spray/SprayRecordPDFService.swift')
assert 'Chemical Subtotal' not in pdf
assert 'tripCostResult?.chemical' in pdf and 'chemical.pricingBases' in pdf
assert '} else if includeCostings, let r = tripCostResult' in pdf
assert 'Season purchase cost unavailable / incomplete' in pdf
for filename in ['TripPdfExporter.kt', 'TripCsvExporter.kt', 'SprayRecordPdfExporter.kt', 'SprayProgramCsvExporter.kt', 'SprayProgramPdfExporter.kt']:
    contents = text(android, 'data/' + filename)
    assert 'chemicalPrices = chemicalPrices' in contents, filename
    assert 'pricingBases' in contents, filename
for filename in ['SprayProgramCSVService.swift', 'SprayProgramExportService.swift']:
    contents = text(ios, 'LegacyImported/Exports/Spray/' + filename)
    assert 'chemicalPrices: chemicalPrices' in contents, filename
    assert 'pricingBases' in contents, filename
assert 'filter { !$0.hasSuffix("Cost Per Unit") }' in text(ios, 'LegacyImported/Exports/Spray/SprayProgramCSVService.swift')
assert 'filterNot { it.endsWith("Cost Per Unit") }' in text(android, 'data/SprayProgramCsvExporter.kt')
print('PASS PDF/CSV: supplied seasonal authority, explicit provenance, no duplicate snapshot subtotal, role-independent unit-price columns removed.')
assert 'costPerUnit = 0.0' in text(android, 'ui/AppViewModel.kt')
assert 'saved.costPerUnit' not in text(android, 'data/SprayProgramCsvImporter.kt')
assert 'costPerUnit: 0,' in text(ios, 'LegacyImported/Exports/Spray/SprayProgramCSVService.swift')
for base, name in [(ios, 'LegacyImported/Views/Fertiliser/FertiliserCalculatorView.swift'), (android, 'ui/screens/FertiliserCalculatorScreen.kt')]:
    assert '.pricePerPack' not in text(base, name), name
print('PASS imports and other chemical calculators: no new imported price snapshot or Saved Chemical pack-price authority.')

# Full reference inventory, excluding separate SavedInput/seeding, purchases of fuel,
# grape purchasers, subscription APIs and the synthetic import-template prose.
pattern = re.compile(r'\b(?:costPerUnit|costPerTank|totalChemicalCost|pricePerPack|price_per_pack|costPerBaseUnit|costPerPackUnit)\b|\.purchase\b')
excluded = {'SavedInput.kt', 'BackendSavedInput.swift', 'SeedingDetails.kt', 'PaywallView.swift', 'SubscriptionService.swift', 'SavedInput.swift', 'SavedInputRepository.kt', 'SavedInputRepository.swift', 'SavedInputsScreen.kt', 'SavedInputsManagementView.swift', 'SeedingDetails.swift', 'SeedingModels.kt', 'StartTripSheet.swift', 'GrapeAllocationView.swift', 'GrapeAllocationScreen.kt', 'GrapeAllocation.swift', 'GrapeAllocationLogic.swift', 'GrapeAllocationFormLogic.swift', 'EquipmentManagementView.swift', 'RevenueCatManager.kt', 'ChemicalInventoryActionsView.swift', 'RegionFormatter.kt'}
compatibility = {'SavedChemical.swift', 'Models.kt', 'BackendManagement.swift', 'SavedChemicalRepository.kt', 'SprayRecord.swift', 'ChemicalReviewSession.swift', 'ChemicalStoreMatching.kt', 'ChemicalSearchV2View.swift', 'ChemicalSearchV2Sheet.kt', 'ChemicalsScreen.kt', 'SprayPresetsView.swift', 'SprayProgramStepDraft.swift', 'SprayProgramStepDraft.kt', 'FertiliserModels.swift', 'SprayProgramCSVService.swift', 'SprayProgramCsvImporter.kt'}
for base, extension in [(ios, '*.swift'), (android, '*.kt')]:
    references = {}
    for path in sorted(base.rglob(extension)):
        if path.name in excluded:
            continue
        matches = [(n, line.strip()) for n, line in enumerate(path.read_text().splitlines(), 1) if pattern.search(line) and 'revenueCat.purchase' not in line]
        if not matches:
            continue
        # Mixed-domain files are listed rather than silently skipped.
        if path.name in {'TripCostService.swift', 'TripCostEstimator.kt'}:
            category = 'historical legacy fallback (chemical); separate seed/input costing unchanged'
        elif path.name in {'SpraysScreen.kt', 'SprayRecordFormView.swift'}:
            category = 'compatibility round-trip only'
        elif path.name in {'FertiliserCalculatorView.swift', 'FertiliserModels.kt'}:
            category = 'standalone manually entered estimate only; never Saved Chemical pricing'
        elif path.name in compatibility:
            category = 'compatibility decode/storage or retired helper only'
        elif path.name in {'TripsScreen.kt', 'CostingSetupWizardSection.swift', 'AppViewModel.kt'}:
            category = 'separate seed/input domain or zero-price new spray writes'
        else:
            category = 'canonical seasonal calculator input/output or zero-price creation'
        references[str(path.relative_to(root))] = (category, matches)
    print('\n' + str(base.relative_to(root)) + ' reference inventory:')
    for path, (category, matches) in references.items():
        print(path + ' | ' + category + ' | lines ' + ', '.join(str(n) for n, _ in matches))
print('\nAll focused pricing-authority source guards passed. Native rendering/interaction requires native tests.')
