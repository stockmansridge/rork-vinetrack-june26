export interface TankJson {
  id?: unknown;
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

export interface SprayTankIdentitySource {
  id: string;
  vineyard_id: string;
  trip_id: string | null;
  entry_source: string | null;
  manual_entry_id: string | null;
  tanks: unknown;
}

export interface TripTankIdentitySource {
  id: string;
  vineyard_id: string;
  entry_source: string | null;
  manual_entry_id: string | null;
  tank_sessions: unknown;
}

function finiteNumber(value: unknown): number | null {
  if (typeof value === "number") return Number.isFinite(value) ? value : null;
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

/** Builds the explicit provenance and exact tank identity used by the detail endpoint. */
export function buildTankActualIdentity(
  spray: SprayTankIdentitySource,
  trip: TripTankIdentitySource | null,
): TankActualIdentity {
  const isManualEntry = spray.entry_source === "manual" &&
    typeof spray.manual_entry_id === "string" && spray.manual_entry_id.trim() !== "";
  const ownsTrip = trip !== null && trip.id === spray.trip_id && trip.vineyard_id === spray.vineyard_id;
  const manualBackingTripMatches = isManualEntry && ownsTrip && trip.entry_source === "manual" &&
    trip.manual_entry_id === spray.manual_entry_id;
  const sessionIdsByTank = new Map<number, Set<string>>();
  const sources = manualBackingTripMatches
    ? (Array.isArray(spray.tanks) ? spray.tanks : [])
    : (!isManualEntry && ownsTrip && Array.isArray(trip.tank_sessions) ? trip.tank_sessions : []);
  for (const raw of sources) {
    if (!raw || typeof raw !== "object") continue;
    const source = raw as Record<string, unknown>;
    const id = typeof source.id === "string" ? source.id :
      typeof source.tank_session_id === "string" ? source.tank_session_id : null;
    const tankNumber = finiteNumber(source.tankNumber ?? source.tank_number);
    if (!id || tankNumber === null) continue;
    sessionIdsByTank.set(tankNumber, new Set([...(sessionIdsByTank.get(tankNumber) ?? []), id]));
  }
  return {
    vineyardId: spray.vineyard_id,
    sprayRecordId: spray.id,
    tripId: spray.trip_id,
    sessionIdsByTank,
    isManualEntry,
  };
}

function rowOwnershipMatches(row: TankActualRow, identity: TankActualIdentity): boolean {
  return row.vineyard_id === identity.vineyardId &&
    row.spray_record_id === identity.sprayRecordId &&
    row.trip_id === identity.tripId;
}

function scopedRows(actualRows: TankActualRow[], identity: TankActualIdentity): TankActualRow[] {
  return actualRows.filter((row) => rowOwnershipMatches(row, identity));
}

function sessionMatches(row: TankActualRow, identity: TankActualIdentity): boolean {
  return identity.sessionIdsByTank.get(row.tank_number)?.has(row.tank_session_id) === true;
}

/** Resolves only exact owned trip and tank sessions. */
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
  if (actualRows.some((row) => !rowOwnershipMatches(row, identity))) return false;
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
    if (identity.isManualEntry) {
      if (lines.length !== planned.length || lineIds.some((id) => id === null || !plannedIds.has(id))) return false;
      return lines.every((line) => {
        const amount = finiteNumber(line.actualAmountBase);
        const kind = typeof line.usageKind === "string" ? line.usageKind : "additional";
        return amount !== null && amount >= 0 && typeof line.savedChemicalId === "string" &&
          line.savedChemicalId.trim() !== "" && line.plannedChemicalId == null &&
          line.replacesPlannedChemicalId == null && kind === "additional";
      });
    }
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

/** Maps only exact-owner rows; malformed ownership is never exposed as another application's evidence. */
export function mapSprayActualTanks(
  rows: TankActualRow[],
  selectedIds: ReadonlySet<string>,
  identity: TankActualIdentity,
) {
  return rows.filter((row) => rowOwnershipMatches(row, identity)).map((row) => ({
    actual_id: row.id,
    association_status: selectedIds.has(row.id) ? "exact" : "unresolved",
    tank_number: row.tank_number,
    tank_session_id: row.tank_session_id,
    confirmed_at: row.confirmed_at,
    actual_water_volume_l: finiteNumber(row.water_volume_l),
    actual_products: (Array.isArray(row.chemicals) ? row.chemicals as TankActualChemicalJson[] : []).map((chemical) => ({
      id: typeof chemical.id === "string" ? chemical.id : null,
      planned_chemical_id: typeof chemical.plannedChemicalId === "string" ? chemical.plannedChemicalId : null,
      saved_chemical_id: typeof chemical.savedChemicalId === "string" ? chemical.savedChemicalId : null,
      replaces_planned_chemical_id: typeof chemical.replacesPlannedChemicalId === "string" ? chemical.replacesPlannedChemicalId : null,
      usage_kind: typeof chemical.usageKind === "string" ? chemical.usageKind : identity.isManualEntry ? "additional" : null,
      name: typeof chemical.name === "string" ? chemical.name : null,
      quantity_base: finiteNumber(chemical.actualAmountBase),
      unit: typeof chemical.unit === "string" ? chemical.unit : null,
    })),
  }));
}
