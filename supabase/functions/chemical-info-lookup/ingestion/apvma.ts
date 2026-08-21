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
// LABEL AUTHORITY (Stage 4)
//   The APVMA-approved label. The register extract points at the current
//   approval (labelreg, carried as `label_version`) AND publishes the
//   label's machine-readable content: registered use claims (produse ×
//   host × pest) and the label's product statements (prodcom — withholding
//   periods, re-entry, restrictions). Those become structured label
//   evidence (ingestion/label.ts) attributed to `manufacturer_label`.
//   The register publishes NO machine-readable rate table, so label RATES
//   stay unresolved for the admin to confirm against the label document at
//   review (or AI-attributed, clearly marked). They are never invented.
//
// LABEL DOCUMENT (Stage LD-1 discovery + Stage LD-2 extraction)
//   For a register-RESOLVED identity only, the official label DOCUMENT is
//   discovered via the PubCRIS portal's own view-label redirect to the
//   APVMA eLabels host (ingestion/label_document.ts). Success populates
//   `label_reference` with the confirmed document URL and records document
//   provenance (URL, retrieval time, SHA-256 when fetched) as a
//   `manufacturer_label` source. When the PDF bytes were fetched, the
//   document's text layer is parsed DETERMINISTICALLY (label_extract.ts):
//   Directions-for-Use rates bind to the register's OWN claims through the
//   fail-closed crop/target join, WHP/re-entry are corroborated with the
//   Stage 4 strict patterns (disagreements become review conflicts), and
//   unbindable rows are preserved verbatim — never served. Any failure at
//   any step is fail-soft: the register result stands byte-identical.
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
  LabelEvidence,
  RegisterCandidate,
  ResolvedRegistration,
  SourceAdapter,
  WireActiveIngredient,
  WireDataSource,
} from "./contract.ts";
import { identityKey } from "./contract.ts";
import { buildLabelEvidence } from "./label.ts";
import {
  discoveryMatchRank,
  nameCorresponds,
  normaliseProductName,
  normaliseProductNameLoose,
  retrievalQueryVariants,
  selectProductRow,
} from "./matching.ts";
import {
  NEGATIVE_TTL_MS,
  RESOLVED_TTL_MS,
  SourceCache,
  UNAVAILABLE_TTL_MS,
} from "./cache.ts";
import {
  clearLabelDocumentCache,
  discoverLabelDocumentWithText,
  labelDocumentSource,
} from "./label_document.ts";
import { applyLabelDocumentExtraction } from "./label_extract.ts";

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
  /** produse.csv — the approved label's use claims (pcode × host × pest). */
  productUses: "80289270-0681-44fd-be6e-0473bb4ab9a0",
  /** host.csv — host (crop) code → wording. */
  hosts: "2927e1dd-b064-411c-bc90-1e2c05b6822f",
  /** pest.csv — pest (target) code → wording. */
  pests: "1365af46-a3db-4d54-9f25-e41f7dfce5d2",
  /** prodcom.csv — label statements (WHP, re-entry…), chunked by seq. */
  productComments: "98e956e0-8d60-47cd-8bed-1d4da4c9826d",
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
// Deterministic name discipline — CANONICAL implementation in matching.ts
// (shared with seed apply hint verification and tests). Re-exported here so
// every existing import site keeps working. The matcher generalises the AWRI
// Stage 5E variant protections: typography (case/punctuation/spacing/pack
// codes) never distinguishes identity, variant designators (FORTE, ULTRA,
// DUO, …) always do, substring matching is structurally impossible, and
// every tie fails closed.
// ---------------------------------------------------------------------------

export { nameCorresponds, normaliseProductName, selectProductRow };

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

/** Test hook: clears the module caches between deno test cases. */
export function clearApvmaCache(): void {
  cache.clear();
  clearLabelDocumentCache();
}

function source(
  name: string,
  reference: string,
  retrievedAt: string,
): WireDataSource {
  return { kind: "official_register", name, reference, retrieved_at: retrievedAt };
}

/**
 * Fetch the approved label's published claim data for one product.
 * Fail-soft by contract: any failure returns null — register identity and
 * chemistry stand, label facts stay unresolved or AI-attributed. Never
 * invented, never partially guessed.
 */
