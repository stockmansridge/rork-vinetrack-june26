// AU authoritative source adapter — APVMA PubCRIS register extract.
//
// GOVERNMENT REGISTRATION SOURCE (highest authority)
//   The APVMA-published PubCRIS dataset on data.gov.au (CKAN datastore API,
//   refreshed weekly by the APVMA, CC-BY). It provides registered product
//   identity (pcode = APVMA product number), verbatim registered product
//   name, registrant of record, category/formulation, registration status
//   and expiry, the product's active constituents WITH concentrations and
//   units, and the current approved-label registration record.
//
// LABEL AUTHORITY
//   The APVMA-approved label itself. The register extract points at it
//   (labelreg approval number + date, carried as `label_version`); the label
//   DOCUMENT is not machine-consumed here, so label-only facts (directions
//   for use, rates, WHP, re-entry) stay unresolved for the admin to confirm
//   against the label at review. They are never invented.
//
// WHAT THIS ADAPTER WILL NEVER DO
//   * Resolve by substring or fuzzy similarity ("custodia" can never reach
//     "Custodia Forte").
//   * Borrow a foreign register/label because a product name matches — it
//     only ever queries the AU register.
//   * Treat "source unavailable" as "product not registered".
//   * Fabricate a value the register does not provide.

import { reconcileGroup } from "./activity_groups.ts";
import type {
  AdapterDeps,
  DiscoveryResult,
  ResolvedRegistration,
  SourceAdapter,
  WireActiveIngredient,
  WireDataSource,
} from "./contract.ts";
import { identityKey } from "./contract.ts";
import {
  NEGATIVE_TTL_MS,
  RESOLVED_TTL_MS,
  SourceCache,
  UNAVAILABLE_TTL_MS,
} from "./cache.ts";

export const APVMA_DATASTORE_URL =
  "https://data.gov.au/data/api/3/action/datastore_search";

/** APVMA PubCRIS dataset resources (data.gov.au, published by the APVMA). */
export const APVMA_RESOURCES = {
  /** product.csv — registered products (pcode, fpname, sname, regcode…). */
  product: "b4bb5394-b60b-4602-8bde-2e206ffc498f",
  /** prodcon.csv — product↔constituent with camount/cucode. */
  productConstituents: "eb08d8fc-bb61-4191-9a4b-a20ee44dac1f",
  /** constit.csv — constituent code → constituent name. */
  constituentNames: "de913672-c51a-483a-b467-f2f9df51f671",
  /** labelreg.csv — current approved label registration per product. */
  labelRegistrations: "a83d500d-b47a-4f03-9d77-4c0524217855",
} as const;

const FETCH_TIMEOUT_MS = 8000;

class SourceUnavailableError extends Error {
  readonly category: string;
  constructor(category: string, message: string) {
    super(message);
    this.category = category;
  }
}

interface ProductRecord {
  pcode: string;
  fpname: string;
  sname: string | null;
  hlevel1: string | null;
  fdesc: string | null;
  regcode: string | null;
  expdate: string | null;
}

// ---------------------------------------------------------------------------
// Deterministic name discipline (shared with tests)
// ---------------------------------------------------------------------------

/** Lowercase, alphanumeric-only tokens, single spaces. */
export function normaliseProductName(raw: string): string {
  return raw
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
}

/**
 * Tokens a register name may append to a brand without changing WHICH product
 * it is: pack strength numbers, formulation codes, and category words.
 * "FORTE", "ULTRA", "DUO" etc. are deliberately NOT here — they denote a
 * different registered product.
 */
const IGNORABLE_SUFFIX_TOKENS = new Set([
  "sc", "ec", "wg", "wdg", "wp", "sl", "se", "ew", "gr", "df", "dp", "ulv",
  "cs", "od", "sg", "sp", "la", "me", "fs",
  "fungicide", "herbicide", "insecticide", "miticide", "acaricide",
  "nematicide", "bactericide", "adjuvant", "surfactant",
  "liquid", "concentrate", "suspension", "emulsifiable", "soluble",
  "dispersible", "flowable", "granule", "granules", "powder", "spray",
  "systemic", "selective",
]);

