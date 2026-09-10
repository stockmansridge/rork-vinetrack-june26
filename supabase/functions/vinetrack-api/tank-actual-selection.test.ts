import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  areSprayTankActualsComplete,
  buildSprayActualResponse,
  buildTankActualIdentity,
  mapSprayActualTanks,
  resolveSprayTankActualRows,
  type TankActualIdentity,
  type TankActualRow,
} from "./tank-actual-validation.ts";

const fixtureUrl = new URL("../../../ios/VineTrackTests/Fixtures/spray_tank_actual_selection_v1.json", import.meta.url);
const fixture = JSON.parse(await Deno.readTextFile(fixtureUrl));
const planned = [fixture.plannedTank];
const base = fixture.actuals[0] as TankActualRow;
const identity: TankActualIdentity = {
  vineyardId: fixture.vineyardId,
  sprayRecordId: fixture.sprayRecordId,
  tripId: fixture.tripId,
  sessionIdsByTank: new Map([[1, new Set([fixture.sessions[0].id])]]),
  isManualEntry: false,
};

Deno.test("exact session control resolves and missing authoritative session does not", () => {
  assertEquals(resolveSprayTankActualRows(planned, [base], identity).get(1)?.id, base.id);
  assertEquals(areSprayTankActualsComplete(planned, [base], identity), true);
  assertEquals(resolveSprayTankActualRows(planned, [base], { ...identity, sessionIdsByTank: new Map() }).size, 0);
  assertEquals(areSprayTankActualsComplete(planned, [base], { ...identity, sessionIdsByTank: new Map() }), false);
});

Deno.test("unmatched tank and unknown session evidence are incomplete", () => {
  const extra = { ...base, id: "extra-tank", tank_number: 2, tank_session_id: "extra-session" };
  assertEquals(areSprayTankActualsComplete(planned, [base, extra], identity), false);
  assertEquals(areSprayTankActualsComplete(planned, [base, fixture.actuals[1]], identity), false);
  assertEquals(areSprayTankActualsComplete(planned, [{ ...base, vineyard_id: "wrong" }], identity), false);
});

Deno.test("duplicate additional id is malformed", () => {
  const addition = (base.chemicals as Record<string, unknown>[])[1];
  const duplicate = { ...base, chemicals: [...base.chemicals as unknown[], { ...addition }] };
  assertEquals(areSprayTankActualsComplete(planned, [duplicate], identity), false);
});

Deno.test("SQL 232 manual backing trip uses stored tank identity and maps actual-only lines", () => {
  const manualId = "60000000-0000-4000-8000-000000000001";
  const tankId = "60000000-0000-4000-8000-000000000002";
  const chemicalId = "60000000-0000-4000-8000-000000000003";
  const manualSpray = {
    id: fixture.sprayRecordId,
    vineyard_id: fixture.vineyardId,
    trip_id: fixture.tripId,
    entry_source: "manual",
    manual_entry_id: manualId,
    tanks: [{ id: tankId, tankNumber: 1, chemicals: [{ id: chemicalId, savedChemicalId: "60000000-0000-4000-8000-000000000004", costPerUnit: null, volumePerTank: null }]}],
  };
  const backingTrip = { id: fixture.tripId, vineyard_id: fixture.vineyardId, entry_source: "manual", manual_entry_id: manualId, tank_sessions: [] };
  const manualIdentity = buildTankActualIdentity(manualSpray, backingTrip);
  const manualActual = {
    ...base,
    tank_session_id: tankId,
    chemicals: [{ id: chemicalId, plannedChemicalId: null, savedChemicalId: "60000000-0000-4000-8000-000000000004", name: "Manual product", actualAmountBase: 1250, unit: "mL" }],
  };
  assertEquals(manualIdentity.isManualEntry, true);
  assertEquals(areSprayTankActualsComplete(manualSpray.tanks, [manualActual], manualIdentity), true);
  const mapped = mapSprayActualTanks([manualActual], new Set([manualActual.id]), manualIdentity);
  assertEquals(mapped[0].association_status, "exact");
  assertEquals(mapped[0].actual_products[0].usage_kind, "additional");
  assertEquals(mapped[0].actual_products[0].planned_chemical_id, null);
});

