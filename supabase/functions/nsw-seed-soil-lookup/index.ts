// Supabase Edge Function: nsw-seed-soil-lookup
//
// Phase 2 of the soil-aware irrigation model.
//
// Looks up NSW soil landscape information for a paddock centroid (or an
// arbitrary lat/lon) by querying the public NSW Department of Climate
// Change, Energy, the Environment and Water (DCCEEW) "Soil Landscapes of
// Central and Eastern NSW" ArcGIS Map Service. The NSW SEED dataset
// catalogue lists this same service as the canonical ArcGIS REST endpoint:
//
//   https://mapprod1.environment.nsw.gov.au/arcgis/rest/services/Soil/
//     SoilLandscapes_CentralAndEasternNSW/MapServer/0
//
// Layer 0 is "Soil Landscapes - published 100K - 250K" (Feature Layer,
// polygon, WGS84/GDA94 compatible). The point-in-polygon query is fully
// supported, returns the soil landscape NAME, SALIS_CODE, REPORT flag and
// related metadata, and does not require an API key for the public layer.
//
// The endpoint URL is configurable via the optional Supabase secret
// `NSW_SEED_SOIL_LANDSCAPE_URL` so we can swap to a different DCCEEW /
// Spatial Services layer (e.g. Soil and Land Resources, eSPADE soil profile
// service, Land and Soil Capability) without redeploying code. If a future
// authenticated NSW SEED service is required, set `NSW_SEED_API_KEY` and it
// will be appended as the `token` query parameter on every upstream call.
//
// Secrets:
//   NSW_SEED_SOIL_LANDSCAPE_URL  optional, overrides the default endpoint
//   NSW_SEED_API_KEY             optional, sent as `?token=...` if set
//
// The iOS app and the Lovable portal NEVER receive either secret — they
// only call this Edge Function with the user's Supabase JWT.
//
// Auth: caller must send the Supabase JWT in the Authorization header and
//       be a member of the target vineyard. Lookup is currently only
//       allowed for vineyards whose country resolves to AU/NSW. The
//       country check is best-effort and accepts vineyards without an
//       explicit country code as long as the requested point falls inside
//       the NSW soil landscape coverage.
//
// Actions:
//   - health                  → reports endpoint + secret configuration
//   - lookup_point            → { vineyardId, lat, lon }
//   - lookup_paddock_soil     → { vineyardId, paddockId }  (uses centroid)
//
// All responses include a `disclaimer` field that the client should show
// any time NSW SEED soil data is rendered.

// deno-lint-ignore-file no-explicit-any

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const PROXY_VERSION = "nsw-seed-soil-lookup-2026-05-16-v3";

// Default public endpoints from the NSW SEED / DCCEEW dataset catalogue.
// These are the same ArcGIS Map Services that power the public "Soils
// Near Me NSW" viewer:
//
//   Soil Landscapes (NAME, SALIS_CODE)             → SOIL_LANDSCAPE
//   Australian Soil Classification (ASC_order)     → ASC
//   Land and Soil Capability (LSC_MstLmt 1–8)       → LSC
//
// All three are public — no token required — but the URLs can be
// overridden via Supabase secrets if NSW ever rotates them.
const DEFAULT_SOIL_LANDSCAPE_URL =
  "https://mapprod1.environment.nsw.gov.au/arcgis/rest/services/Soil/SoilLandscapes_CentralAndEasternNSW/MapServer/0";
const DEFAULT_ASC_URL =
  "https://mapprod1.environment.nsw.gov.au/arcgis/rest/services/Soil/Soils_ASC_SoilTypes_EDP/MapServer/2";
const DEFAULT_LSC_URL =
  "https://mapprod1.environment.nsw.gov.au/arcgis/rest/services/LandCap/LandAndSoilCapability_EDP/MapServer/2";