function isIgnorableToken(token: string): boolean {
  if (/^\d+(\.\d+)?$/.test(token)) return true; // "320", "500"
  if (/^\d+(\.\d+)?(g|kg|ml|l)$/.test(token)) return true; // "500g"
  return IGNORABLE_SUFFIX_TOKENS.has(token);
}

/**
 * Whether a register product name corresponds to a requested name under the
 * deterministic rules: exact normalised equality, or the register name being
 * the requested name plus ONLY ignorable formulation/category tokens.
 * Substring matching is structurally impossible here — "custodia" can never
 * correspond to "custodia forte …" because "forte" is not ignorable.
 */
export function nameCorresponds(requested: string, registerName: string): boolean {
  const wanted = normaliseProductName(requested);
  const actual = normaliseProductName(registerName);
  if (!wanted || !actual) return false;
  if (wanted === actual) return true;
  if (!actual.startsWith(`${wanted} `)) return false;
  const remainder = actual.slice(wanted.length).trim();
  return remainder.split(" ").every((t) => isIgnorableToken(t));
}

/**
 * Deterministically select AT MOST one register row for the requested names.
 * Exact normalised equality wins first; the formulation-suffix rule second;
 * ANY tie at either tier is ambiguous and fails closed.
 */
export function selectProductRow(
  requestedNames: string[],
  rows: ProductRecord[],
): { row: ProductRecord; mode: "exact_name" | "formulation_suffix" } | "ambiguous" | null {
  const names = requestedNames.map(normaliseProductName).filter((n) => n.length > 0);
  if (!names.length || !rows.length) return null;

  const byPcode = new Map<string, ProductRecord>();
  for (const row of rows) {
    if (row?.pcode && row?.fpname) byPcode.set(String(row.pcode), row);
  }
  const unique = Array.from(byPcode.values());

  const exact = unique.filter((r) =>
    names.some((n) => normaliseProductName(r.fpname) === n)
  );
  if (exact.length === 1) return { row: exact[0], mode: "exact_name" };
  if (exact.length > 1) return "ambiguous";

  const suffix = unique.filter((r) => names.some((n) => nameCorresponds(n, r.fpname)));
  if (suffix.length === 1) return { row: suffix[0], mode: "formulation_suffix" };
  if (suffix.length > 1) return "ambiguous";
  return null;
}

// ---------------------------------------------------------------------------
// Register field mappings (contract vocabularies only — no synonyms invented)
// ---------------------------------------------------------------------------

function mapCategory(hlevel1: string | null): string | null {
  const value = (hlevel1 ?? "").trim().toUpperCase();
  if (!value) return null;
  if (value.includes("FUNGICIDE")) return "fungicide";
  if (value.includes("HERBICIDE")) return "herbicide";
  if (value.includes("INSECTICIDE")) return "insecticide";
  if (value.includes("MITICIDE") || value.includes("ACARICIDE")) return "miticide";
  if (value.includes("GROWTH REGULATOR")) return "growthRegulator";
  if (value.includes("ADJUVANT") || value.includes("SURFACTANT")) return "adjuvant";
  return null;
}

function mapFormType(fdesc: string | null): string | null {
  const value = (fdesc ?? "").trim().toUpperCase();
  if (!value) return null;
  if (/(GRANUL|POWDER|DUST|PELLET|SOLID|TABLET|DRY)/.test(value)) return "solid";
  if (/(CONCENTRATE|LIQUID|EMULSIF|SOLUBLE|SUSPENSION|SOLUTION|FLOWABLE|AQUA)/.test(value)) {
    return "liquid";
  }
  return null;
}

