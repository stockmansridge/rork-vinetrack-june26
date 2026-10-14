"""Source-wiring regression checks; these do not replace rendered device navigation tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ProgramStepCreationRoutes(unittest.TestCase):
    def test_ios_add_and_empty_state_share_canonical_creator(self):
        view = (ROOT / "ios/VineTrack/LegacyImported/Views/Spray/SprayProgramView.swift").read_text()
        route = view.split('.sheet(isPresented: $showProgramStepForm)', 1)[1].split('.sheet(isPresented: $showManualRecordForm)', 1)[0]
        self.assertIn("SprayProgramStepEditView(vineyardId: vineyardId)", route)
        self.assertNotIn("SprayRecordFormView", route)
        self.assertNotIn("createsProgramStep", route)
        self.assertEqual(view.count("showProgramStepForm = true"), 2)
        editor = (ROOT / "ios/VineTrack/App/SprayProgram/SprayProgramStepEditView.swift").read_text()
        self.assertIn('Picker("Method", selection: $draft.operationType)', editor)
        self.assertIn("init(vineyardId: UUID", editor)
        self.assertIn("portalTemplates.createProgramStep(draft: draft", editor)
        self.assertIn("SprayLineChemicalPicker(", editor)
        detail = (ROOT / "ios/VineTrack/App/SprayProgram/SprayProgramStepDetailView.swift").read_text()
        self.assertIn('"Apply via Irrigation"', detail)

    def test_android_add_and_empty_state_share_canonical_creator(self):
        view = (ROOT / "android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/SpraysScreen.kt").read_text()
        route = view.split("if (creatingTemplate)", 1)[1].split("prefillFromTemplate?.let", 1)[0]
        self.assertIn("SprayProgramStepEditSheet(vm = vm, state = state", route)
        self.assertNotIn("SpraySheet(", route)
        self.assertNotIn("asTemplate", route)
        self.assertIn("onAction = onAddTemplate", view)
        self.assertIn("onClick = { addMenu = false; onAddTemplate() }", view)
        editor = (ROOT / "android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/SprayProgramStepEditSheet.kt").read_text()
        self.assertIn('label = "Method"', editor)
        self.assertIn("record: SprayRecord? = null", editor)
        self.assertIn("vm.createProgramStep(d, creationVineyardId)", editor)
        self.assertIn("SprayProductPickerDialog(", editor)
        detail = (ROOT / "android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/SprayProgramStepDetailScreen.kt").read_text()
        self.assertIn('"Apply via Irrigation"', detail)


if __name__ == "__main__":
    unittest.main()