// The default mapprod1 layer is a public ArcGIS service and rejects requests
// that include an unrecognised `token` parameter. We therefore only append the
// NSW_SEED_API_KEY when either (a) the operator has explicitly opted in via
// NSW_SEED_FORCE_TOKEN=true, or (b) a custom NSW_SEED_SOIL_LANDSCAPE_URL has
// been configured (assumed to be the authenticated SEED endpoint).
function shouldSendTokenByDefault(endpoint: string): boolean {
  const force = Deno.env.get("NSW_SEED_FORCE_TOKEN")?.trim().toLowerCase();
  if (force === "true" || force === "1" || force === "yes") return true;
  const usingDefault = endpoint.replace(/\/$/, "") ===
    DEFAULT_SOIL_LANDSCAPE_URL.replace(/\/$/, "");
  return !usingDefault;
}

function isArcgisAuthError(body: any): boolean {
  const err = body && typeof body === "object" ? body.error : null;
  if (!err || typeof err !== "object") return false;
  const code = Number(err.code);
  if ([401, 403, 498, 499].includes(code)) return true;
  const msg = String(err.message ?? "").toLowerCase();
  return msg.includes("token") || msg.includes("unauthorized") || msg.includes("not authorized");
}

const DISCLAIMER =
  "Soil information is estimated from NSW SEED mapping and may not reflect site-specific vineyard soil conditions. Adjust soil class and water-holding values using your own soil knowledge where needed.";

const MODEL_VERSION = "soil_aware_irrigation_v2";

