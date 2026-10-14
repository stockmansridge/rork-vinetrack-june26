/** Read-only occurrence projection. A non-null unsupported document never uses numeric truth. */
export function tripCoverageSummary(raw: unknown, sequence: unknown, completed: unknown, skipped: unknown): Record<string, unknown> {
  if (raw === null || raw === undefined) {
    return { coverage_basis: "legacyNumeric", planned: Array.isArray(sequence) ? sequence.length : 0,
      completed: Array.isArray(completed) ? completed.length : 0, skipped: Array.isArray(skipped) ? skipped.length : 0 };
  }
  const unavailable = { coverage_basis: "updateRequired", planned: null, completed: null, skipped: null, incomplete: null,
    message: "Occurrence coverage unavailable. An updated compatible reader is required." };
  const object = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v);
  const uuid = (v: unknown): v is string => typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(v);
  if (!object(raw) || raw.contract !== "vinetrack.planned-occurrence" || raw.schemaVersion !== 1 || !uuid(raw.planId) ||
      !Number.isSafeInteger(raw.revision) || Number(raw.revision) < 0 || !Number.isSafeInteger(raw.planRevision) || Number(raw.planRevision) < 1 ||
      !Array.isArray(raw.items) || !Array.isArray(raw.activeOrder) || !Array.isArray(raw.retired) || !object(raw.states)) return unavailable;
  const items = new Map<string, Record<string, unknown>>();
  for (const item of raw.items) {
    if (!object(item) || !uuid(item.occurrenceId) || items.has(item.occurrenceId) || !uuid(item.blockId) ||
        typeof item.blockNameSnapshot !== "string" || typeof item.pathNumber !== "number" || !Number.isFinite(item.pathNumber) ||
        !Number.isSafeInteger(item.passOrdinal) || Number(item.passOrdinal) < 1 || !object(item.physicalPathRef) ||
        !uuid(item.physicalPathRef.pathId) || !Array.isArray(item.physicalPathRef.rowIds) || !item.physicalPathRef.rowIds.every(uuid)) return unavailable;
    items.set(item.occurrenceId, item);
  }
  const activeOrder = raw.activeOrder;
  const all = [...activeOrder, ...raw.retired];
  if (all.length !== items.size || new Set(all).size !== items.size || !all.every(id => uuid(id) && items.has(id)) ||
      Object.keys(raw.states).length !== items.size || Object.keys(raw.states).some(id => !items.has(id)) ||
      [raw.selectedOccurrenceId, raw.plannedCursorId].some(id => id != null && !activeOrder.includes(id))) return unavailable;
  const states = raw.states;
  const occurrences: Record<string, unknown>[] = [];
  let done = 0; let skip = 0; let incomplete = 0;
  for (const id of all as string[]) {
    const state = states[id]; const item = items.get(id)!;
    if (!object(state) || !["incomplete", "done", "skipped"].includes(String(state.status)) ||
        !Array.isArray(state.tankSessionIds) || !state.tankSessionIds.every(uuid) ||
        (state.lastOperationId != null && !uuid(state.lastOperationId)) ||
        (state.source != null && !["manual", "automatic", "correction", "endReview"].includes(String(state.source)))) return unavailable;
    const retired = raw.retired.includes(id);
    if (!retired) { if (state.status === "done") done++; else if (state.status === "skipped") skip++; else incomplete++; }
    occurrences.push({ occurrence_id: id, block_id: item.blockId, block_name: item.blockNameSnapshot,
      path_number: item.pathNumber, pass_ordinal: item.passOrdinal, state: state.status,
      source: state.source ?? null, tank_session_ids: state.tankSessionIds, is_retired: retired });
  }
  return { coverage_basis: "plannedOccurrencesV1", plan_id: raw.planId, revision: raw.revision, plan_revision: raw.planRevision,
    planned: raw.activeOrder.length, completed: done, skipped: skip, incomplete, occurrences };
}
