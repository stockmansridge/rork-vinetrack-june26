import { assertEquals, assertGreater } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { deriveRecoveryAssignments, type RecoveryBlock } from "./spray-row-recovery.ts";

const block = (id: string, offset: number): RecoveryBlock => ({
  id,
  name: id,
  rows: [24, 25].map((number) => ({
    id: `${id}-${number}`,
    number,
    startPoint: { latitude: -33 + offset, longitude: 149 + number * 0.0001 },
    endPoint: { latitude: -32.999 + offset, longitude: 149 + number * 0.0001 },
  })),
});

Deno.test("saved identities recover only a uniquely scoped block", () => {
  const result = deriveRecoveryAssignments({
    rowSequence: [24.5], completedPaths: [24.5], skippedPaths: [], route: [],
    blocks: [block("north", 0), block("south", 0.01)], authoritativeBlockIds: ["north"], plannedBlockIds: ["north", "south"],
    sessions: [{ id: "session-1", tankNumber: 1, pathsCovered: [24.5] }],
  });
  assertEquals(result.unresolved, []);
  assertEquals(result.assignments.length, 1);
  assertEquals(result.assignments[0].blockId, "north");
  assertEquals(result.assignments[0].tankSessionId, "session-1");
  assertEquals(result.assignments[0].status, "Complete");
});

Deno.test("repeated row numbers across blocks stay unresolved without discriminating evidence", () => {
  const result = deriveRecoveryAssignments({
    rowSequence: [24.5], completedPaths: [], skippedPaths: [], route: [],
    blocks: [block("north", 0), block("south", 0.01)], authoritativeBlockIds: [], plannedBlockIds: ["north", "south"], sessions: [],
  });
  assertEquals(result.assignments, []);
  assertEquals(result.unresolved, [{ rowNumber: 24.5, reason: "ambiguous_block_or_geometry" }]);
});

Deno.test("repeated occurrences of the same path remain unresolved", () => {
  const result = deriveRecoveryAssignments({
    rowSequence: [24.5, 24.5], completedPaths: [24.5], skippedPaths: [], route: [],
    blocks: [block("north", 0)], authoritativeBlockIds: ["north"], plannedBlockIds: ["north"], sessions: [],
  });
  assertEquals(result.assignments, []);
  assertEquals(result.unresolved, [{ rowNumber: 24.5, reason: "repeated_path_occurrence" }]);
});

Deno.test("GPS geometry selects a separated saved-row path and exposes provenance", () => {
  const north = block("north", 0);
  const route = Array.from({ length: 8 }, (_, index) => ({ latitude: -32.9999 + index * 0.0001, longitude: 149.00245 }));
  const result = deriveRecoveryAssignments({
    rowSequence: [24.5], completedPaths: [], skippedPaths: [24.5], route,
    blocks: [north, block("south", 0.01)], authoritativeBlockIds: [], plannedBlockIds: ["north", "south"], sessions: [],
  });
  assertEquals(result.assignments.length, 1);
  assertEquals(result.assignments[0].assignmentSource, "gps_geometry_intersection");
  assertGreater(result.assignments[0].confidence, 0.9);
  assertEquals(result.assignments[0].status, "Skipped/Not complete");
  assertEquals(result.assignments[0].originalEvidence.derivationVersion, "spray-row-recovery-v1");
});