async function fetchLabelEvidence(
  deps: AdapterDeps,
  pcode: string,
  retrievedAt: string,
): Promise<LabelEvidence | null> {
  try {
    const useRows = await datastoreSearch(deps, {
      resourceId: APVMA_RESOURCES.productUses,
      filters: { pcode },
      limit: 512,
    });
    if (!useRows.length) return null;

    const hostCodes = Array.from(
      new Set(useRows.map((u) => String(u?.hostcode ?? "")).filter(Boolean)),
    );
    const pestCodes = Array.from(
      new Set(useRows.map((u) => String(u?.pestcode ?? "")).filter(Boolean)),
    );
    const [hostRows, pestRows] = await Promise.all([
      datastoreSearch(deps, {
        resourceId: APVMA_RESOURCES.hosts,
        filters: { hostcode: hostCodes },
        limit: hostCodes.length + 4,
      }),
      datastoreSearch(deps, {
        resourceId: APVMA_RESOURCES.pests,
        filters: { pestcode: pestCodes },
        limit: pestCodes.length + 4,
      }),
    ]);

    // Label statements are supporting evidence for the claims; their outage
    // must not take the claims down with them.
    let commentRows: Record<string, unknown>[] = [];
    try {
      commentRows = await datastoreSearch(deps, {
        resourceId: APVMA_RESOURCES.productComments,
        filters: { pcode },
        limit: 256,
      });
    } catch (err) {
      console.error(
        "apvma label statements unavailable:",
        err instanceof Error ? err.message : String(err),
      );
    }

    const evidence = buildLabelEvidence({
      pcode,
      useRows,
      hostRows,
      pestRows,
      commentRows,
      retrievedAt,
      claimsReference: datastoreUrl({
        resourceId: APVMA_RESOURCES.productUses,
        filters: { pcode },
        limit: 512,
      }),
      statementsReference: commentRows.length
        ? datastoreUrl({
          resourceId: APVMA_RESOURCES.productComments,
          filters: { pcode },
          limit: 256,
        })
        : null,
    });
    return evidence.claims.length ? evidence : null;
  } catch (err) {
    console.error(
      "apvma label evidence unavailable:",
      err instanceof Error ? err.message : String(err),
    );
    return null;
  }
}

async function resolveDetails(
  deps: AdapterDeps,
  row: ProductRecord,
  mode: ResolvedRegistration["match_mode"],
): Promise<ResolvedRegistration> {
  const retrievedAt = deps.now().toISOString();
  const pcode = String(row.pcode).trim();
  const unresolved = new Set<string>([
    // Both start unresolved and are cleared ONLY by their authoritative
    // steps below: label_reference by Stage LD-1 document discovery,
    // registered_uses by Stage 4 label evidence. Never assumed resolved.
    "label_reference",
    "registered_uses",
  ]);

  const registerStatus = registerStatusOf(row);

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

  // ---- Official label evidence (Stage 4; fail-soft) -----------------------
  let labelEvidence = await fetchLabelEvidence(deps, pcode, retrievedAt);

  // ---- Official label DOCUMENT (Stage LD-1 + LD-2; fail-soft) -------------
  // Runs ONLY here — i.e. only after this register identity RESOLVED
  // deterministically. Discovery success clears the label_reference gap and
  // records document provenance. When the PDF text layer was extracted AND
  // Stage 4 claims resolved, the deterministic LD-2 pass binds document
  // rates / corroborates WHP+re-entry onto those claims (fail-closed join;
  // its own failures are contained so a bad document can never damage the
  // register result). Any timeout/404/extraction failure leaves everything
  // exactly as it stands — gaps stay honestly listed, nothing downgraded.
  const labelDoc = await discoverLabelDocumentWithText(deps, pcode);
  const labelDocument = labelDoc.doc;
  if (
    labelDocument?.document && labelDoc.items && labelEvidence &&
    labelEvidence.claims.length
  ) {
    try {
      labelEvidence = applyLabelDocumentExtraction(
        labelEvidence,
        labelDoc.items,
        labelDocument,
      );
    } catch (err) {
      // Fail soft: Stage 4 evidence stands untouched.
      console.error(
        "label document extraction skipped:",
        err instanceof Error ? err.message : String(err),
      );
    }
  }

  if (labelEvidence) {
    unresolved.delete("registered_uses");
    for (const gap of labelEvidence.unresolved) unresolved.add(gap);
    sources.push(...labelEvidence.sources);
  }
  if (labelDocument) {
    unresolved.delete("label_reference");
    sources.push(labelDocumentSource(pcode, labelDocument));
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
    label_evidence: labelEvidence,
    label_document: labelDocument,
  };
}