function mapConcentrationUnit(cucode: string | null): string | null {
  const value = (cucode ?? "").trim();
  if (!value) return null;
  const upper = value.toUpperCase();
  if (upper === "G/L") return "g/L";
  if (upper === "G/KG") return "g/kg";
  if (upper === "% W/W" || upper === "%W/W") return "% w/w";
  if (upper === "% W/V" || upper === "%W/V") return "% w/v";
  if (upper === "CFU/G") return "CFU/g";
  // Unfamiliar register unit: carried verbatim, never guessed into the
  // contract vocabulary.
  return value;
}

function titleCaseActive(raw: string): string {
  return raw
    .toLowerCase()
    .split(/\s+/)
    .map((w) => (w ? w.charAt(0).toUpperCase() + w.slice(1) : w))
    .join(" ")
    .trim();
}

// ---------------------------------------------------------------------------
// Datastore access
// ---------------------------------------------------------------------------

interface DatastoreParams {
  resourceId: string;
  q?: string;
  filters?: Record<string, string | string[]>;
  limit: number;
}

export function datastoreUrl(params: DatastoreParams): string {
  const url = new URL(APVMA_DATASTORE_URL);
  url.searchParams.set("resource_id", params.resourceId);
  if (params.q) url.searchParams.set("q", params.q);
  if (params.filters) url.searchParams.set("filters", JSON.stringify(params.filters));
  url.searchParams.set("limit", String(params.limit));
  return url.toString();
}

// deno-lint-ignore no-explicit-any
async function datastoreSearch(deps: AdapterDeps, params: DatastoreParams): Promise<any[]> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  let res: Response;
  try {
    res = await deps.fetchFn(datastoreUrl(params), {
      headers: { "Accept": "application/json" },
      signal: ctrl.signal,
    });
  } catch (err) {
    clearTimeout(timer);
    const aborted = err instanceof DOMException && err.name === "AbortError";
    throw new SourceUnavailableError(
      aborted ? "timeout" : "network_error",
      aborted ? "APVMA datastore timed out" : "APVMA datastore unreachable",
    );
  }
  clearTimeout(timer);
  if (!res.ok) {
    try {
      await res.body?.cancel();
    } catch { /* ignore */ }
    throw new SourceUnavailableError(`http_${res.status}`, `APVMA datastore HTTP ${res.status}`);
  }
  // deno-lint-ignore no-explicit-any
  let payload: any;
  try {
    payload = await res.json();
  } catch {
    throw new SourceUnavailableError("bad_payload", "APVMA datastore returned non-JSON");
  }
  if (payload?.success !== true || !Array.isArray(payload?.result?.records)) {
    throw new SourceUnavailableError("bad_payload", "APVMA datastore payload malformed");
  }
  return payload.result.records;
}

// ---------------------------------------------------------------------------
// The adapter
// ---------------------------------------------------------------------------

const cache = new SourceCache();

/** Test hook: clears the module cache between deno test cases. */
export function clearApvmaCache(): void {
  cache.clear();
}

function source(
  name: string,
  reference: string,
  retrievedAt: string,
): WireDataSource {
  return { kind: "official_register", name, reference, retrieved_at: retrievedAt };
}