Deno.test("manual identity rejects wrong backing owner, provenance, and stored tank session", () => {
  const manualId = "70000000-0000-4000-8000-000000000001";
  const tankId = "70000000-0000-4000-8000-000000000002";
  const spray = { id: fixture.sprayRecordId, vineyard_id: fixture.vineyardId, trip_id: fixture.tripId, entry_source: "manual", manual_entry_id: manualId, tanks: [{ id: tankId, tankNumber: 1, chemicals: [] }] };
  const wrongOwner = buildTankActualIdentity(spray, { id: fixture.tripId, vineyard_id: "wrong", entry_source: "manual", manual_entry_id: manualId, tank_sessions: [] });
  const unknownOrigin = buildTankActualIdentity({ ...spray, entry_source: null, manual_entry_id: null }, null);
  assertEquals(wrongOwner.sessionIdsByTank.size, 0);
  assertEquals(unknownOrigin.isManualEntry, false);
  assertEquals(resolveSprayTankActualRows(spray.tanks, [{ ...base, tank_session_id: "wrong-session" }], wrongOwner).size, 0);
});

Deno.test("manual response mapping preserves explicit zero and null quantities and rejects wrong owner evidence", () => {
  const manualIdentity = { ...identity, isManualEntry: true };
  const rows = [
    { ...base, chemicals: [{ id: "line-zero", plannedChemicalId: null, savedChemicalId: "saved-zero", actualAmountBase: 0 }] },
    { ...base, id: "wrong-owner", vineyard_id: "wrong", chemicals: [{ id: "line-null", plannedChemicalId: null, savedChemicalId: "saved-null", actualAmountBase: null }] },
  ];
  const mapped = mapSprayActualTanks(rows, new Set([base.id]), manualIdentity);
  assertEquals(mapped.length, 1);
  assertEquals(mapped[0].actual_products[0].quantity_base, 0);
  assertEquals(areSprayTankActualsComplete(planned, rows, manualIdentity), false);
});

Deno.test("full spray response keeps absent manual plan null and genuine actual zero", () => {
  const tankId = "80000000-0000-4000-8000-000000000001";
  const manualIdentity: TankActualIdentity = {
    ...identity,
    isManualEntry: true,
    sessionIdsByTank: new Map([[1, new Set([tankId])]]),
  };
  const plannedManual = [{ id: tankId, tankNumber: 1, chemicals: [] }];
  const actualZero = { ...base, tank_session_id: tankId, water_volume_l: 0, chemicals: [] };
  const response = buildSprayActualResponse(plannedManual, [actualZero], manualIdentity).fields;
  assertEquals(response.planned_water_volume_l, null);
  assertEquals(response.actual_water_volume_l, 0);
  assertEquals(response.actuals_complete, true);
  assertEquals((response.actual_tanks as Array<Record<string, unknown>>)[0].actual_water_volume_l, 0);

  const explicitPlan = buildSprayActualResponse([{ ...plannedManual[0], waterVolume: 0 }], [actualZero], manualIdentity).fields;
  assertEquals(explicitPlan.planned_water_volume_l, 0);
});

Deno.test("zero direct line with one valid substitution is complete", () => {
  const substitution = {
    id: "30000000-0000-4000-8000-000000000099",
    plannedChemicalId: null,
    savedChemicalId: "30000000-0000-4000-8000-000000000098",
    replacesPlannedChemicalId: fixture.plannedTank.chemicals[0].id,
    usageKind: "substitution",
    name: "Valid Substitute",
    actualAmountBase: 900,
    unit: "mL",
  };
  const amended = { ...base, chemicals: [...base.chemicals as unknown[], substitution] };
  assertEquals(areSprayTankActualsComplete(planned, [amended], identity), true);
  assertEquals(areSprayTankActualsComplete(planned, [{ ...amended, water_volume_l: null }], identity), false);
});
