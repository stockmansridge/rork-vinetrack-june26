// scripts/preview_pin_attachment.ts
//
// READ-ONLY preview generator for the pins attachment backfill.
//
// For each legacy pin (deleted_at is null, pin_row_number is null) with a
// known paddock + driving row + heading + side, it proposes:
//   * driving_row_number       = legacy row_number + 0.5
//   * pin_row_number           = computed from path geometry + heading + side
//   * pin_side                 = legacy side (already operator-POV)
//   * snapped_latitude/long    = projected onto the path mid-line
//   * along_row_distance_m     = distance along the path mid-line
//   * snapped_to_row           = true only when geometry resolves cleanly
//
// Output: CSV + JSON written to migration/out/pin_attachment_preview.{csv,json}
//
// IMPORTANT: this script ONLY reads data and writes local files. It does
// NOT update Supabase. The conservative UPDATE for high-confidence rows
// is held until the preview output has been reviewed.
//
// Usage:
//   bun run scripts/preview_pin_attachment.ts
//
// Required env (server-side, NOT EXPO_PUBLIC):
//   V2_SUPABASE_URL
//   V2_SERVICE_ROLE_KEY

import { createClient } from "@supabase/supabase-js";
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

type LatLng = { latitude: number; longitude: number };

type PaddockRow = {
  number: number;
  startPoint: LatLng;
  endPoint: LatLng;
};

type Paddock = {
  id: string;
  rows: PaddockRow[];
};

type LegacyPin = {
  id: string;
  vineyard_id: string;
  paddock_id: string | null;
  row_number: number | null;
  side: string | null;
  heading: number | null;
  latitude: number | null;
  longitude: number | null;
  pin_row_number: number | null;
  snapped_to_row: boolean | null;
  button_name: string | null;
  mode: string | null;
};

type Confidence = "high" | "medium" | "low";

type Proposal = {
  pin_id: string;
  vineyard_id: string;
  paddock_id: string | null;
  button_name: string | null;
  mode: string | null;
  legacy_row_number: number | null;
  legacy_side: string | null;
  proposed_driving_row_number: number | null;
  proposed_pin_row_number: number | null;
  proposed_pin_side: string | null;
  current_latitude: number | null;
  current_longitude: number | null;
  proposed_snapped_latitude: number | null;
  proposed_snapped_longitude: number | null;
  proposed_along_row_distance_m: number | null;
  confidence: Confidence;
  reason: string;
};

const url = process.env.V2_SUPABASE_URL;
const key = process.env.V2_SERVICE_ROLE_KEY;
if (!url || !key) {
  console.error("V2_SUPABASE_URL and V2_SERVICE_ROLE_KEY must be set.");
  process.exit(1);
}

const client = createClient(url, key, {
  auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false }
});

async function main(): Promise<void> {
  const pins = await fetchLegacyPins();
  const paddocks = await fetchPaddocks(uniquePaddockIds(pins));
  const proposals: Proposal[] = pins.map((pin) => buildProposal(pin, paddocks));

  await writeOutputs(proposals);
  printSummary(proposals);
}

async function fetchLegacyPins(): Promise<LegacyPin[]> {
  const { data, error } = await client
    .from("pins")
    .select(
      "id,vineyard_id,paddock_id,row_number,side,heading,latitude,longitude,pin_row_number,snapped_to_row,button_name,mode"
    )
    .is("deleted_at", null)
    .is("pin_row_number", null);
  if (error) throw error;
  return (data ?? []) as LegacyPin[];
}

async function fetchPaddocks(ids: string[]): Promise<Map<string, Paddock>> {
  if (ids.length === 0) return new Map();
  // Paddock geometry currently lives in Supabase as JSON columns.
  // Adjust the column names below if your schema differs.
  const { data, error } = await client
    .from("paddocks")
    .select("id, rows")
    .in("id", ids);
  if (error) throw error;

  const map = new Map<string, Paddock>();
  for (const row of (data ?? []) as { id: string; rows: unknown }[]) {
    const rows = parseRows(row.rows);
    map.set(row.id, { id: row.id, rows });
  }
  return map;
}

function parseRows(value: unknown): PaddockRow[] {
  if (!Array.isArray(value)) return [];
  const out: PaddockRow[] = [];
  for (const r of value) {
    if (!r || typeof r !== "object") continue;
    const number = (r as { number?: number }).number;
    const startPoint = (r as { startPoint?: LatLng }).startPoint;
    const endPoint = (r as { endPoint?: LatLng }).endPoint;
    if (
      typeof number === "number" &&
      startPoint && typeof startPoint.latitude === "number" &&
      endPoint && typeof endPoint.latitude === "number"
    ) {
      out.push({ number, startPoint, endPoint });
    }
  }
  return out;
}

function uniquePaddockIds(pins: LegacyPin[]): string[] {
  const set = new Set<string>();
  for (const p of pins) {
    if (p.paddock_id) set.add(p.paddock_id);
  }
  return [...set];
}