function json(body: unknown, status = 200): Response {
  let payload: unknown = body;
  if (body && typeof body === "object" && !Array.isArray(body)) {
    payload = { _proxy_version: PROXY_VERSION, ...(body as Record<string, unknown>) };
  }
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

function num(v: unknown): number | null {
  if (v == null) return null;
  const n = typeof v === "number" ? v : Number(v);
  return isFinite(n) ? n : null;
}

function getSoilLandscapeUrl(): string | null {
  const override = Deno.env.get("NSW_SEED_SOIL_LANDSCAPE_URL")?.trim();
  if (override && override.length > 0) return override.replace(/\/$/, "");
  return DEFAULT_SOIL_LANDSCAPE_URL;
}

function getAscUrl(): string {
  const override = Deno.env.get("NSW_SEED_ASC_URL")?.trim();
  if (override && override.length > 0) return override.replace(/\/$/, "");
  return DEFAULT_ASC_URL;
}

function getLscUrl(): string {
  const override = Deno.env.get("NSW_SEED_LSC_URL")?.trim();
  if (override && override.length > 0) return override.replace(/\/$/, "");
  return DEFAULT_LSC_URL;
}

function getApiKey(): string | null {
  const k = Deno.env.get("NSW_SEED_API_KEY")?.trim();
  return k && k.length > 0 ? k : null;
}

// ---------------------------------------------------------------------------
// Polygon centroid (planar approximation — accurate enough for paddock-scale
// soil landscape lookup at NSW SEED's 1:100k–1:250k resolution).
// ---------------------------------------------------------------------------

interface LatLon { lat: number; lon: number; }

function polygonCentroid(points: LatLon[]): LatLon | null {
  if (!Array.isArray(points) || points.length === 0) return null;
  if (points.length === 1) return points[0];
  if (points.length === 2) {
    return {
      lat: (points[0].lat + points[1].lat) / 2,
      lon: (points[0].lon + points[1].lon) / 2,
    };
  }
  // Shoelace centroid; falls back to vertex average if area degenerates.
  let area = 0;
  let cx = 0;
  let cy = 0;
  const n = points.length;
  for (let i = 0; i < n; i++) {
    const p0 = points[i];
    const p1 = points[(i + 1) % n];
    const cross = p0.lon * p1.lat - p1.lon * p0.lat;
    area += cross;
    cx += (p0.lon + p1.lon) * cross;
    cy += (p0.lat + p1.lat) * cross;
  }
  area *= 0.5;
  if (Math.abs(area) < 1e-12) {
    let sumLat = 0;
    let sumLon = 0;
    for (const p of points) { sumLat += p.lat; sumLon += p.lon; }
    return { lat: sumLat / n, lon: sumLon / n };
  }
  return { lat: cy / (6 * area), lon: cx / (6 * area) };
}

function extractPolygonPoints(raw: unknown): LatLon[] {
  if (!Array.isArray(raw)) return [];
  const out: LatLon[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const lat = num((item as any).latitude ?? (item as any).lat);
    const lon = num((item as any).longitude ?? (item as any).lon ?? (item as any).lng);
    if (lat != null && lon != null) out.push({ lat, lon });
  }
  return out;
}

// ---------------------------------------------------------------------------
// NSW SEED ArcGIS query
// ---------------------------------------------------------------------------

interface QueryAttempt {
  ok: boolean;
  status: number;
  body: any;
  url_safe: string;        // URL with `token` redacted
  token_used: boolean;
}

function buildQueryUrl(endpoint: string, lat: number, lon: number, token: string | null): URL {
  const u = new URL(`${endpoint}/query`);
  u.searchParams.set("geometry", `${lon},${lat}`);
  u.searchParams.set("geometryType", "esriGeometryPoint");
  u.searchParams.set("inSR", "4326");
  u.searchParams.set("spatialRel", "esriSpatialRelIntersects");
  u.searchParams.set("outFields", "*");
  u.searchParams.set("returnGeometry", "false");
  u.searchParams.set("f", "json");
  if (token) u.searchParams.set("token", token);
  return u;
}

function redactToken(u: URL): string {
  const safe = new URL(u.toString());
  if (safe.searchParams.has("token")) safe.searchParams.set("token", "***");
  return safe.toString();
}

async function doQuery(endpoint: string, lat: number, lon: number, token: string | null): Promise<QueryAttempt> {
  const u = buildQueryUrl(endpoint, lat, lon, token);
  const url_safe = redactToken(u);
  let res: Response;
  try {
    res = await fetch(u.toString(), { headers: { Accept: "application/json" } });
  } catch (e) {
    return { ok: false, status: 0, body: { error: String(e) }, url_safe, token_used: token != null };
  }
  const text = await res.text();
  let parsed: any = null;
  try { parsed = JSON.parse(text); } catch { parsed = text; }
  return { ok: res.ok, status: res.status, body: parsed, url_safe, token_used: token != null };
}

async function querySoilLandscape(
  endpoint: string,
  apiKey: string | null,
  lat: number,
  lon: number,
): Promise<{ ok: boolean; status: number; body: any; attempts: QueryAttempt[] }> {
  const sendToken = apiKey != null && shouldSendTokenByDefault(endpoint);
  const attempts: QueryAttempt[] = [];

  const first = await doQuery(endpoint, lat, lon, sendToken ? apiKey : null);
  attempts.push(first);

  // Retry once without token if ArcGIS returned an auth/token error.
  const needsRetry = first.token_used && (
    (!first.ok && (first.status === 401 || first.status === 403 || first.status === 498 || first.status === 499)) ||
    isArcgisAuthError(first.body)
  );
  if (needsRetry) {
    const second = await doQuery(endpoint, lat, lon, null);
    attempts.push(second);
    return { ok: second.ok, status: second.status, body: second.body, attempts };
  }
  return { ok: first.ok, status: first.status, body: first.body, attempts };
}

// ---------------------------------------------------------------------------
// Combined ASC + Soil Landscape + LSC → irrigation soil class mapping.
//
// V2 reads the Australian Soil Classification order (e.g. Ferrosols,
// Vertosols) plus the Soil Landscape name/SALIS code and the Land and
// Soil Capability "most-limiting" class (1–8) to derive a more useful
// irrigation soil class than the keyword-only v1 mapping.
//
// Per user guidance on basalt mapping:
//   * basalt + clay loam keywords → basalt_clay_loam
//   * basalt alone → basalt_clay_loam at lower confidence
//   * otherwise the texture keyword wins.
//
// ASC overrides — when ASC is present it drives the class because it is
// the authoritative soil-type classification:
//   Ferrosols + basalt/volcanic context → basalt_clay_loam (medium)
//   Ferrosols (no basalt context)       → clay_loam (medium)
//   Vertosols                           → clay_heavy_clay (medium)
//   Dermosols / Kurosols / Sodosols     → clay_loam (medium)
//   Chromosols                          → clay_loam (medium)
//   Kandosols / Calcarosols             → loam (medium)
//   Tenosols                            → sandy_loam (low)
//   Rudosols / Podosols                 → sand_loamy_sand (low)
//   Hydrosols                           → clay_loam (low)
//   Organosols / Anthroposols           → unknown (low)
// ---------------------------------------------------------------------------

interface SoilClassGuess {
  irrigation_soil_class: string;
  confidence: "low" | "medium" | "high";
  matched_keywords: string[];
}

// LSC "most-limiting" integer (1–8) → friendly label used by Soils Near Me.
function landSoilCapabilityLabel(cls: number | null): string | null {
  if (cls == null || !isFinite(cls)) return null;
  if (cls >= 1 && cls <= 3) return "High capability land";
  if (cls >= 4 && cls <= 5) return "Moderate capability land";
  if (cls >= 6 && cls <= 8) return "Low capability land";
  return null;
}

function guessFromAsc(
  ascOrder: string | null,
  landscapeHay: string,
  matched: string[],
): { cls: string; conf: "low" | "medium" | "high" } | null {
  if (!ascOrder) return null;
  const a = ascOrder.trim().toLowerCase();
  if (!a) return null;
  matched.push(`asc:${a}`);
  const hasBasaltContext = landscapeHay.includes("basalt") || landscapeHay.includes("volcanic");
  if (a.startsWith("ferrosol")) {
    return hasBasaltContext
      ? { cls: "basalt_clay_loam", conf: "medium" }
      : { cls: "clay_loam", conf: "medium" };
  }
  if (a.startsWith("vertosol")) return { cls: "clay_heavy_clay", conf: "medium" };
  if (a.startsWith("dermosol")) return { cls: "clay_loam", conf: "medium" };
  if (a.startsWith("kurosol")) return { cls: "clay_loam", conf: "medium" };
  if (a.startsWith("sodosol")) return { cls: "clay_loam", conf: "medium" };
  if (a.startsWith("chromosol")) return { cls: "clay_loam", conf: "medium" };
  if (a.startsWith("kandosol")) return { cls: "loam", conf: "medium" };
  if (a.startsWith("calcarosol")) return { cls: "loam", conf: "medium" };
  if (a.startsWith("tenosol")) return { cls: "sandy_loam", conf: "low" };
  if (a.startsWith("rudosol")) return { cls: "sand_loamy_sand", conf: "low" };
  if (a.startsWith("podosol")) return { cls: "sand_loamy_sand", conf: "low" };
  if (a.startsWith("hydrosol")) return { cls: "clay_loam", conf: "low" };
  if (a.startsWith("organosol")) return { cls: "unknown", conf: "low" };
  if (a.startsWith("anthroposol")) return { cls: "unknown", conf: "low" };
  return null;
}

// Known NSW soil-landscape names whose dominant material is basalt-derived,
// based on the NSW Soil Landscape series (eSPADE). When ASC is missing we use
// this list to give a useful basalt_clay_loam suggestion instead of falling
// all the way through to "unknown".
const BASALT_LANDSCAPE_KEYWORDS: string[] = [
  "towac", "orange", "lidster", "canobolas", "millthorpe",
  "byng", "borenore", "mullion", "comboyne", "dorrigo",
  "ebor", "guyra", "glen innes", "inverell", "tenterfield",
  "bega", "cobargo", "robertson", "moss vale",
];

function guessIrrigationSoilClass(
  name: string | null,
  salisCode: string | null,
  ascOrder: string | null = null,
): SoilClassGuess {
  const hay = `${name ?? ""} ${salisCode ?? ""}`.toLowerCase();
  const matched: string[] = [];

  const landscapeIsBasaltDerived = BASALT_LANDSCAPE_KEYWORDS.some((kw) => {
    if (hay.includes(kw)) { matched.push(`landscape:${kw}`); return true; }
    return false;
  });

  // ASC drives the answer when present.
  const fromAsc = guessFromAsc(ascOrder, hay, matched);
  if (fromAsc) {
    if (hay.includes("basalt")) matched.push("basalt");
    // Promote Ferrosols to basalt_clay_loam when the landscape name
    // resolves to a known basalt-derived NSW landscape even without an
    // explicit "basalt" keyword in the attributes.
    if (landscapeIsBasaltDerived && fromAsc.cls === "clay_loam"
        && ascOrder && ascOrder.toLowerCase().startsWith("ferrosol")) {
      return {
        irrigation_soil_class: "basalt_clay_loam",
        confidence: fromAsc.conf,
        matched_keywords: matched,
      };
    }
    return {
      irrigation_soil_class: fromAsc.cls,
      confidence: fromAsc.conf,
      matched_keywords: matched,
    };
  }

  // No ASC but the landscape name matches a known basalt-derived NSW
  // landscape → return basalt_clay_loam with low confidence so the user
  // still gets a useful suggestion (Towac/Orange/Lidster etc.).
  if (landscapeIsBasaltDerived) {
    return {
      irrigation_soil_class: "basalt_clay_loam",
      confidence: "low",
      matched_keywords: matched,
    };
  }

  // Fallback to landscape keyword heuristic when ASC is missing or
  // unrecognised — same logic as v1.
  const has = (kw: string) => {
    if (hay.includes(kw)) { matched.push(kw); return true; }
    return false;
  };

  const hasBasalt = has("basalt");
  const hasClayLoam = has("clay loam");
  const hasHeavyClay = has("heavy clay");
  const hasClay = has("clay");
  const hasSiltLoam = has("silt loam");
  const hasSilt = has("silt");
  const hasSandyLoam = has("sandy loam");
  const hasLoamySand = has("loamy sand");
  const hasLoam = has("loam");
  const hasSand = has("sand");
  const hasRocky = has("rocky") || has("shallow") || has("skeletal") || has("lithosol");

  if (hasBasalt && hasClayLoam) {
    return { irrigation_soil_class: "basalt_clay_loam", confidence: "medium", matched_keywords: matched };
  }
  if (hasHeavyClay) {
    return { irrigation_soil_class: "clay_heavy_clay", confidence: "medium", matched_keywords: matched };
  }
  if (hasClayLoam) {
    return { irrigation_soil_class: "clay_loam", confidence: "medium", matched_keywords: matched };
  }
  if (hasClay) {
    return { irrigation_soil_class: "clay_heavy_clay", confidence: "low", matched_keywords: matched };
  }
  if (hasSiltLoam || hasSilt) {
    return { irrigation_soil_class: "silt_loam", confidence: "medium", matched_keywords: matched };
  }
  if (hasSandyLoam) {
    return { irrigation_soil_class: "sandy_loam", confidence: "medium", matched_keywords: matched };
  }
  if (hasLoamySand) {
    return { irrigation_soil_class: "sand_loamy_sand", confidence: "medium", matched_keywords: matched };
  }
  if (hasLoam) {
    return { irrigation_soil_class: "loam", confidence: "medium", matched_keywords: matched };
  }
  if (hasSand) {
    return { irrigation_soil_class: "sand_loamy_sand", confidence: "low", matched_keywords: matched };
  }
  if (hasRocky) {
    return { irrigation_soil_class: "shallow_rocky", confidence: "low", matched_keywords: matched };
  }
  if (hasBasalt) {
    // Basalt alone, texture unclear — keep the basalt mapping but at low confidence.
    return { irrigation_soil_class: "basalt_clay_loam", confidence: "low", matched_keywords: matched };
  }
  return { irrigation_soil_class: "unknown", confidence: "low", matched_keywords: matched };
}

interface LayerResults {
  landscape: { feature: any; attrs: any } | null;
  asc: { feature: any; attrs: any } | null;
  lsc: { feature: any; attrs: any } | null;
}

function buildSoilProfileSuggestion(
  layers: LayerResults,
  endpoint: string,
  origin: { lat: number; lon: number },
): Record<string, unknown> {
  const lAttrs = layers.landscape?.attrs ?? {};
  const aAttrs = layers.asc?.attrs ?? {};
  const sAttrs = layers.lsc?.attrs ?? {};

  const name = typeof lAttrs?.NAME === "string" ? lAttrs.NAME : null;
  const salisCode = typeof lAttrs?.SALIS_CODE === "string"
    ? lAttrs.SALIS_CODE
    : (typeof lAttrs?.CODE === "string" ? lAttrs.CODE : null);

  const ascOrder = typeof aAttrs?.ASC_order === "string" ? aAttrs.ASC_order : null;
  const ascCode = typeof aAttrs?.ASC_code === "string" ? aAttrs.ASC_code : null;

  const lscMostLimiting = num(sAttrs?.LSC_MstLmt);
  const lscLabel = landSoilCapabilityLabel(lscMostLimiting);

  const guess = guessIrrigationSoilClass(name, salisCode, ascOrder);

  return {
    source: "nsw_seed",
    source_provider: "nsw_seed",
    source_dataset: "SoilsNearMe_Combined",
    source_feature_id: salisCode
      ?? (lAttrs?.OBJECTID != null ? String(lAttrs.OBJECTID) : null)
      ?? (aAttrs?.OBJECTID != null ? String(aAttrs.OBJECTID) : null),
    source_name: name,
    source_endpoint: endpoint,
    country_code: "AU",
    region_code: "NSW",
    irrigation_soil_class: guess.irrigation_soil_class,
    confidence: guess.confidence,
    matched_keywords: guess.matched_keywords,
    lookup_latitude: origin.lat,
    lookup_longitude: origin.lon,
    soil_landscape: name,
    soil_landscape_code: salisCode,
    australian_soil_classification: ascOrder,
    australian_soil_classification_code: ascCode,
    land_soil_capability: lscLabel,
    land_soil_capability_class: lscMostLimiting,
    model_version: MODEL_VERSION,
    is_manual_override: false,
    disclaimer: DISCLAIMER,
    raw_attributes: {
      landscape: lAttrs,
      asc: aAttrs,
      lsc: sAttrs,
    },
  };
}

// ---------------------------------------------------------------------------
// Country / region gating.
// ---------------------------------------------------------------------------

function isAustraliaCountry(country: unknown): boolean {
  if (typeof country !== "string") return false;
  const c = country.trim().toLowerCase();
  if (!c) return false;
  return c === "au" || c === "aus" || c === "australia";
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  if (!supabaseUrl || !serviceKey || !anonKey) {
    return json({ error: "Server misconfigured" }, 500);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return json({ error: "Authentication required" }, 401);
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userRes, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userRes?.user) return json({ error: "Authentication required" }, 401);
  const userId = userRes.user.id;

  let body: any;
  try { body = await req.json(); } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const action = typeof body?.action === "string" ? body.action : null;
  if (!action) return json({ error: "action is required" }, 400);

  const endpoint = getSoilLandscapeUrl();
  const apiKey = getApiKey();
  const usingDefaultEndpoint = !Deno.env.get("NSW_SEED_SOIL_LANDSCAPE_URL")?.trim();

  // ---- health (no vineyard required) ------------------------------------
  if (action === "health") {
    return json({
      success: true,
      endpoint,
      asc_endpoint: getAscUrl(),
      lsc_endpoint: getLscUrl(),
      using_default_endpoint: usingDefaultEndpoint,
      has_api_key: apiKey != null,
      sends_token_by_default: apiKey != null && shouldSendTokenByDefault(endpoint),
      disclaimer: DISCLAIMER,
      model_version: MODEL_VERSION,
    });
  }

  if (!endpoint) {
    return json({
      success: false,
      error: "NSW SEED soil landscape endpoint is not configured.",
      reason: "missing_soil_landscape_endpoint",
    }, 503);
  }

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const vineyardId = typeof body?.vineyardId === "string" ? body.vineyardId : null;
  if (!vineyardId) return json({ error: "vineyardId is required" }, 400);

  // Membership check (any role can read).
  const { data: memberRow, error: memberErr } = await admin
    .from("vineyard_members")
    .select("role")
    .eq("vineyard_id", vineyardId)
    .eq("user_id", userId)
    .maybeSingle();
  if (memberErr) return json({ error: memberErr.message }, 500);
  if (!memberRow) return json({ error: "Not a vineyard member" }, 403);

  // Country gating — best-effort, accepts AU vineyards. If the vineyard has
  // no country recorded yet we still allow the lookup; the NSW SEED service
  // simply returns no features for points outside coverage.
  const { data: vineyardRow } = await admin
    .from("vineyards")
    .select("id, country_code")
    .eq("id", vineyardId)
    .maybeSingle();
  const country = (vineyardRow as any)?.country_code ?? null;
  if (country != null && country !== "" && !isAustraliaCountry(country)) {
    return json({
      success: false,
      error: "NSW SEED lookup is only available for Australian vineyards.",
      reason: "unsupported_country",
      country,
    }, 400);
  }

  // ---- lookup_point -----------------------------------------------------
  if (action === "lookup_point") {
    const lat = num(body?.lat);
    const lon = num(body?.lon ?? body?.lng);
    if (lat == null || lon == null) {
      return json({ error: "lat and lon are required", reason: "missing_params" }, 400);
    }
    return await runLookup(endpoint, apiKey, lat, lon, null);
  }

  // ---- lookup_paddock_soil ---------------------------------------------
  if (action === "lookup_paddock_soil") {
    const paddockId = typeof body?.paddockId === "string" ? body.paddockId : null;
    if (!paddockId) return json({ error: "paddockId is required" }, 400);

    const { data: paddockRow, error: paddockErr } = await admin
      .from("paddocks")
      .select("id, vineyard_id, name, polygon_points")
      .eq("id", paddockId)
      .maybeSingle();
    if (paddockErr) return json({ error: paddockErr.message }, 500);
    if (!paddockRow) return json({ error: "Paddock not found", reason: "paddock_not_found" }, 404);
    if (String((paddockRow as any).vineyard_id) !== vineyardId) {
      return json({ error: "Paddock does not belong to vineyard", reason: "paddock_wrong_vineyard" }, 403);
    }

    const polygon = extractPolygonPoints((paddockRow as any).polygon_points);
    const centroid = polygonCentroid(polygon);
    if (!centroid) {
      return json({
        success: false,
        error: "Paddock has no polygon to derive a centroid from.",
        reason: "paddock_missing_polygon",
      }, 400);
    }
    return await runLookup(endpoint, apiKey, centroid.lat, centroid.lon, paddockId);
  }

  return json({ error: `Unknown action: ${action}` }, 400);
});

