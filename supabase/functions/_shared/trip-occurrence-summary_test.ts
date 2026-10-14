import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { tripCoverageSummary } from "./trip-occurrence-summary.ts";

const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
function document() {
  return { contract: "vinetrack.planned-occurrence", schemaVersion: 1, planId: id(9), revision: 3, planRevision: 1,
    items: [1,2,3,4].map(n => ({ occurrenceId: id(n), blockId: id(n <= 2 ? 7 : 8), blockNameSnapshot: n <= 2 ? "A" : "B",
      pathNumber: 38.5, passOrdinal: n % 2 === 1 ? 1 : 2, physicalPathRef: { pathId: id(n <= 2 ? 5 : 6), rowIds: [], geometryRevision: "unresolved" } })),
    activeOrder: [id(3),id(1),id(2)], retired: [id(4)], selectedOccurrenceId: null, plannedCursorId: id(2),
    states: Object.fromEntries([1,2,3,4].map(n => [id(n), { status: n === 1 || n === 4 ? "done" : n === 3 ? "skipped" : "incomplete",
      lastOperationId: null, source: null, tankSessionIds: [] }])) };
}

Deno.test("same labels retain blocks, passes, order and separate retired evidence", () => {
  const result = tripCoverageSummary(document(), [38.5,38.5,38.5], [38.5], []);
  assertEquals([result.planned,result.completed,result.skipped,result.incomplete],[3,1,1,1]);
  const rows = result.occurrences as Record<string, unknown>[];
  assertEquals(rows.map(row => row.occurrence_id), [id(3),id(1),id(2),id(4)]);
  assertEquals(rows.map(row => row.block_name), ["B","A","A","B"]);
  assertEquals(rows.map(row => row.pass_ordinal), [1,1,2,2]);
  assertEquals(rows[3].is_retired,true);
});

Deno.test("non-null malformed/future states do not fall back to numeric counts", () => {
  for (const raw of ["bad", {}, {...document(),schemaVersion:99}, {...document(),activeOrder:[id(1),id(1),id(2)]},
                     {...document(),states:{...document().states,[id(2)]:{status:"unknown",tankSessionIds:[]}}}]) {
    const result = tripCoverageSummary(raw,[38.5,38.5],[38.5],[38.5]);
    assertEquals(result.coverage_basis,"updateRequired"); assertEquals(result.completed,null);
  }
});

Deno.test("NULL legacy numeric API projection remains unchanged", () => {
  const result = tripCoverageSummary(null,[38.5,38.5],[38.5],[]);
  assertEquals(result,{coverage_basis:"legacyNumeric",planned:2,completed:1,skipped:0});
});
