"""Supplementary source guards; behavioral/native tests remain required."""
from pathlib import Path
import unittest
R=Path(__file__).resolve().parents[2]
class RepairWiring(unittest.TestCase):
    def test_active_deletion_resolver_keeps_rork_verification_only_path(self):
        s=(R/'ios/VineTrack/Backend/Repositories/SupabaseTripSyncRepository.swift').read_text()
        start=s.index('    private func resolveDeletion(')
        s=s[start:s.index('    private func deletionRequest(',start)]
        for required in ['rest/v1/rpc/confirm_trip_absence_v1', 'receipt.requireConfirmation', 'verificationOnly', 'accountGeneration == session.incarnation', 'Task.checkCancellation()', 'SERVER_ABSENCE_VERIFIED:']:
            self.assertIn(required,s)
        i=s.index('let afterReceipt')
        self.assertIn('deletionAuthority.requireWrite',s[i:s.index('return "SERVER_ABSENCE_VERIFIED:',i)])
    def test_trip_service_has_both_recovery_routes_and_exact_retirement(self):
        s=(R/'ios/VineTrack/Backend/Sync/TripSyncService.swift').read_text()
        for text in ['self.repository.resolveDeletion(scope, isCurrent: scopeCurrent)', 'self.repository.reverifyDeletion(scope, isCurrent: scopeCurrent)', 'try metadata.clearDeletedRevision(tripId, at: timestamp)']:
            self.assertIn(text,s)
    def test_full_sweep_includes_weights_stale_errors_and_interrupt_fence(self):
        s=(R/'ios/VineTrack/App/NewMainTabView.swift').read_text()
        self.assertIn('YieldMasterWeightCache.shared.synchronize(vineyardId: vineyardId, paddocks: store.paddocks)',s)
        self.assertIn('YieldMasterWeightCache.shared.syncError(vineyardId: store.selectedVineyardId)',s)
        self.assertIn('!sweepAccountIsCurrent()',s)
        self.assertIn('if syncStatusCenter.isSyncing {',s)
    def test_rork_retained_spray_projection_is_preserved(self):
        s=(R/'ios/VineTrack/App/BackendSettingsView.swift').read_text()
        self.assertIn('tripSync.retainedState.summary',s)
        self.assertIn('Trip deletions retained.',s)
    def test_android_full_load_refreshes_once_and_cache_notification_does_not_fetch(self):
        s=(R/'android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt').read_text()
        self.assertEqual(s.count('.refresh(vineyardId, _ui.value.paddocks)'),1)
        s=(R/'android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/CurrentYieldEstimateSummary.kt').read_text()
        start=s.index('LaunchedEffect(scope, cacheRevision)'); end=s.index('LaunchedEffect(scope, state.paddocks',start)
        self.assertIn('repository.cached',s[start:end]); self.assertNotIn('repository.refresh',s[start:end])
if __name__=='__main__': unittest.main()
