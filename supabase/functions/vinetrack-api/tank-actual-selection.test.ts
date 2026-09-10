import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { areSprayTankActualsComplete, resolveSprayTankActualRows } from "./index.ts";

Deno.test("shared full record keeps same-number sessions unresolved", async () => {
  const fixtureUrl = new URL("../../../ios/VineTrackTests/Fixtures/spray_tank_actual_selection_v1.json", import.meta.url);
  const fixture = JSON.parse(await Deno.readTextFile(fixtureUrl));
  const planned = [fixture.plannedTank];
  const rows = fixture.actuals;
  assertEquals(resolveSprayTankActualRows(planned, rows).size, 0);
  assertEquals(areSprayTankActualsComplete(planned, rows), false);
  assertEquals(resolveSprayTankActualRows(planned, [rows[0]]).get(1)?.id, rows[0].id);
  assertEquals(areSprayTankActualsComplete(planned, [rows[0]]), true);
  assertEquals(areSprayTankActualsComplete(planned, [{ ...rows[0], water_volume_l: null }]), false);
});