/** Register lifecycle detail ("R, expires 30/06/2029"), or null. */
function registerStatusOf(row: ProductRecord): string | null {
  return [
    row.regcode ? String(row.regcode).trim() : null,
    row.expdate ? `expires ${String(row.expdate).trim()}` : null,
  ].filter(Boolean).join(", ") || null;
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

    // 2) Full-text register search, then DETERMINISTIC selection. The live
    //    CKAN datastore tokenises on whitespace, so a spaced request can miss
    //    a compact register name entirely ("Spray Seal" retrieves ZERO rows
    //    for "Sprayseal Pruning Wound Treatment"). RETRIEVAL therefore tries
    //    bounded typography variants (raw → compact → loose), unioning rows
    //    by pcode — while MATCHING stays deterministic against the original
    //    requested name. An ambiguous selection is terminal: more retrieval
    //    can only add rows, never un-tie them.
    if (!normQuery) {
      return finish(
        { outcome: "unresolved", adapter: "apvma", cache: "miss" },
        NEGATIVE_TTL_MS,
      );
    }
    const seenPcodes = new Set<string>();
    const collected: ProductRecord[] = [];
    let selection: ReturnType<typeof selectProductRow<ProductRecord>> = null;
    for (const variant of retrievalQueryVariants(query)) {
      const rows = await datastoreSearch(deps, {
        resourceId: APVMA_RESOURCES.product,
        q: variant,
        limit: 32,
      }) as ProductRecord[];
      for (const r of rows) {
        const pcode = String(r?.pcode ?? "");
        if (!pcode || !r?.fpname || seenPcodes.has(pcode)) continue;
        seenPcodes.add(pcode);
        collected.push(r);
      }
      selection = selectProductRow([query], collected);
      if (selection) break;
    }
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

// ---------------------------------------------------------------------------
// Candidate discovery (search listings) — DISCOVERY ONLY, never authority
// ---------------------------------------------------------------------------

const CANDIDATE_LIMIT_DEFAULT = 6;

/**
 * Free-text candidate discovery for human search listings (contract
 * `SourceAdapter.discoverCandidates`).
 *
 * DISCOVERY IS NOT VERIFICATION. This path exists so a partial or loosely
 * spaced product name ("Dithane rainshield") — or a bare registration
 * number — can SURFACE the register rows a human might mean, including
 * SEVERAL rows when the name is ambiguous (never a silent pick). It grants
 * nothing: candidates carry register identity and display fields only; the
 * strict `discover` path re-establishes identity on the exact selection
 * (verbatim register name + registration number) before anything binds.
 *
 * Retrieval mirrors the resolver's bounded typography variants plus a direct
 * registration-number lookup for digit queries. Ranking is
 * `discoveryMatchRank` (token-boundary discipline — substrings still cannot
 * match). Chemistry summaries are best-effort batched constituent reads,
 * fail-soft to empty. Any source failure returns [] — search never breaks.
 */
async function discoverCandidates(
  query: string,
  deps: AdapterDeps,
  limit: number = CANDIDATE_LIMIT_DEFAULT,
): Promise<RegisterCandidate[]> {
  const trimmed = query.trim();
  if (!trimmed) return [];
  const nowMs = deps.now().getTime();
  const cacheKey = `candidates:${normaliseProductNameLoose(trimmed)}|${limit}`;
  const cached = cache.get<RegisterCandidate[]>("AU", "apvma", cacheKey, nowMs);
  if (cached) return cached.value;

  const finish = (
    result: RegisterCandidate[],
    ttlMs: number,
  ): RegisterCandidate[] => {
    cache.set(
      "AU",
      "apvma",
      cacheKey,
      result,
      ttlMs,
      nowMs,
      deps.now().toISOString(),
      null,
    );
    return result;
  };

  try {
    const ranked: { row: ProductRecord; rank: number }[] = [];
    const seen = new Set<string>();

    if (/^\d{3,8}$/.test(trimmed)) {
      // Registration-number query: a direct register pointer. Listed as a
      // candidate only — the strict resolver still re-verifies name↔number
      // after selection.
      const rows = await datastoreSearch(deps, {
        resourceId: APVMA_RESOURCES.product,
        filters: { pcode: trimmed },
        limit: 2,
      }) as ProductRecord[];
      for (const r of rows) {
        const pcode = String(r?.pcode ?? "").trim();
        if (pcode !== trimmed || !r?.fpname || seen.has(pcode)) continue;
        seen.add(pcode);
        ranked.push({ row: r, rank: 0 });
      }
    } else {
      // Bounded typography-variant retrieval (raw → compact → loose),
      // unioned by pcode; every retrieved row is then ranked — or dropped —
      // by the discovery matcher.
      for (const variant of retrievalQueryVariants(trimmed)) {
        const rows = await datastoreSearch(deps, {
          resourceId: APVMA_RESOURCES.product,
          q: variant,
          limit: 32,
        }) as ProductRecord[];
        for (const r of rows) {
          const pcode = String(r?.pcode ?? "").trim();
          if (!pcode || !r?.fpname || seen.has(pcode)) continue;
          seen.add(pcode);
          const rank = discoveryMatchRank(trimmed, String(r.fpname));
          if (rank !== null) ranked.push({ row: r, rank });
        }
      }
    }

    if (!ranked.length) return finish([], NEGATIVE_TTL_MS);

    ranked.sort((a, b) =>
      a.rank - b.rank ||
      String(a.row.fpname).localeCompare(String(b.row.fpname)) ||
      String(a.row.pcode).localeCompare(String(b.row.pcode))
    );
    const top = ranked.slice(0, limit);

    // Best-effort display chemistry: ONE batched constituent read + ONE
    // name read for all candidates. Fail-soft — a summary outage never
    // hides a candidate.
    const summaries = new Map<string, { text: string; groups: string[] }>();
    try {
      const pcodes = top.map((t) => String(t.row.pcode).trim());
      const conRows = await datastoreSearch(deps, {
        resourceId: APVMA_RESOURCES.productConstituents,
        filters: { pcode: pcodes },
        limit: 256,
      });
      const activeRows = conRows.filter((c) =>
        String(c?.ctype ?? "").trim().toUpperCase() === "A" && c?.ccode &&
        c?.pcode
      );
      const codes = Array.from(
        new Set(activeRows.map((c) => String(c.ccode))),
      );
      const namesByCode = new Map<string, string>();
      if (codes.length) {
        const nameRows = await datastoreSearch(deps, {
          resourceId: APVMA_RESOURCES.constituentNames,
          filters: { ccode: codes },
          limit: codes.length + 4,
        });
        for (const n of nameRows) {
          if (n?.ccode && n?.cname) {
            namesByCode.set(String(n.ccode), String(n.cname));
          }
        }
      }
      for (const pcode of pcodes) {
        const parts: string[] = [];
        const groups = new Set<string>();
        for (const c of activeRows.filter((r) => String(r.pcode) === pcode)) {
          const rawName = namesByCode.get(String(c.ccode));
          if (!rawName) continue;
          const name = titleCaseActive(rawName);
          const parsed = Number.parseFloat(String(c.camount ?? ""));
          const unit = mapConcentrationUnit(c?.cucode ? String(c.cucode) : null);
          const conc = Number.isFinite(parsed)
            ? ` ${parsed}${unit ? ` ${unit}` : ""}`
            : "";
          parts.push(`${name}${conc}`.trim());
          const { group } = reconcileGroup(name, null);
          if (group?.code) groups.add(group.code);
        }
        summaries.set(pcode, {
          text: parts.join(" + "),
          groups: Array.from(groups),
        });
      }
    } catch (err) {
      console.error(
        "apvma candidate chemistry summary skipped:",
        err instanceof Error ? err.message : String(err),
      );
    }

    const candidates: RegisterCandidate[] = top.map(({ row, rank }) => {
      const pcode = String(row.pcode).trim();
      const summary = summaries.get(pcode);
      return {
        registration_number: pcode,
        registered_product_name: String(row.fpname).trim(),
        registrant: row.sname ? String(row.sname).trim() : null,
        product_category: mapCategory(row.hlevel1),
        register_status: registerStatusOf(row),
        actives_summary: summary?.text ?? "",
        activity_groups: summary?.groups ?? [],
        match_rank: rank,
      };
    });
    return finish(candidates, RESOLVED_TTL_MS);
  } catch (err) {
    console.error(
      "apvma candidate discovery unavailable:",
      err instanceof Error ? err.message : String(err),
    );
    return finish([], UNAVAILABLE_TTL_MS);
  }
}

export const apvmaAdapter: SourceAdapter = {
  id: "apvma",
  country: "AU",
  scheme: "apvma",
  discover,
  discoverCandidates,
};
