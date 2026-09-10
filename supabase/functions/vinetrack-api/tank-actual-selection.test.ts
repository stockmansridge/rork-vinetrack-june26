import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  areSprayTankActualsComplete,
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