function buildProposal(pin: LegacyPin, paddocks: Map<string, Paddock>): Proposal {
  const drivingFloor = pin.row_number;
  const drivingPath = drivingFloor != null ? drivingFloor + 0.5 : null;

  if (drivingFloor == null) {
    return baseProposal(pin, drivingPath, "low", "Missing legacy row_number.");
  }
  if (!pin.paddock_id) {
    return baseProposal(pin, drivingPath, "low", "Missing paddock_id.");
  }
  if (pin.heading == null) {
    return baseProposal(pin, drivingPath, "low", "Missing heading \u2014 cannot infer direction of travel.");
  }
  if (!pin.side) {
    return baseProposal(pin, drivingPath, "low", "Missing side \u2014 cannot infer attached vine row.");
  }
  if (pin.latitude == null || pin.longitude == null) {
    return baseProposal(pin, drivingPath, "low", "Missing coordinates \u2014 cannot snap to row.");
  }

  const paddock = paddocks.get(pin.paddock_id);
  if (!paddock || paddock.rows.length === 0) {
    return baseProposal(pin, drivingPath, "medium", "Paddock geometry not available in this preview run.");
  }

  const lower = Math.floor(drivingPath!);
  const upper = Math.ceil(drivingPath!);
  const r1 = paddock.rows.find((r) => r.number === lower);
  const r2 = paddock.rows.find((r) => r.number === upper);
  if (!r1 || !r2) {
    return baseProposal(pin, drivingPath, "medium", "Adjacent row geometry missing.");
  }

  const snap = snapToPath({ latitude: pin.latitude, longitude: pin.longitude }, r1, r2);
  if (!snap) {
    return baseProposal(pin, drivingPath, "medium", "Path segment degenerate.");
  }

  const attachedRow = attachedVineRow({
    paddockRowLower: r1,
    paddockRowUpper: r2,
    snappedPoint: snap.point,
    heading: pin.heading,
    operatorSide: pin.side
  });

  return {
    pin_id: pin.id,
    vineyard_id: pin.vineyard_id,
    paddock_id: pin.paddock_id,
    button_name: pin.button_name,
    mode: pin.mode,
    legacy_row_number: drivingFloor,
    legacy_side: pin.side,
    proposed_driving_row_number: drivingPath,
    proposed_pin_row_number: attachedRow,
    proposed_pin_side: pin.side,
    current_latitude: pin.latitude,
    current_longitude: pin.longitude,
    proposed_snapped_latitude: snap.point.latitude,
    proposed_snapped_longitude: snap.point.longitude,
    proposed_along_row_distance_m: snap.alongMetres,
    confidence: "high",
    reason: "Resolved from path geometry + heading + side."
  };
}

function baseProposal(
  pin: LegacyPin,
  drivingPath: number | null,
  confidence: Confidence,
  reason: string
): Proposal {
  return {
    pin_id: pin.id,
    vineyard_id: pin.vineyard_id,
    paddock_id: pin.paddock_id,
    button_name: pin.button_name,
    mode: pin.mode,
    legacy_row_number: pin.row_number,
    legacy_side: pin.side,
    proposed_driving_row_number: drivingPath,
    proposed_pin_row_number: null,
    proposed_pin_side: pin.side,
    current_latitude: pin.latitude,
    current_longitude: pin.longitude,
    proposed_snapped_latitude: null,
    proposed_snapped_longitude: null,
    proposed_along_row_distance_m: null,
    confidence,
    reason
  };
}

// MARK: - Geometry helpers (mirrors the iOS PinAttachmentResolver)

function snapToPath(
  point: LatLng,
  r1: PaddockRow,
  r2: PaddockRow
): { point: LatLng; alongMetres: number } | null {
  const start = midpoint(r1.startPoint, r2.startPoint);
  const end = midpoint(r1.endPoint, r2.endPoint);
  return projectOntoSegment(point, start, end);
}

function projectOntoSegment(
  point: LatLng,
  a: LatLng,
  b: LatLng
): { point: LatLng; alongMetres: number } | null {
  const centroidLat = (a.latitude + b.latitude + point.latitude) / 3;
  const mPerDegLat = 111_320;
  const mPerDegLon = 111_320 * Math.cos((centroidLat * Math.PI) / 180);
  const ax = a.longitude * mPerDegLon;
  const ay = a.latitude * mPerDegLat;
  const bx = b.longitude * mPerDegLon;
  const by = b.latitude * mPerDegLat;
  const px = point.longitude * mPerDegLon;
  const py = point.latitude * mPerDegLat;
  const dx = bx - ax;
  const dy = by - ay;
  const lenSq = dx * dx + dy * dy;
  if (lenSq < 1e-6) return null;
  const length = Math.sqrt(lenSq);
  let t = ((px - ax) * dx + (py - ay) * dy) / lenSq;
  t = Math.max(0, Math.min(1, t));
  const cx = ax + t * dx;
  const cy = ay + t * dy;
  return {
    point: { latitude: cy / mPerDegLat, longitude: cx / mPerDegLon },
    alongMetres: t * length
  };
}

