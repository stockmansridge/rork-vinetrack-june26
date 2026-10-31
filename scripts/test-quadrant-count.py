#!/usr/bin/env python3
"""Focused source-derived host checks, not native UI/build or device acceptance.
Uses the real Swift payload, ViewModel, save boundary and estimate implementation.
Kotlin checks use real model/save/estimate code without serialization annotations;
Kotlin JSON round-trip and native UI require the normal platform test environment.
Only platform infrastructure is replaced by small host stubs. No project build.
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SWIFT = ROOT / 'ios/VineTrack'
KOTLIN = ROOT / 'android-vinetrack/app/src/main/java/com/rork/vinetrack'

def balanced(source, marker):
    start = source.index(marker)
    opening = source.index('{', start + len(marker))
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

def kotlin_clean(source):
    source = re.sub(r'^\s*(package|import) .*\n', '', source, flags=re.M)
    source = re.sub(r'@Serializable(?:\([^\n]*\))?\s*', '', source)
    return re.sub(r'@SerialName\([^\n]*?\)\s*', '', source)

swift_stubs = '''
import Foundation
struct CLLocationCoordinate2D { let latitude: Double; let longitude: Double }
struct CoordinatePoint: Codable, Sendable, Hashable { let latitude: Double; let longitude: Double }
struct PaddockRow { let number: Int; let startPoint: CoordinatePoint; let endPoint: CoordinatePoint }
struct Planting { let percent: Double; let name: String?; let varietyKey: String? }
struct Paddock {
 let id: UUID; var name = "Block"; var areaHectares = 1.0
 var authoritativeVineCount = 1000; var effectiveVineCount = 1000
 var polygonPoints: [CoordinatePoint] = []; var rows: [PaddockRow] = []; var rowDirection = 0.0
 var varietyAllocations = [Planting(percent: 100, name: "Shiraz", varietyKey: "shiraz")]
}
struct DamageRecord: Sendable {}
@MainActor final class FakeYieldRepo {
 var fail = false; var saved: [YieldEstimationSession] = []
 func saveLocalSession(_ session: YieldEstimationSession, at: Date) throws {
   if fail { throw NSError(domain: "fixture", code: 1) }; saved.append(session)
 }
}
'''
swift_tests = r'''
@main struct QuadrantHostChecks {
 @MainActor static func main() throws {
  var passed = 0
  func check(_ ok: Bool, _ label: String) {
    precondition(ok, label); passed += 1
  }
  func near(_ a: Double, _ b: Double) -> Bool { abs(a-b) < 1e-10 }
  func make(_ raw: Double, _ length: Double = 60, _ spacing: Double? = 100, _ admin: Bool = true) -> QuadrantCountMeasurement? {
    .make(rawBunchCount: raw, sectionLengthCm: length, vineSpacingCm: spacing, isSystemAdmin: admin)
  }
  let a = make(12)!, b = make(7)!, c = make(12, 50)!
  check(near(a.bunchesPerVine, 20), "60cm and 1m spacing")
  check(near(b.bunchesPerVine, 35.0/3.0), "fractional result retained")
  check(near(c.bunchesPerVine, 24), "editable length")
  check(near(make(12, 60, 240)!.bunchesPerVine, 48), "different block spacing")
  check(make(0)!.bunchesPerVine == 0, "zero count valid")
  for raw in [-1.0, 1.5, .infinity, .nan] { check(make(raw) == nil, "invalid raw count") }
  for length in [0.0, -1, .infinity, .nan] { check(make(12, length) == nil, "invalid length") }
  for spacing: Double? in [nil, 0, -1, .infinity, .nan] { check(make(12, 60, spacing) == nil, "invalid spacing") }
  check(make(12, 60, 100, false) == nil, "nonadmin factory")
  check(make(1e300, 1e-200, 1e300) == nil, "overflow blocked")
  let vid=UUID(), block=UUID()
  let model = YieldEstimationViewModel()
  model.startNewTrip(); let firstID = model.sessionId
  model.countMethod="quadrant"; model.selectedPaddockIds=[block]
  model.sampleSites = [SampleSite(paddockId: block, rowNumber: 1, latitude: 1, longitude: 2, siteIndex: 1),
                       SampleSite(paddockId: block, rowNumber: 2, latitude: 3, longitude: 4, siteIndex: 2)]
  let s1=model.sampleSites[0].id, s2=model.sampleSites[1].id
  check(!model.recordQuadrantCount(siteId:s1,measurement:a,recordedBy:"test",isSystemAdmin:false), "nonadmin record denied")
  check(model.recordQuadrantCount(siteId:s1,measurement:a,recordedBy:"test",isSystemAdmin:true), "first recording")
  check(model.recordQuadrantCount(siteId:s2,measurement:c,recordedBy:"test",isSystemAdmin:true), "second length recording")
  model.recordBunchCount(siteId:s1,bunchesPerVine:999,recordedBy:"legacy")
  check(model.sampleSites[0].bunchCountEntry?.quadrant == a, "legacy writer cannot strip metadata")
  let session=model.toSession(vineyardId:vid,samplesPerHectare:20)
  check(session.id == firstID && session.isQuadrantCount && session.quadrantSectionLengthCm == 50, "session identity and default")
  let encoded=try JSONEncoder().encode(session)
  let decoded=try JSONDecoder().decode(YieldEstimationSession.self,from:encoded)
  check(decoded.sampleSites[0].bunchCountEntry?.quadrant == a && decoded.sampleSites[1].bunchCountEntry?.quadrant == c, "JSON measurement roundtrip")
  check(decoded.sampleSites[1].rowNumber == 2 && decoded.sampleSites[1].latitude == 3, "site metadata roundtrip")
  let restored=YieldEstimationViewModel();restored.loadSession(decoded)
  check(restored.isQuadrantCount && restored.quadrantSectionLengthCm == 50 && restored.sessionId == firstID, "resume metadata")
  let legacy=YieldEstimationSession(vineyardId:vid)
  let legacyJson=try JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy)) as! [String:Any]
  check(legacyJson["countMethod"] == nil && legacyJson["quadrantSectionLengthCm"] == nil, "legacy encoding unchanged")
  let oldJson = "{\"id\":\"\(UUID())\",\"vineyardId\":\"\(vid)\",\"sampleSites\":[]}"
  check(!(try JSONDecoder().decode(YieldEstimationSession.self,from:Data(oldJson.utf8))).isQuadrantCount,"old payload decodes")
  let oldEntry=try JSONDecoder().decode(BunchCountEntry.self,from:Data("{\"bunchesPerVine\":9,\"recordedAt\":0,\"recordedBy\":\"a\"}".utf8))
  check(oldEntry.quadrant == nil && oldEntry.bunchesPerVine == 9,"old count decodes")
  var detected=decoded;detected.countMethod=nil
  check(detected.isQuadrantCount,"sample metadata also identifies method")
  let paddock=Paddock(id:block)
  let weight=YieldMasterWeight(bunchWeightGrams:150,source:"variety_default",recordId:UUID(),varietyKey:"shiraz")
  let weights=[CurrentYieldEstimate.key(blockId:block,varietyKey:"shiraz"):weight]
  let estimate=CurrentYieldEstimate.trip(session:decoded,paddocks:[paddock],weights:weights)
  check(near(estimate.blocks[0].averageBunches!,22),"normalize each sample before averaging")
  check(near(estimate.totalTonnes!,3.3),"existing yield estimate uses normalized values")
  check(estimate.countMethod == "Quadrant Count","method source label")
  let reuse=BunchCountTripLogic.reusableRoute(sessions:[decoded],selectedPaddockIds:[block])!
  check(reuse.sites.allSatisfy { $0.bunchCountEntry == nil } && reuse.sites[0].id == s1,"route reuse strips counts not identity")
  model.markCompleted(paddocks:[paddock])
  check(!model.recordQuadrantCount(siteId:s1,measurement:b,recordedBy:"test",isSystemAdmin:true),"completed samples immutable")
  model.startNewTrip()
  check(!model.isQuadrantCount && model.quadrantSectionLengthCm == 60 && model.sessionId != firstID,"new full-vine trip resets method")
  let store=StoreProbe();store.selectedVineyardId=vid
  check(!store.saveYieldSession(decoded),"durable save rejects nonadmin")
  check(store.saveYieldSession(decoded,isSystemAdmin:true),"durable save accepts admin")
  var stripped=decoded;stripped.countMethod=nil;stripped.sampleSites=[]
  check(!store.saveYieldSession(stripped,isSystemAdmin:true),"save cannot strip existing method")
  store.yieldRepo.fail=true
  check(!store.saveYieldSession(decoded,isSystemAdmin:true),"disk failure not success")
  store.yieldRepo.fail=false
  check(store.saveYieldSession(legacy),"legacy save remains available")
  print("Swift source-derived checks passed: \(passed)")
 }
}
'''

kotlin_stubs='''
import java.time.Instant
import java.util.UUID
import kotlin.math.abs
data class CoordinatePoint(val latitude:Double,val longitude:Double)
data class Planting(val displayPercent:Double?=100.0,val displayName:String?="Shiraz",val varietyKey:String?="shiraz")
data class Paddock(val id:String,val name:String="Block",val authoritativeVineCount:Int=1000,val effectiveVineCount:Int=1000,
 val areaHectares:Double=1.0,val varietyAllocations:List<Planting>?=listOf(Planting()))
data class Ui(val selectedVineyardId:String?,val isSystemAdmin:Boolean=false,val isOnline:Boolean=false,
 val yieldSessions:List<YieldEstimationSession> = emptyList(),val yieldSessionError:String?=null)
class State(var value:Ui) { fun update(block:(Ui)->Ui) { value=block(value) } }
class FakeSync { var fail=false;var calls=0;fun enqueue(session:YieldEstimationSession,at:String) { if(fail) error("disk");calls++ } }
'''
kotlin_tests='''
fun main() {
 var passed=0
 fun verify(value:Boolean,label:String) { check(value) { label };passed++ }
 fun make(raw:Double,length:Double=60.0,spacing:Double?=100.0,admin:Boolean=true)=QuadrantCountMeasurement.make(raw,length,spacing,admin)
 fun near(a:Double,b:Double)=abs(a-b)<1e-10
 val a=make(12.0)!!;val b=make(7.0)!!;val c=make(12.0,50.0)!!
 verify(near(a.bunchesPerVine,20.0),"default section")
 verify(near(b.bunchesPerVine,35.0/3.0),"fraction retained")
 verify(near(c.bunchesPerVine,24.0),"custom section")
 verify(near(make(12.0,60.0,240.0)!!.bunchesPerVine,48.0),"block spacing")
 verify(make(0.0)!!.bunchesPerVine==0.0,"zero count")
 for(raw in listOf(-1.0,1.5,Double.POSITIVE_INFINITY,Double.NaN)) verify(make(raw)==null,"bad raw")
 for(length in listOf(0.0,-1.0,Double.POSITIVE_INFINITY,Double.NaN)) verify(make(12.0,length)==null,"bad section")
 for(spacing in listOf(null,0.0,-1.0,Double.POSITIVE_INFINITY,Double.NaN)) verify(make(12.0,60.0,spacing)==null,"bad spacing")
 verify(make(12.0,60.0,100.0,false)==null,"admin check")
 verify(make(1e300,1e-200,1e300)==null,"overflow")
 val legacy=YieldEstimationSession("legacy","vineyard","2026-10-30T12:00:00Z")
 verify(!legacy.isQuadrantCount && legacy.countMethod==null,"legacy defaults")
 val sites=listOf(SampleSite("s1","block",rowNumber=1,latitude=1.0,longitude=2.0,siteIndex=1),
   SampleSite("s2","block",rowNumber=2,latitude=3.0,longitude=4.0,siteIndex=2))
 val trip=legacy.copy(id="quadrant",countMethod="quadrant",quadrantSectionLengthCm=60.0,selectedPaddockIds=listOf("block"),sampleSites=sites)
   .recordQuadrant("s1",a,"tester").recordQuadrant("s2",c,"tester")
 verify(trip.sampleSites[0].bunchCountEntry!!.quadrant==a,"raw metadata preserved")
 verify(trip.sampleSites[1].latitude==3.0 && trip.quadrantSectionLengthCm==50.0,"sample identity/default")
 verify(trip.copy(countMethod=null).isQuadrantCount,"sample metadata identifies method")
 verify(trip.recordBunch("s1",999.0,"legacy")==trip,"legacy writer cannot strip")
 verify(trip.copy(isCompleted=true).recordQuadrant("s1",b,"tester").sampleSites==trip.sampleSites,"completed immutable")
 val block=Paddock("block")
 val weights=mapOf(CurrentYieldEstimate.key("block","shiraz") to YieldMasterWeight(150.0,"variety_default","weight","shiraz"))
 val estimate=CurrentYieldEstimate.trip(trip,listOf(block),weights)
 verify(near(estimate.blocks[0].averageBunches!!,22.0),"per-sample normalization")
 verify(near(estimate.totalTonnes!!,3.3),"existing yield calculation")
 verify(estimate.countMethod=="Quadrant Count","method label")
 val probe=StoreProbe();var accepted=true
 probe.saveYieldSession(trip) { accepted=it };verify(!accepted && probe.yieldSessionSaveSync.calls==0,"nonadmin save blocked")
 probe._ui.update { it.copy(isSystemAdmin=true) }
 probe.saveYieldSession(trip) { accepted=it };verify(accepted && probe._ui.value.yieldSessions.single()==trip,"admin durable save")
 probe.saveYieldSession(trip.copy(countMethod=null,sampleSites=emptyList())) { accepted=it };verify(!accepted,"method stripping blocked")
 probe.yieldSessionSaveSync.fail=true
 probe.saveYieldSession(trip) { accepted=it };verify(!accepted,"disk failure retained")
 probe.yieldSessionSaveSync.fail=false;probe._ui.update { it.copy(isSystemAdmin=false) }
 probe.saveYieldSession(legacy) { accepted=it };verify(accepted,"full-vine save unchanged")
 println("Kotlin source-derived checks passed: $passed")
}
'''

def main():
 with tempfile.TemporaryDirectory(prefix='quadrant-check-') as td:
  temp=Path(td)
  models=(SWIFT/'LegacyImported/Models/YieldEstimationModels.swift').read_text()
  selected=models[:models.index('nonisolated enum DamageType')].replace('import CoreLocation','')
  selected += '\n'+balanced(models,'nonisolated struct QuadrantCountMeasurement')
  vm=(SWIFT/'LegacyImported/Views/Yield/YieldEstimationViewModel.swift').read_text().replace('import CoreLocation','').replace('@Observable','')
  logic=balanced((SWIFT/'LegacyImported/Models/YieldVintageReport.swift').read_text(),'nonisolated enum BunchCountTripLogic')
  saver=balanced((SWIFT/'LegacyImported/Services/MigratedDataStore+Yield.swift').read_text(),'func saveYieldSession(')
  save_probe='@MainActor final class StoreProbe { var selectedVineyardId: UUID?; var yieldSessions:[YieldEstimationSession]=[];let yieldRepo=FakeYieldRepo();var onYieldSessionChanged:((UUID)->Void)?\n'+saver+'\n}'
  swift_source='\n'.join([swift_stubs,selected,vm,logic,(SWIFT/'LegacyImported/Models/CurrentYieldEstimate.swift').read_text(),save_probe,swift_tests])
  (temp/'Checks.swift').write_text(swift_source)
  subprocess.run(['swiftc','-parse-as-library',str(temp/'Checks.swift'),'-o',str(temp/'swift-checks')],check=True)
  subprocess.run([str(temp/'swift-checks')],check=True)
  models=(KOTLIN/'data/model/YieldEstimationSession.kt').read_text()
  models=models[models.index('@Serializable\ndata class BunchCountEntry'):]
  start=models.index('object BlockBunchWeightsSerializer')
  finish=models.index('/**\n * A single working',start)
  models=models[:start]+models[finish:]
  # The serializer decorator is dropped, not the production model fields/body.
  models=kotlin_clean(models)
  ui=(KOTLIN/'ui/screens/YieldEstimationScreen.kt').read_text()
  # recordBunch has an expression body containing nested lambdas; delimit by comment.
  start=ui.index('private fun YieldEstimationSession.recordBunch(')
  record_full=ui[start:ui.index('// =============================================================================',start)]
  record_quad=balanced(ui,'private fun YieldEstimationSession.recordQuadrant(')
  saver=balanced((KOTLIN/'ui/AppViewModel.kt').read_text(),'fun saveYieldSession(session: YieldEstimationSession, onResult: (Boolean) -> Unit = {})')
  probe='class StoreProbe { val _ui=State(Ui("vineyard")); val yieldSessionSaveSync=FakeSync();fun replayPendingYieldSessions() {}\n'+saver+'\n}'
  source='\n'.join([kotlin_stubs,models,kotlin_clean((KOTLIN/'data/CurrentYieldEstimate.kt').read_text()),record_full,record_quad,probe,kotlin_tests])
  (temp/'Checks.kt').write_text(source)
  subprocess.run(['kotlinc',str(temp/'Checks.kt'),'-include-runtime','-d',str(temp/'checks.jar')],check=True)
  subprocess.run(['java','-jar',str(temp/'checks.jar')],check=True)
  files=[str(p) for p in (SWIFT/'LegacyImported/Views/Yield').glob('*.swift')]
  subprocess.run(['swiftc','-frontend','-parse']+files,check=True)
  print('Swift Yield UI source parse: PASS (not a native UI typecheck/build)')

if __name__=='__main__': main()
