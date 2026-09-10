export interface TankJson {
  tankNumber?: unknown;
  waterVolume?: unknown;
  sprayRatePerHa?: unknown;
  concentrationFactor?: unknown;
  chemicals?: unknown;
  [key: string]: unknown;
}

export interface TankActualChemicalJson {
  id?: unknown;
  plannedChemicalId?: unknown;
  savedChemicalId?: unknown;
  replacesPlannedChemicalId?: unknown;
  usageKind?: unknown;
  name?: unknown;
  actualAmountBase?: unknown;
  unit?: unknown;
}

export interface TankActualRow {
  id: string;
  vineyard_id: string;
  spray_record_id: string;
  trip_id: string;
  tank_session_id: string;
  tank_number: number;
  water_volume_l: number | null;
  chemicals: unknown;
  confirmed_at: string;
  client_updated_at: string;
  correction_version: number | null;
}

export interface TankActualIdentity {
  vineyardId: string;
  sprayRecordId: string;
  tripId: string | null;
  sessionIdsByTank: ReadonlyMap<number, ReadonlySet<string>>;
  isManualEntry: boolean;
}

function finiteNumber(value: unknown): number | null {
  if (typeof value === "number") return Number.isFinite(value) ? value : null;
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function scopedRows(actualRows: TankActualRow[], identity: TankActualIdentity): TankActualRow[] {
  return actualRows.filter((row) =>
    row.vineyard_id === identity.vineyardId &&
    row.spray_record_id === identity.sprayRecordId &&
    (identity.isManualEntry || row.trip_id === identity.tripId)
  );
}

function sessionMatches(row: TankActualRow, identity: TankActualIdentity): boolean {
  if (identity.isManualEntry) return row.tank_session_id.trim() !== "";
  return identity.sessionIdsByTank.get(row.tank_number)?.has(row.tank_session_id) === true;
}

/** Resolves only exact owned trip sessions, or explicit manual-entry sessions. */
export function resolveSprayTankActualRows(
  plannedTanks: TankJson[],
  actualRows: TankActualRow[],
  identity: TankActualIdentity,
): Map<number, TankActualRow> {
  const resolved = new Map<number, TankActualRow>();
  const scoped = scopedRows(actualRows, identity).filter((row) => sessionMatches(row, identity));
  for (const tank of plannedTanks) {
    const tankNumber = finiteNumber(tank.tankNumber);
    if (tankNumber === null) continue;
    const bySession = new Map<string, TankActualRow[]>();
    for (const row of scoped.filter((candidate) => candidate.tank_number === tankNumber)) {
      bySession.set(row.tank_session_id, [...(bySession.get(row.tank_session_id) ?? []), row]);
    }
    if (bySession.size !== 1) continue;
    const revisions = [...bySession.values()][0];
    const highestVersion = Math.max(...revisions.map((row) => finiteNumber(row.correction_version) ?? 0));
    const highest = revisions.filter((row) => (finiteNumber(row.correction_version) ?? 0) === highestVersion);
    if (highest.length === 1) resolved.set(tankNumber, highest[0]);
  }
  return resolved;
}

/** Validates exact identities, revisions, water and amendment-aware chemical evidence. */
export function areSprayTankActualsComplete(
  plannedTanks: TankJson[],
  actualRows: TankActualRow[],
  identity: TankActualIdentity,
): boolean {
  if (plannedTanks.length === 0) return false;
  const plannedNumbers = new Set<number>();
  for (const tank of plannedTanks) {
    const tankNumber = finiteNumber(tank.tankNumber);
    if (tankNumber === null || plannedNumbers.has(tankNumber)) return false;
    plannedNumbers.add(tankNumber);
  }
  const scoped = scopedRows(actualRows, identity);
  if (scoped.some((row) => !plannedNumbers.has(row.tank_number) || !sessionMatches(row, identity))) return false;
  const resolved = resolveSprayTankActualRows(plannedTanks, actualRows, identity);
  return plannedTanks.every((tank) => {
    const tankNumber = finiteNumber(tank.tankNumber);
    const actual = tankNumber === null ? undefined : resolved.get(tankNumber);
    const water = actual ? finiteNumber(actual.water_volume_l) : null;
    if (!actual || water === null || water < 0) return false;
    const lines = Array.isArray(actual.chemicals) ? actual.chemicals as TankActualChemicalJson[] : [];
    const planned = Array.isArray(tank.chemicals) ? tank.chemicals as Array<{ id?: unknown }> : [];
    const plannedIds = new Set(planned.map((line) => typeof line.id === "string" ? line.id : null).filter((id): id is string => id !== null));
    const lineIds = lines.map((line) => typeof line.id === "string" && line.id.trim() !== "" ? line.id : null);
    if (plannedIds.size !== planned.length || lineIds.some((id) => id === null) || new Set(lineIds).size !== lineIds.length) return false;
    if (!lines.every((line) => {
      const amount = finiteNumber(line.actualAmountBase);
      if (amount === null || amount < 0) return false;
      const kind = typeof line.usageKind === "string" ? line.usageKind : "planned";
      if (kind === "planned") return typeof line.plannedChemicalId === "string" && plannedIds.has(line.plannedChemicalId) && line.replacesPlannedChemicalId == null;
      if (kind === "additional") return line.plannedChemicalId == null && line.replacesPlannedChemicalId == null;
      return kind === "substitution" && line.plannedChemicalId == null && typeof line.replacesPlannedChemicalId === "string" && plannedIds.has(line.replacesPlannedChemicalId);
    })) return false;
    return [...plannedIds].every((plannedId) => {
      const direct = lines.filter((line) => (line.usageKind ?? "planned") === "planned" && line.plannedChemicalId === plannedId);
      const substitutions = lines.filter((line) => line.usageKind === "substitution" && line.replacesPlannedChemicalId === plannedId);
      if (substitutions.length === 1) return direct.length <= 1 && direct.every((line) => finiteNumber(line.actualAmountBase) === 0);
      return substitutions.length === 0 && direct.length === 1;
    });
  });
}
