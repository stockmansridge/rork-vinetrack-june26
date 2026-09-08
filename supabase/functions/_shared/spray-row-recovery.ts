export const ROW_RECOVERY_VERSION = "spray-row-recovery-v1";

export type Coordinate = { latitude: number; longitude: number };
export type SavedRow = { id?: string | null; number: number; startPoint?: Coordinate | null; endPoint?: Coordinate | null };
export type RecoveryBlock = { id: string; name: string; rows: SavedRow[] };
export type RecoverySession = { id?: string | null; tankNumber?: number | null; pathsCovered?: number[] | null };
export type RecoveryInput = {
  rowSequence: number[];
  completedPaths: number[];
  skippedPaths: number[];
  route: Coordinate[];
  blocks: RecoveryBlock[];
  authoritativeBlockIds: string[];
  plannedBlockIds: string[];
  sessions: RecoverySession[];
};
export type RecoveryAssignment = {
  blockId: string;
  blockName: string;
  rowIdentity: string;
  rowNumber: number;
  tankSessionId: string | null;
  tankNumber: number | null;
  status: "Complete" | "Skipped/Not complete" | "Not recorded";
  assignmentSource: "saved_plan_identity" | "session_boundary_order" | "gps_geometry_intersection";
  confidence: number;
  originalEvidence: Record<string, unknown>;
};

type PathCandidate = {
  block: RecoveryBlock;
  rowIdentity: string;
  matchingRowIds: string[];
  line: [Coordinate, Coordinate] | null;
};