function midpoint(a: LatLng, b: LatLng): LatLng {
  return {
    latitude: (a.latitude + b.latitude) / 2,
    longitude: (a.longitude + b.longitude) / 2
  };
}

function bearingDegrees(from: LatLng, to: LatLng): number {
  const lat1 = (from.latitude * Math.PI) / 180;
  const lat2 = (to.latitude * Math.PI) / 180;
  const dLon = ((to.longitude - from.longitude) * Math.PI) / 180;
  const y = Math.sin(dLon) * Math.cos(lat2);
  const x =
    Math.cos(lat1) * Math.sin(lat2) -
    Math.sin(lat1) * Math.cos(lat2) * Math.cos(dLon);
  const bearing = (Math.atan2(y, x) * 180) / Math.PI;
  return ((bearing % 360) + 360) % 360;
}

function signedAngularDifference(a: number, b: number): number {
  let diff = ((a - b) % 360);
  if (diff > 180) diff -= 360;
  if (diff <= -180) diff += 360;
  return diff;
}

function attachedVineRow(opts: {
  paddockRowLower: PaddockRow;
  paddockRowUpper: PaddockRow;
  snappedPoint: LatLng;
  heading: number;
  operatorSide: string;
}): number {
  const { paddockRowLower: r1, paddockRowUpper: r2, snappedPoint, heading, operatorSide } = opts;
  const pathStart = midpoint(r1.startPoint, r2.startPoint);
  const pathEnd = midpoint(r1.endPoint, r2.endPoint);
  const pathBearing = bearingDegrees(pathStart, pathEnd);
  const headingDiff = signedAngularDifference(heading, pathBearing);
  const forward =
    Math.abs(headingDiff) > 90 ? (pathBearing + 180) % 360 : pathBearing;
  const leftBearing = ((forward - 90) % 360 + 360) % 360;
  const lowerMid = midpoint(r1.startPoint, r1.endPoint);
  const toLower = bearingDegrees(snappedPoint, lowerMid);
  const lowerIsOnLeft = Math.abs(signedAngularDifference(toLower, leftBearing)) < 90;
  const isLeft = operatorSide.toLowerCase() === "left";
  if (isLeft) return lowerIsOnLeft ? r1.number : r2.number;
  return lowerIsOnLeft ? r2.number : r1.number;
}

// MARK: - Output

async function writeOutputs(proposals: Proposal[]): Promise<void> {
  const outDir = join(process.cwd(), "migration", "out");
  await mkdir(outDir, { recursive: true });
  const jsonPath = join(outDir, "pin_attachment_preview.json");
  const csvPath = join(outDir, "pin_attachment_preview.csv");
  await writeFile(jsonPath, JSON.stringify(proposals, null, 2), "utf8");
  await writeFile(csvPath, toCsv(proposals), "utf8");
  await ensureDir(dirname(jsonPath));
  console.log(`Wrote ${proposals.length} rows to:\n  ${jsonPath}\n  ${csvPath}`);
}

async function ensureDir(path: string): Promise<void> {
  try { await mkdir(path, { recursive: true }); } catch { /* already exists */ }
}

function toCsv(rows: Proposal[]): string {
  const headers = [
    "pin_id","vineyard_id","paddock_id","button_name","mode",
    "legacy_row_number","legacy_side",
    "proposed_driving_row_number","proposed_pin_row_number","proposed_pin_side",
    "current_latitude","current_longitude",
    "proposed_snapped_latitude","proposed_snapped_longitude","proposed_along_row_distance_m",
    "confidence","reason"
  ];
  const escape = (v: unknown): string => {
    if (v == null) return "";
    const s = String(v);
    if (/[",\n]/.test(s)) return `"${s.replace(/"/g, '""')}"`;
    return s;
  };
  const lines = [headers.join(",")];
  for (const r of rows) {
    lines.push(headers.map((h) => escape((r as Record<string, unknown>)[h])).join(","));
  }
  return lines.join("\n") + "\n";
}

function printSummary(rows: Proposal[]): void {
  const counts = { high: 0, medium: 0, low: 0 };
  for (const r of rows) counts[r.confidence] += 1;
  console.log("\nPin attachment preview summary:");
  console.log(`  total proposals : ${rows.length}`);
  console.log(`  high confidence : ${counts.high}  (eligible for conservative backfill)`);
  console.log(`  medium          : ${counts.medium}`);
  console.log(`  low             : ${counts.low}  (manual review)`);
  console.log("\nNo updates were applied. Review the CSV/JSON before running any backfill.\n");
}

main().catch((err: unknown) => {
  console.error("preview_pin_attachment failed:", err);
  process.exit(1);
});