async function runLookup(
  endpoint: string,
  apiKey: string | null,
  lat: number,
  lon: number,
  paddockId: string | null,
): Promise<Response> {
  const ascEndpoint = getAscUrl();
  const lscEndpoint = getLscUrl();

  // Query all three layers in parallel. ASC + LSC are public and never
  // need a token; only the (configurable) landscape endpoint may use one.
  const [landscape, asc, lsc] = await Promise.all([
    querySoilLandscape(endpoint, apiKey, lat, lon),
    querySoilLandscape(ascEndpoint, null, lat, lon),
    querySoilLandscape(lscEndpoint, null, lat, lon),
  ]);

  const diagnostics = {
    endpoint,
    asc_endpoint: ascEndpoint,
    lsc_endpoint: lscEndpoint,
    using_default_endpoint: !Deno.env.get("NSW_SEED_SOIL_LANDSCAPE_URL")?.trim(),
    layers: {
      landscape: summariseAttempts(landscape),
      asc: summariseAttempts(asc),
      lsc: summariseAttempts(lsc),
    },
  };

  // Treat the lookup as upstream-failed only when the primary landscape
  // layer fails AND ASC also fails — if at least one classification layer
  // succeeded we can still return a useful suggestion.
  const landscapeArcError = landscape.body && typeof landscape.body === "object" && landscape.body.error;
  const ascArcError = asc.body && typeof asc.body === "object" && asc.body.error;
  const lscArcError = lsc.body && typeof lsc.body === "object" && lsc.body.error;
  const landscapeOk = landscape.ok && !landscapeArcError;
  const ascOk = asc.ok && !ascArcError;
  const lscOk = lsc.ok && !lscArcError;

  if (!landscapeOk && !ascOk && !lscOk) {
    return json({
      success: false,
      error: "NSW SEED upstream request failed.",
      reason: "upstream_error",
      http_status: landscape.status,
      upstream: landscape.body,
      diagnostics,
      endpoint,
      disclaimer: DISCLAIMER,
    }, 502);
  }

  const landscapeFeatures = landscapeOk && Array.isArray(landscape.body?.features) ? landscape.body.features : [];
  const ascFeatures = ascOk && Array.isArray(asc.body?.features) ? asc.body.features : [];
  const lscFeatures = lscOk && Array.isArray(lsc.body?.features) ? lsc.body.features : [];

  if (landscapeFeatures.length === 0 && ascFeatures.length === 0 && lscFeatures.length === 0) {
    return json({
      success: true,
      found: false,
      lookup_latitude: lat,
      lookup_longitude: lon,
      paddock_id: paddockId,
      message:
        "No NSW SEED soil mapping polygon was found at this location. The point may be outside the central/eastern NSW coverage.",
      diagnostics,
      endpoint,
      disclaimer: DISCLAIMER,
      model_version: MODEL_VERSION,
    });
  }

  const layerResults: LayerResults = {
    landscape: landscapeFeatures.length > 0
      ? { feature: landscapeFeatures[0], attrs: landscapeFeatures[0]?.attributes ?? {} }
      : null,
    asc: ascFeatures.length > 0
      ? { feature: ascFeatures[0], attrs: ascFeatures[0]?.attributes ?? {} }
      : null,
    lsc: lscFeatures.length > 0
      ? { feature: lscFeatures[0], attrs: lscFeatures[0]?.attributes ?? {} }
      : null,
  };

  const suggestion = buildSoilProfileSuggestion(layerResults, endpoint, { lat, lon });
  return json({
    success: true,
    found: true,
    paddock_id: paddockId,
    suggestion,
    feature_count: landscapeFeatures.length + ascFeatures.length + lscFeatures.length,
    raw_features: {
      landscape: layerResults.landscape?.feature ?? null,
      asc: layerResults.asc?.feature ?? null,
      lsc: layerResults.lsc?.feature ?? null,
    },
    diagnostics,
    endpoint,
    disclaimer: DISCLAIMER,
    model_version: MODEL_VERSION,
  });
}

function summariseAttempts(r: { ok: boolean; status: number; body: any; attempts: QueryAttempt[] }) {
  return {
    ok: r.ok,
    http_status: r.status,
    feature_count: Array.isArray(r.body?.features) ? r.body.features.length : 0,
    arcgis_error: r.body && typeof r.body === "object" ? r.body.error ?? null : null,
    attempts: r.attempts.map((a) => ({
      url_safe: a.url_safe,
      token_used: a.token_used,
      http_status: a.status,
      arcgis_error: a.body && typeof a.body === "object" ? a.body.error ?? null : null,
    })),
  };
}
