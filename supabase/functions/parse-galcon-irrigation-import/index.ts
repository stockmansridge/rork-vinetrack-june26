// =============================================================================
// parse-galcon-irrigation-import — Irrigation Records Phase 2A file parser.
//
// Provider-adapter architecture: this function owns FILE PARSING ONLY for the
// `galcon_gsi` adapter (headers, dates, times, units, valve identity). Every
// business rule — thresholds, Test programs, classification, duplicates,
// mapping, commit, reversal — is enforced by the SQL 142 RPCs, which this
// function calls WITH THE CALLER'S JWT so the shared capability gate
// (SQL 151: `import_irrigation` = vineyard Owner/Manager, or a System
// Administrator member) and RLS always apply. Clients can never insert
// imported sessions directly. Access followed the SQL gate automatically
// at the public release — no code change was required here.
//
// Request (POST, application/json):
//   {
//     "vineyard_id":  "<uuid>",
//     "provider":     "galcon_gsi",
//     "file_name":    "HistoryIrrigation.xlsx",
//     "file_base64":  "<base64 of the raw file bytes>",
//     "timezone":     "Australia/Sydney",        // optional
//     "allow_revalidation": false                 // optional
//   }
//
// Response 200: { ok, batch_id, duplicate_file?, preview, file: {...} }
// Response 4xx: { ok: false, error, missing_headers? }
// =============================================================================

import { createClient } from "npm:@supabase/supabase-js@2";
import * as XLSX from "npm:xlsx@0.18.5";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const MAX_FILE_BYTES = 10 * 1024 * 1024; // 10 MB
const MAX_SOURCE_ROWS = 50_000;
const STAGE_CHUNK = 250;

// ---------------------------------------------------------------------------
// Provider adapter contract — Galcon GSI implementation
// ---------------------------------------------------------------------------
interface ProviderAdapter {
  providerId: string;
  displayName: string;
  supportedFileTypes: string[];
  requiredHeaders: string[];
  optionalHeaders: string[];
  formatMismatchMessage: string;
}

const GALCON_GSI: ProviderAdapter = {
  providerId: "galcon_gsi",
  displayName: "Galcon GSI",
  supportedFileTypes: ["xlsx", "csv"],
  requiredHeaders: [
    "Unit Name", "Date", "Start Time", "End Time", "Program", "Valve Name",
    "Run Time", "Water Quantity", "Average Flow", "Comment",
  ],
  optionalHeaders: ["Irrigation Head", "Fert Program Name", "Fertilizer Quantity"],
  formatMismatchMessage:
    "This file does not match the expected Galcon GSI irrigation export format.",
};

const ADAPTERS: Record<string, ProviderAdapter> = { galcon_gsi: GALCON_GSI };