function finite(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function samePath(left: number, right: number): boolean {
  return Math.abs(left - right) < 0.000_001;
}

function rowId(blockId: string, row: SavedRow): string {
  return row.id?.trim() || `${blockId}:legacy-row:${row.number}:${row.startPoint?.latitude ?? ""}:${row.startPoint?.longitude ?? ""}:${row.endPoint?.latitude ?? ""}:${row.endPoint?.longitude ?? ""}`;
}

function pathCandidate(block: RecoveryBlock, path: number): PathCandidate | null {
  const low = Math.floor(path);
  const high = Math.ceil(path);
  const required = low === high ? [low] : [low, high];
  const matches = required.map((number) => block.rows.filter((row) => row.number === number));
  if (matches.some((rows) => rows.length !== 1)) return null;
  const rows = matches.map((rows) => rows[0]);
  const ids = rows.map((row) => rowId(block.id, row));
  let line: [Coordinate, Coordinate] | null = null;
  if (rows.every((row) => row.startPoint && row.endPoint)) {
    if (rows.length === 1) {
      line = [rows[0].startPoint!, rows[0].endPoint!];
    } else {
      line = [
        { latitude: (rows[0].startPoint!.latitude + rows[1].startPoint!.latitude) / 2, longitude: (rows[0].startPoint!.longitude + rows[1].startPoint!.longitude) / 2 },
        { latitude: (rows[0].endPoint!.latitude + rows[1].endPoint!.latitude) / 2, longitude: (rows[0].endPoint!.longitude + rows[1].endPoint!.longitude) / 2 },
      ];
    }
  }
  return {
    block,
    rowIdentity: `block:${block.id}:rows:${ids.join("+")}:path:${path.toFixed(6)}`,
    matchingRowIds: ids,
    line,
  };
}

function metres(point: Coordinate, origin: Coordinate): { x: number; y: number } {
  const latScale = 111_320;
  const lonScale = latScale * Math.cos(origin.latitude * Math.PI / 180);
  return { x: (point.longitude - origin.longitude) * lonScale, y: (point.latitude - origin.latitude) * latScale };
}

function segmentDistance(point: Coordinate, line: [Coordinate, Coordinate]): number {
  const p = metres(point, line[0]);
  const b = metres(line[1], line[0]);
  const denominator = b.x * b.x + b.y * b.y;
  if (denominator <= 0) return Math.hypot(p.x, p.y);
  const t = Math.max(0, Math.min(1, (p.x * b.x + p.y * b.y) / denominator));
  return Math.hypot(p.x - t * b.x, p.y - t * b.y);
}

function geometryScore(route: Coordinate[], candidate: PathCandidate): { median: number; nearCount: number; longestRun: number } | null {
  if (!candidate.line || route.length < 3) return null;
  const distances = route.map((point) => segmentDistance(point, candidate.line!));
  const near = distances.filter((distance) => distance <= 8).sort((a, b) => a - b);
  let run = 0;
  let longestRun = 0;
  for (const distance of distances) {
    run = distance <= 8 ? run + 1 : 0;
    longestRun = Math.max(longestRun, run);
  }
  if (near.length < 3 || longestRun < 3) return null;
  return { median: near[Math.floor(near.length / 2)], nearCount: near.length, longestRun };
}

function sessionFor(path: number, sessions: RecoverySession[]): RecoverySession | null {
  const matches = sessions.filter((session) => session.pathsCovered?.some((covered) => finite(covered) && samePath(covered, path)) === true);
  return matches.length === 1 ? matches[0] : null;
}

/** Derives only reproducible, unambiguous assignments; unresolved paths are returned separately. */
export function deriveRecoveryAssignments(input: RecoveryInput): { assignments: RecoveryAssignment[]; unresolved: Array<{ rowNumber: number; reason: string }> } {
  const assignments: RecoveryAssignment[] = [];
  const unresolved: Array<{ rowNumber: number; reason: string }> = [];
  const uniquePaths = input.rowSequence.filter(finite).filter((path, index, all) => all.findIndex((value) => samePath(value, path)) === index);
  const authoritative = new Set(input.authoritativeBlockIds);
  const planned = new Set(input.plannedBlockIds);

  for (const path of uniquePaths) {
    if (input.rowSequence.filter((value) => finite(value) && samePath(value, path)).length !== 1) {
      unresolved.push({ rowNumber: path, reason: "repeated_path_occurrence" });
      continue;
    }
    const candidates = input.blocks.map((block) => pathCandidate(block, path)).filter((candidate): candidate is PathCandidate => candidate !== null);
    const authoritativeCandidates = candidates.filter((candidate) => authoritative.has(candidate.block.id));
    const plannedCandidates = candidates.filter((candidate) => planned.has(candidate.block.id));
    const scoped = authoritativeCandidates.length > 0 ? authoritativeCandidates : plannedCandidates;
    let selected: PathCandidate | null = null;
    let source: RecoveryAssignment["assignmentSource"] = "saved_plan_identity";
    let confidence = 1;
    let geometryEvidence: Record<string, unknown> | null = null;

    if (scoped.length === 1) {
      selected = scoped[0];
    } else {
      const geometryCandidates = (scoped.length > 1 ? scoped : candidates)
        .map((candidate) => ({ candidate, score: geometryScore(input.route, candidate) }))
        .filter((entry): entry is { candidate: PathCandidate; score: { median: number; nearCount: number; longestRun: number } } => entry.score !== null)
        .sort((left, right) => left.score.median - right.score.median || right.score.longestRun - left.score.longestRun);
      const winner = geometryCandidates[0];
      const runnerUp = geometryCandidates[1];
      const margin = winner && runnerUp ? runnerUp.score.median - winner.score.median : winner ? 8 - winner.score.median : 0;
      if (winner && winner.score.median <= 6 && margin >= 3) {
        selected = winner.candidate;
        source = "gps_geometry_intersection";
        confidence = Math.min(0.99, 0.90 + Math.min(winner.score.longestRun, 10) * 0.005 + Math.min(margin, 10) * 0.004);
        geometryEvidence = {
          routePointCount: input.route.length,
          pointsWithinEightMetres: winner.score.nearCount,
          longestContiguousRun: winner.score.longestRun,
          medianDistanceMetres: Number(winner.score.median.toFixed(3)),
          runnerUpMarginMetres: Number(margin.toFixed(3)),
          thresholdMetres: 8,
          minimumConfidence: 0.9,
        };
      }
    }

    if (!selected) {
      unresolved.push({ rowNumber: path, reason: candidates.length === 0 ? "no_saved_row_identity" : "ambiguous_block_or_geometry" });
      continue;
    }

    const session = sessionFor(path, input.sessions);
    const isComplete = input.completedPaths.some((value) => samePath(value, path));
    const isSkipped = input.skippedPaths.some((value) => samePath(value, path));
    assignments.push({
      blockId: selected.block.id,
      blockName: selected.block.name,
      rowIdentity: selected.rowIdentity,
      rowNumber: path,
      tankSessionId: session?.id?.trim() || null,
      tankNumber: finite(session?.tankNumber) && (session?.tankNumber ?? 0) >= 1 ? session!.tankNumber! : null,
      status: isComplete ? "Complete" : isSkipped ? "Skipped/Not complete" : "Not recorded",
      assignmentSource: source,
      confidence,
      originalEvidence: {
        derivationVersion: ROW_RECOVERY_VERSION,
        pathNumber: path,
        tripSequenceIndices: input.rowSequence.map((value, index) => samePath(value, path) ? index : -1).filter((index) => index >= 0),
        attributionBasis: authoritativeCandidates.length > 0 ? "recorded_application_blocks" : "saved_trip_or_job_plan",
        authoritativeBlockIds: input.authoritativeBlockIds,
        plannedBlockIds: input.plannedBlockIds,
        candidateBlockIds: candidates.map((candidate) => candidate.block.id),
        matchingRowIds: selected.matchingRowIds,
        tankSessionIdentity: session?.id ?? null,
        tankNumber: session?.tankNumber ?? null,
        geometry: geometryEvidence,
      },
    });
  }
  return { assignments, unresolved };
}