async function resolveDetails(
  deps: AdapterDeps,
  row: ProductRecord,
  mode: "exact_name" | "formulation_suffix" | "register_number_verified",
): Promise<ResolvedRegistration> {
  const retrievedAt = deps.now().toISOString();
  const pcode = String(row.pcode).trim();
  const unresolved = new Set<string>([
    // The register extract carries no label directions-for-use table and the
    // label document itself is not machine-consumed here.
    "label_reference",
    "registered_uses",
  ]);

  const registerStatus = [
    row.regcode ? String(row.regcode).trim() : null,
    row.expdate ? `expires ${String(row.expdate).trim()}` : null,
  ].filter(Boolean).join(", ") || null;

  const productUrl = datastoreUrl({
    resourceId: APVMA_RESOURCES.product,
    filters: { pcode },
    limit: 1,
  });
  const sources: WireDataSource[] = [
    source(
      `APVMA PubCRIS register extract — product ${pcode}` +
        (registerStatus ? ` (${registerStatus})` : ""),
      productUrl,
      retrievedAt,
    ),
  ];

  // ---- Constituents (register-backed chemistry) --------------------------
  let actives: WireActiveIngredient[] = [];
  try {
    const constituentRows = await datastoreSearch(deps, {
      resourceId: APVMA_RESOURCES.productConstituents,
      filters: { pcode },
      limit: 32,
    });
    const activeRows = constituentRows.filter((c) =>
      String(c?.ctype ?? "").trim().toUpperCase() === "A" && c?.ccode
    );
    if (activeRows.length) {
      const codes = Array.from(new Set(activeRows.map((c) => String(c.ccode))));
      const nameRows = await datastoreSearch(deps, {
        resourceId: APVMA_RESOURCES.constituentNames,
        filters: { ccode: codes },
        limit: codes.length + 4,
      });
      const namesByCode = new Map<string, string>();
      for (const n of nameRows) {
        if (n?.ccode && n?.cname) namesByCode.set(String(n.ccode), String(n.cname));
      }
      for (const c of activeRows) {
        const rawName = namesByCode.get(String(c.ccode));
        if (!rawName) {
          // Register lists a constituent it cannot name for us: the active is
          // omitted rather than fabricated, and the gap is recorded.
          unresolved.add(`active_ingredient:${String(c.ccode)}`);
          continue;
        }
        const name = titleCaseActive(rawName);
        const parsed = Number.parseFloat(String(c.camount ?? ""));
        const concentration = Number.isFinite(parsed) ? parsed : null;
        if (concentration === null) unresolved.add(`concentration:${name}`);
        const unit = mapConcentrationUnit(c?.cucode ? String(c.cucode) : null);
        const { group, source: groupSource } = reconcileGroup(name, null);
        if (!group) unresolved.add(`activity_group:${name}`);
        actives.push({
          name,
          concentration,
          concentration_unit: unit,
          activity_group: group,
          group_source: groupSource,
          identity_source: "official_register",
        });
      }
      if (actives.length) {
        sources.push(source(
          `APVMA PubCRIS constituents — product ${pcode}`,
          datastoreUrl({
            resourceId: APVMA_RESOURCES.productConstituents,
            filters: { pcode },
            limit: 32,
          }),
          retrievedAt,
        ));
      }
    }
  } catch (err) {
    // Identity stands; chemistry from the register does not. Never invented.
    actives = [];
    unresolved.add("active_ingredients");
    console.error(
      "apvma constituents unavailable:",
      err instanceof Error ? err.message : String(err),
    );
  }

  // ---- Current approved label registration --------------------------------
  let labelVersion: string | null = null;
  try {
    const labelRows = await datastoreSearch(deps, {
      resourceId: APVMA_RESOURCES.labelRegistrations,
      filters: { pcode },
      limit: 8,
    });
    const withRegno = labelRows.filter((l) => l?.regno);
    if (withRegno.length) {
      const latest = withRegno[withRegno.length - 1];
      const regno = String(latest.regno).trim();
      const regdate = latest?.regdate ? String(latest.regdate).trim() : null;
      labelVersion = `APVMA label approval ${regno}${regdate ? ` (${regdate})` : ""}`;
      sources.push(source(
        `APVMA PubCRIS label registration ${regno}${regdate ? ` (${regdate})` : ""}`,
        datastoreUrl({
          resourceId: APVMA_RESOURCES.labelRegistrations,
          filters: { pcode },
          limit: 8,
        }),
        retrievedAt,
      ));
    } else {
      unresolved.add("label_version");
    }
  } catch (err) {
    unresolved.add("label_version");
    console.error(
      "apvma label registration unavailable:",
      err instanceof Error ? err.message : String(err),
    );
  }

  return {
    country_code: "AU",
    scheme: "apvma",
    registration_number: pcode,
    registration_identity_key: identityKey("AU", "apvma", pcode),
    registered_product_name: String(row.fpname).trim(),
    registrant: row.sname ? String(row.sname).trim() : null,
    product_category: mapCategory(row.hlevel1),
    form_type: mapFormType(row.fdesc),
    label_version: labelVersion,
    register_status: registerStatus,
    active_ingredients: actives,
    unresolved_fields: Array.from(unresolved).sort(),
    sources,
    match_mode: mode,
  };
}