interface ParsedRow {
  source_row_number: number;
  raw_payload: Record<string, string>;
  parsed_date: string | null;
  parsed_start_time: string | null;
  parsed_end_time: string | null;
  parsed_duration_seconds: number | null;
  parsed_water_litres: number | null;
  parsed_flow_litres_per_hour: number | null;
  original_water_value: number | null;
  original_water_unit: string | null;
  original_flow_value: number | null;
  original_flow_unit: string | null;
  external_valve_number: number | null;
  external_station_code: string | null;
  external_valve_name: string | null;
  external_valve_label: string | null;
  program_name: string | null;
  source_comment: string | null;
  parse_errors: string[];
  parse_warnings: string[];
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function normHeader(h: unknown): string {
  return String(h ?? "").trim().toLowerCase().replace(/\s+/g, " ");
}

function cellText(v: unknown): string {
  if (v === null || v === undefined) return "";
  if (v instanceof Date) return v.toISOString();
  return String(v).trim();
}

/** DD/MM/YYYY (Galcon) → ISO yyyy-mm-dd. Never interprets 06/05 as 5 June. */
function parseGalconDate(v: unknown): string | null {
  if (v instanceof Date) {
    // Date-typed cell: SheetJS parses using the cell's own d/m ordering,
    // which is ambiguous — fall through to text handling via ISO parts.
    const y = v.getUTCFullYear();
    const m = v.getUTCMonth() + 1;
    const d = v.getUTCDate();
    if (y > 1990 && y < 2200) {
      return `${y}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
    }
    return null;
  }
  const t = cellText(v);
  const m = t.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
  if (!m) return null;
  const day = Number(m[1]);
  const month = Number(m[2]);
  const year = Number(m[3]);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  const date = new Date(Date.UTC(year, month - 1, day));
  if (date.getUTCMonth() + 1 !== month || date.getUTCDate() !== day) return null;
  return `${year}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
}

/** HH:MM[:SS] wall-clock time → canonical HH:MM:SS. */
function parseGalconTime(v: unknown): string | null {
  if (typeof v === "number" && v >= 0 && v < 2) {
    // Excel time fraction.
    const total = Math.round(v * 86400);
    const h = Math.floor(total / 3600) % 24;
    const mi = Math.floor((total % 3600) / 60);
    const s = total % 60;
    return `${String(h).padStart(2, "0")}:${String(mi).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
  }
  if (v instanceof Date) {
    return `${String(v.getUTCHours()).padStart(2, "0")}:${String(v.getUTCMinutes()).padStart(2, "0")}:${String(v.getUTCSeconds()).padStart(2, "0")}`;
  }
  const t = cellText(v);
  const m = t.match(/^(\d{1,2}):(\d{2})(?::(\d{2}))?$/);
  if (!m) return null;
  const h = Number(m[1]);
  const mi = Number(m[2]);
  const s = Number(m[3] ?? "0");
  if (h > 23 || mi > 59 || s > 59) return null;
  return `${String(h).padStart(2, "0")}:${String(mi).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

/** Run Time HH:MM:SS → whole seconds. */
function parseRunTimeSeconds(v: unknown): number | null {
  if (typeof v === "number" && v >= 0 && v < 8) {
    return Math.round(v * 86400); // Excel duration fraction
  }
  const t = cellText(v);
  const m = t.match(/^(\d{1,3}):(\d{2})(?::(\d{2}))?$/);
  if (!m) return null;
  return Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3] ?? "0");
}

/**
 * "0.2 m³" / "12 m³/h" / bare "0" → { value, unit }. Bare zeros parse as
 * zero in the known Galcon context (m³); empty cells stay null.
 */
function parseQuantity(v: unknown, defaultUnit: string):
  { value: number | null; unit: string | null; text: string } {
  const t = cellText(v);
  if (t === "") return { value: null, unit: null, text: t };
  const m = t.match(/^(-?\d+(?:[.,]\d+)?)\s*(.*)$/);
  if (!m) return { value: null, unit: null, text: t };
  const value = Number(m[1].replace(",", "."));
  if (!Number.isFinite(value)) return { value: null, unit: null, text: t };
  const unit = (m[2] || "").trim() || defaultUnit;
  return { value, unit, text: t };
}

/**
 * Galcon valve identity: "12 - Shiraz 15-30 (S12)" or "7 - Pinot Noir W1 90-108 S7".
 * Station code variants with/without parentheses are both supported. Row-range
 * text is descriptive only — mapping is always to irrigation_valves.id.
 */
function parseValveName(v: unknown): {
  name: string | null; number: number | null; station: string | null; label: string | null;
} {
  const t = cellText(v);
  if (t === "") return { name: null, number: null, station: null, label: null };
  const m = t.match(/^\s*(\d+)\s*-\s*(.*?)\s*(?:\(\s*(S\d+)\s*\)|(S\d+))?\s*$/i);
  if (!m) return { name: t, number: null, station: null, label: t };
  const station = (m[3] ?? m[4] ?? null)?.toUpperCase() ?? null;
  return {
    name: t,
    number: Number(m[1]),
    station,
    label: m[2].trim() || null,
  };
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes.slice().buffer);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0")).join("");
}

function base64ToBytes(b64: string): Uint8Array {
  const binary = atob(b64.replace(/\s+/g, ""));
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

// ---------------------------------------------------------------------------
// Workbook / CSV → header-mapped rows
// ---------------------------------------------------------------------------
interface SheetData {
  worksheetName: string;
  headers: string[];
  rows: unknown[][];
}

function readWorkbook(bytes: Uint8Array, fileName: string, adapter: ProviderAdapter):
  { sheet?: SheetData; error?: string; missing?: string[] } {
  let wb: XLSX.WorkBook;
  const isCsv = /\.csv$/i.test(fileName) && !(bytes[0] === 0x50 && bytes[1] === 0x4b);
  try {
    if (isCsv) {
      const text = new TextDecoder("utf-8", { fatal: false }).decode(bytes);
      if (text.includes("\uFFFD\uFFFD")) {
        return { error: "The file uses an unsupported text encoding." };
      }
      wb = XLSX.read(text, { type: "string", raw: true });
    } else {
      wb = XLSX.read(bytes, { type: "array", raw: true, cellDates: false });
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    if (/password|encrypted|ECMA-376/i.test(msg)) {
      return { error: "Password-protected workbooks are not supported. Remove the password and upload again." };
    }
    return { error: adapter.formatMismatchMessage };
  }

  const required = adapter.requiredHeaders.map(normHeader);
  let firstMissing: string[] | null = null;

  for (const sheetName of wb.SheetNames) {
    const props = (wb.Workbook?.Sheets ?? []).find((s) => s.name === sheetName);
    if (props && props.Hidden && props.Hidden !== 0) continue; // hidden sheet

    const ws = wb.Sheets[sheetName];
    if (!ws) continue;
    const grid = XLSX.utils.sheet_to_json<unknown[]>(ws, {
      header: 1, raw: true, defval: null, blankrows: false,
    });
    if (grid.length === 0) continue;

    const headerRow = (grid[0] ?? []).map(cellText);
    const normed = headerRow.map(normHeader);

    // Ambiguous duplicate headers are rejected.
    const seen = new Map<string, number>();
    for (const h of normed) {
      if (h) seen.set(h, (seen.get(h) ?? 0) + 1);
    }
    const duplicated = [...seen.entries()].filter(([, n]) => n > 1).map(([h]) => h);

    const missing = adapter.requiredHeaders.filter(
      (rh) => !normed.includes(normHeader(rh)),
    );
    if (missing.length > 0) {
      firstMissing = firstMissing ?? missing;
      continue; // try the next visible worksheet
    }
    if (duplicated.length > 0) {
      return { error: `The file contains ambiguous duplicate columns: ${duplicated.join(", ")}.` };
    }
    void required;
    return {
      sheet: { worksheetName: sheetName, headers: headerRow, rows: grid.slice(1) },
    };
  }

  return {
    error: adapter.formatMismatchMessage,
    missing: firstMissing ?? adapter.requiredHeaders,
  };
}

// ---------------------------------------------------------------------------
// HTTP handler
// ---------------------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json(405, { ok: false, error: "Method not allowed" });

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json(401, { ok: false, error: "Authentication required" });

  let body: {
    vineyard_id?: string; provider?: string; file_name?: string;
    file_base64?: string; timezone?: string; allow_revalidation?: boolean;
  };
  try {
    body = await req.json();
  } catch {
    return json(400, { ok: false, error: "A JSON body is required" });
  }

  const adapter = ADAPTERS[body.provider ?? ""];
  if (!adapter) {
    return json(400, { ok: false, error: `Unsupported import provider: ${body.provider ?? "(none)"}` });
  }
  if (!body.vineyard_id || !body.file_name || !body.file_base64) {
    return json(400, { ok: false, error: "vineyard_id, file_name and file_base64 are required" });
  }
  const ext = (body.file_name.split(".").pop() ?? "").toLowerCase();
  if (!adapter.supportedFileTypes.includes(ext)) {
    return json(400, {
      ok: false,
      error: `Unsupported file type .${ext} — ${adapter.displayName} supports: ${adapter.supportedFileTypes.join(", ")}`,
    });
  }

  let bytes: Uint8Array;
  try {
    bytes = base64ToBytes(body.file_base64);
  } catch {
    return json(400, { ok: false, error: "file_base64 is not valid base64" });
  }
  if (bytes.length === 0) return json(400, { ok: false, error: "The file is empty." });
  if (bytes.length > MAX_FILE_BYTES) {
    return json(400, { ok: false, error: "The file exceeds the 10 MB import limit." });
  }

  const parsedSheet = readWorkbook(bytes, body.file_name, adapter);
  if (!parsedSheet.sheet) {
    return json(422, {
      ok: false,
      error: parsedSheet.error ?? adapter.formatMismatchMessage,
      missing_headers: parsedSheet.missing ?? undefined,
    });
  }
  const { worksheetName, headers, rows } = parsedSheet.sheet;
  if (rows.length === 0) {
    return json(422, { ok: false, error: "The file contains a header row but no data rows." });
  }
  if (rows.length > MAX_SOURCE_ROWS) {
    return json(400, { ok: false, error: "The file exceeds the maximum of 50,000 source rows." });
  }

  const col = new Map<string, number>();
  headers.forEach((h, i) => col.set(normHeader(h), i));
  const get = (row: unknown[], header: string): unknown =>
    row[col.get(normHeader(header)) ?? -1] ?? null;

  // Controller/unit identity: the first non-empty Unit Name. Rows from a
  // DIFFERENT unit are flagged — mappings never silently cross controllers.
  let unitName: string | null = null;
  for (const row of rows) {
    const u = cellText(get(row, "Unit Name"));
    if (u) { unitName = u; break; }
  }

  const parsedRows: ParsedRow[] = rows.map((row, index) => {
    const errors: string[] = [];
    const warnings: string[] = [];

    const raw: Record<string, string> = {};
    headers.forEach((h, i) => {
      const v = cellText(row[i]);
      if (h && v !== "") raw[h] = v;
    });

    const rowUnit = cellText(get(row, "Unit Name"));
    if (unitName && rowUnit && rowUnit !== unitName) {
      errors.push(`unit_mismatch: row belongs to unit "${rowUnit}", not "${unitName}"`);
    }

    const date = parseGalconDate(get(row, "Date"));
    if (!date) errors.push("invalid_date: expected DD/MM/YYYY");
    const startTime = parseGalconTime(get(row, "Start Time"));
    const endTime = parseGalconTime(get(row, "End Time"));
    if (cellText(get(row, "Start Time")) !== "" && !startTime) {
      errors.push("invalid_start_time");
    }
    if (cellText(get(row, "End Time")) !== "" && !endTime) {
      errors.push("invalid_end_time");
    }
    const runtime = parseRunTimeSeconds(get(row, "Run Time"));
    if (cellText(get(row, "Run Time")) !== "" && runtime === null) {
      errors.push("invalid_run_time");
    }

    const water = parseQuantity(get(row, "Water Quantity"), "m³");
    const flow = parseQuantity(get(row, "Average Flow"), "m³/h");
    let waterLitres: number | null = null;
    if (water.value !== null) {
      if (/m³|m3/i.test(water.unit ?? "")) waterLitres = Math.round(water.value * 1000 * 1000) / 1000;
      else if (/^l/i.test(water.unit ?? "")) waterLitres = water.value;
      else if ((water.unit ?? "") === "m³") waterLitres = water.value * 1000;
      else waterLitres = water.value * 1000; // bare number in Galcon context = m³
      if (waterLitres !== null && waterLitres < 0) {
        errors.push("invalid_water_quantity: negative value");
        waterLitres = null;
      }
    } else if (water.text !== "") {
      warnings.push(`Water quantity "${water.text}" could not be parsed`);
    }
    let flowLph: number | null = null;
    if (flow.value !== null) {
      if (/l\s*\/\s*h/i.test(flow.unit ?? "") && !/m³|m3/i.test(flow.unit ?? "")) flowLph = flow.value;
      else flowLph = Math.round(flow.value * 1000 * 1000) / 1000; // m³/h → L/h
      if (flowLph !== null && flowLph < 0) {
        errors.push("invalid_average_flow: negative value");
        flowLph = null;
      }
    } else if (flow.text !== "") {
      warnings.push(`Average flow "${flow.text}" could not be parsed`);
    }

    const valve = parseValveName(get(row, "Valve Name"));
    if (!valve.name) errors.push("missing_valve_name");
    else if (valve.number === null && valve.station === null) {
      warnings.push(`Valve name "${valve.name}" has no station code or valve number`);
    }

    return {
      source_row_number: index + 2, // 1-based + header row
      raw_payload: raw,
      parsed_date: date,
      parsed_start_time: startTime,
      parsed_end_time: endTime,
      parsed_duration_seconds: runtime,
      parsed_water_litres: waterLitres,
      parsed_flow_litres_per_hour: flowLph,
      original_water_value: water.value,
      original_water_unit: water.value !== null ? (water.unit ?? "m³") : null,
      original_flow_value: flow.value,
      original_flow_unit: flow.value !== null ? (flow.unit ?? "m³/h") : null,
      external_valve_number: valve.number,
      external_station_code: valve.station,
      external_valve_name: valve.name,
      external_valve_label: valve.label,
      program_name: cellText(get(row, "Program")) || null,
      source_comment: cellText(get(row, "Comment")) || null,
      parse_errors: errors,
      parse_warnings: warnings,
    };
  });

  // --- Stage through the SQL 142 RPCs using the CALLER'S credentials -------
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const supabase = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });

  const fileHash = await sha256Hex(bytes);
  const batchId = crypto.randomUUID();

  const { data: createData, error: createError } = await supabase.rpc(
    "create_irrigation_import_batch",
    {
      p_id: batchId,
      p_vineyard_id: body.vineyard_id,
      p_provider: adapter.providerId,
      p_file_name: body.file_name,
      p_file_hash: fileHash,
      p_file_size: bytes.length,
      p_worksheet_name: worksheetName,
      p_source_unit_name: unitName,
      p_total_rows: parsedRows.length,
      p_timezone: body.timezone ?? null,
      p_allow_revalidation: body.allow_revalidation ?? false,
    },
  );
  if (createError) {
    const status = /import_access_denied/.test(createError.message) ? 403 : 400;
    return json(status, { ok: false, error: createError.message });
  }
  if (createData?.duplicate_file) {
    return json(200, {
      ok: true,
      duplicate_file: true,
      batch_id: createData.batch?.id,
      message: createData.message,
      batch: createData.batch,
    });
  }
  const realBatchId: string = createData?.batch?.id ?? batchId;

  for (let i = 0; i < parsedRows.length; i += STAGE_CHUNK) {
    const chunk = parsedRows.slice(i, i + STAGE_CHUNK);
    const { error: stageError } = await supabase.rpc("stage_irrigation_import_rows", {
      p_batch_id: realBatchId,
      p_rows: chunk,
    });
    if (stageError) {
      return json(400, {
        ok: false,
        error: `Row staging failed at rows ${i + 1}–${i + chunk.length}: ${stageError.message}`,
        batch_id: realBatchId,
      });
    }
  }

  const { data: preview, error: validateError } = await supabase.rpc(
    "validate_irrigation_import",
    { p_batch_id: realBatchId },
  );
  if (validateError) {
    return json(400, { ok: false, error: validateError.message, batch_id: realBatchId });
  }

  return json(200, {
    ok: true,
    batch_id: realBatchId,
    duplicate_file: false,
    file: {
      name: body.file_name,
      sha256: fileHash,
      size_bytes: bytes.length,
      worksheet: worksheetName,
      unit_name: unitName,
      source_rows: parsedRows.length,
      rows_with_parse_errors: parsedRows.filter((r) => r.parse_errors.length > 0).length,
    },
    preview,
  });
});