async function discover(
  query: string,
  hintRegistrationNumber: string | null,
  deps: AdapterDeps,
): Promise<DiscoveryResult> {
  const nowMs = deps.now().getTime();
  const normQuery = normaliseProductName(query);
  const hint = (hintRegistrationNumber ?? "").trim();
  const cacheKey = `discover:${normQuery}|${hint}`;

  const cached = cache.get<DiscoveryResult>("AU", "apvma", cacheKey, nowMs);
  if (cached) return { ...cached.value, cache: "hit" };

  const finish = (result: DiscoveryResult, ttlMs: number): DiscoveryResult => {
    cache.set(
      "AU",
      "apvma",
      cacheKey,
      result,
      ttlMs,
      nowMs,
      deps.now().toISOString(),
      result.registration?.registration_identity_key ?? null,
    );
    return result;
  };

  try {
    // 1) A registration-number hint is only ever a POINTER. The register row
    //    it names must exist AND its name must correspond deterministically to
    //    what was asked for — a hallucinated or mistyped number can never bind
    //    the wrong product.
    if (/^\d{3,8}$/.test(hint)) {
      const rows = await datastoreSearch(deps, {
        resourceId: APVMA_RESOURCES.product,
        filters: { pcode: hint },
        limit: 2,
      }) as ProductRecord[];
      const row = rows.find((r) => String(r?.pcode ?? "") === hint && r?.fpname);
      if (row && nameCorresponds(query, row.fpname)) {
        const registration = await resolveDetails(deps, row, "register_number_verified");
        return finish(
          { outcome: "resolved", adapter: "apvma", registration, cache: "miss" },
          RESOLVED_TTL_MS,
        );
      }
      // Fall through to the name path: the number did not verify.
    }

    // 2) Full-text register search, then DETERMINISTIC selection.
    if (!normQuery) {
      return finish(
        { outcome: "unresolved", adapter: "apvma", cache: "miss" },
        NEGATIVE_TTL_MS,
      );
    }
    const rows = await datastoreSearch(deps, {
      resourceId: APVMA_RESOURCES.product,
      q: query,
      limit: 32,
    }) as ProductRecord[];
    const selection = selectProductRow([query], rows);
    if (selection === "ambiguous") {
      return finish(
        { outcome: "ambiguous", adapter: "apvma", cache: "miss" },
        NEGATIVE_TTL_MS,
      );
    }
    if (!selection) {
      return finish(
        { outcome: "unresolved", adapter: "apvma", cache: "miss" },
        NEGATIVE_TTL_MS,
      );
    }
    const registration = await resolveDetails(deps, selection.row, selection.mode);
    return finish(
      { outcome: "resolved", adapter: "apvma", registration, cache: "miss" },
      RESOLVED_TTL_MS,
    );
  } catch (err) {
    const category = err instanceof SourceUnavailableError ? err.category : "unexpected_error";
    return finish(
      {
        outcome: "source_unavailable",
        adapter: "apvma",
        error_category: category,
        cache: "miss",
      },
      UNAVAILABLE_TTL_MS,
    );
  }
}

export const apvmaAdapter: SourceAdapter = {
  id: "apvma",
  country: "AU",
  scheme: "apvma",
  discover,
};
