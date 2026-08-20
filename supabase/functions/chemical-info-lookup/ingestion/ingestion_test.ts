// deno test supabase/functions/chemical-info-lookup/ingestion/ingestion_test.ts
//
// Master Chemical Catalogue Stages 3–4 — AU authoritative ingestion tests.
// Covers the required matrix (§O 40–49) plus the Custodia end-to-end fixture
// (§H 23–25), the cache jurisdiction rules (§L), the candidate response
// envelope (§J) and Stage 4 official label evidence (50–59).
//
// The register facts (Custodia 320 SC = Azoxystrobin 120 g/L + Tebuconazole
// 200 g/L, APVMA 66541; Custodia Forte = 222/370 g/L, APVMA 91636) live HERE,
// in mocked APVMA PubCRIS documents — the adapter must establish them through
// its normal evidence path (register extract → constituent names →
// authoritative FRAC table). Stage 4 label fixtures mirror the LIVE PubCRIS
// label data for Custodia Forte 91636 byte-for-byte (use claims + chunked
// withholding statements, retrieved 2026-08-20): grapevine claims for powdery
// mildew / botrytis cinerea / downy mildew, grape WHP "4 WEEKS" = 28 days, NO
// re-entry statement, NO machine-readable rates. Nothing in the
// implementation hard-codes any of it.

import {
  APVMA_RESOURCES,
  apvmaAdapter,
  clearApvmaCache,
  nameCorresponds,
  normaliseProductName,
  selectProductRow,
} from "./apvma.ts";
import { adapterFor, registryEntryFor } from "./registry.ts";
import {
  buildCandidatePayload,
  buildRegisterOnlyStructured,
  candidateEnvelope,
  discoverAuthoritative,
  discoveryEnvelope,
  mergeDiscoveryIntoStructured,
  upsertCandidate,
} from "./ingest.ts";
import {
  buildCandidateRefreshPatch,
  refreshMasterRow,
} from "./refresh.ts";
import type {
  AdapterDeps,
  CandidateRowPayload,
  MasterOps,
  MasterRow,
} from "./contract.ts";
import { identityKey } from "./contract.ts";
import { SourceCache } from "./cache.ts";
import {
  assembleProductComments,
  cropsCorrespond,
  reentryHoursFromStatement,
  targetsCorrespond,
  whpDaysFromStatement,
} from "./label.ts";

// ---------------------------------------------------------------------------
// Assertion helpers (lib_test.ts convention)
// ---------------------------------------------------------------------------

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`assertion failed: ${msg}`);
}

function assertEquals<T>(actual: T, expected: T, msg: string): void {
  if (actual !== expected) {
    throw new Error(`${msg}: expected ${String(expected)}, got ${String(actual)}`);
  }
}

// ---------------------------------------------------------------------------
// Mock APVMA PubCRIS documents (register fixture)
// ---------------------------------------------------------------------------

// deno-lint-ignore no-explicit-any
type Row = Record<string, any>;

const CUSTODIA_320 = {
  pcode: "66541",
  fpname: "CUSTODIA 320 SC FUNGICIDE",
  sname: "ADAMA AUSTRALIA PTY LIMITED",
  hlevel1: "FUNGICIDE",
  fdesc: "SUSPENSION CONCENTRATE",
  regcode: "R",
  expdate: "30/06/2027 0:00",
};

const CUSTODIA_FORTE = {
  pcode: "91636",
  fpname: "CUSTODIA FORTE FUNGICIDE",
  sname: "ADAMA AUSTRALIA PTY LIMITED",
  hlevel1: "FUNGICIDE",
  fdesc: "SUSPENSION CONCENTRATE",
  regcode: "R",
  expdate: "30/06/2029 0:00",
};

interface RegisterFixture {
  products: Row[];
  prodcon: Record<string, Row[]>;
  constit: Record<string, string>;
  labelreg: Record<string, Row[]>;
  /** Stage 4 — approved-label use claims (produse.csv), keyed by pcode. */
  produse?: Record<string, Row[]>;
  /** Stage 4 — host code → wording (host.csv). */
  hosts?: Record<string, string>;
  /** Stage 4 — pest code → wording (pest.csv). */
  pests?: Record<string, string>;
  /** Stage 4 — chunked label statements (prodcom.csv), keyed by pcode. */
  prodcom?: Record<string, Row[]>;
  failResources?: Set<string>;
  requestLog?: string[];
}

// Live PubCRIS label data for Custodia Forte 91636 (retrieved 2026-08-20),
// mirrored verbatim — including the register's own chunking artefacts
// ("GRAP" + "EVINES", "AFTER" + "APPLICATION") and out-of-order seq rows.
const FORTE_PRODUSE: Row[] = [
  { pcode: "91636", hostcode: "FRVG", pestcode: "YMIP" },
  { pcode: "91636", hostcode: "FRVG", pestcode: "YBOTR1" },
  { pcode: "91636", hostcode: "FRVG", pestcode: "YMIDP" },
  { pcode: "91636", hostcode: "NTSA", pestcode: "HUR" },
  { pcode: "91636", hostcode: "NTSA", pestcode: "YRU" },
  { pcode: "91636", hostcode: "NTSA", pestcode: "YROB3" },
  { pcode: "91636", hostcode: "NTSA", pestcode: "YSHOE" },
  { pcode: "91636", hostcode: "NTSGB", pestcode: "YSPH1" },
];

const FORTE_PRODCOM: Row[] = [
  { pcode: "91636", seq: 1, applic: "WITHHOLDING PERIODS\nHarvest\nALMONDS: N" },
  { pcode: "91636", seq: 4, applic: "APPLICATION.\nMACADAMIAS: DO NOT HARVES" },
  { pcode: "91636", seq: 5, applic: "T FOR 15 DAYS AFTER APPLICATION." },
  { pcode: "91636", seq: 2, applic: "OT REQUIRED WHEN USED AS DIRECTED.\nGRAP" },
  { pcode: "91636", seq: 3, applic: "EVINES: DO NOT HARVEST FOR 4 WEEKS AFTER" },
];

const FULL_REGISTER: RegisterFixture = {
  products: [CUSTODIA_320, CUSTODIA_FORTE],
  prodcon: {
    "66541": [
      { pcode: "66541", ccode: "PMAZ", ctype: "A", camount: "120.000000", cucode: "g/L" },
      { pcode: "66541", ccode: "TZTB", ctype: "A", camount: "200.000000", cucode: "g/L" },
    ],
    "91636": [
      { pcode: "91636", ccode: "PMAZ", ctype: "A", camount: "222.000000", cucode: "g/L" },
      { pcode: "91636", ccode: "TZTB", ctype: "A", camount: "370.000000", cucode: "g/L" },
    ],
  },
  constit: { PMAZ: "AZOXYSTROBIN", TZTB: "TEBUCONAZOLE" },
  labelreg: {
    "66541": [{ pcode: "66541", regno: "112233", regdate: "5/09/2012 0:00" }],
    "91636": [{ pcode: "91636", regno: "132920", regdate: "2/03/2022 9:50:13 AM" }],
  },
  produse: { "91636": FORTE_PRODUSE },
  hosts: { FRVG: "GRAPEVINE", NTSA: "ALMOND", NTSGB: "MACADAMIA" },
  pests: {
    YMIP: "POWDERY MILDEW",
    YBOTR1: "BOTRYTIS CINEREA",
    YMIDP: "DOWNY MILDEW ON GRAPE",
    HUR: "HULL ROT SUPPRESSION ONLY",
    YRU: "RUST",
    YROB3: "BROWN ROT",
    YSHOE: "SHOT HOLE",
    YSPH1: "HUSK SPOT - PSEUDOCERCOSPORA MACADAMIAE",
  },
  prodcom: { "91636": FORTE_PRODCOM },
};

function fixtureWithoutCustodia320(): RegisterFixture {
  return {
    ...FULL_REGISTER,
    products: [CUSTODIA_FORTE],
    requestLog: [],
  };
}

function makeRegisterFetch(fixture: RegisterFixture): typeof fetch {
  const respond = (records: Row[]): Response =>
    new Response(JSON.stringify({ success: true, result: { records } }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });

  return ((input: Request | URL | string): Promise<Response> => {
    const url = new URL(String(input));
    fixture.requestLog?.push(url.toString());
    if (url.hostname !== "data.gov.au") {
      // The AU adapter must never leave the AU government register.
      return Promise.reject(new Error(`forbidden host: ${url.hostname}`));
    }
    const resource = url.searchParams.get("resource_id") ?? "";
    if (fixture.failResources?.has(resource)) {
      return Promise.resolve(new Response("upstream error", { status: 500 }));
    }
    const q = url.searchParams.get("q");
    const filtersRaw = url.searchParams.get("filters");
    // deno-lint-ignore no-explicit-any
    const filters: any = filtersRaw ? JSON.parse(filtersRaw) : null;

    let records: Row[] = [];
    if (resource === APVMA_RESOURCES.product) {
      records = fixture.products;
      if (filters?.pcode) records = records.filter((r) => r.pcode === filters.pcode);
      if (q) {
        records = records.filter((r) =>
          String(r.fpname).toLowerCase().includes(q.toLowerCase())
        );
      }
    } else if (resource === APVMA_RESOURCES.productConstituents) {
      records = fixture.prodcon[filters?.pcode] ?? [];
    } else if (resource === APVMA_RESOURCES.constituentNames) {
      const codes: string[] = Array.isArray(filters?.ccode)
        ? filters.ccode
        : [filters?.ccode].filter(Boolean);
      records = codes
        .map((c) => ({ ccode: c, cname: fixture.constit[c] }))
        .filter((r) => r.cname);
    } else if (resource === APVMA_RESOURCES.labelRegistrations) {
      records = fixture.labelreg[filters?.pcode] ?? [];
    } else if (resource === APVMA_RESOURCES.productUses) {
      records = fixture.produse?.[filters?.pcode] ?? [];
    } else if (resource === APVMA_RESOURCES.hosts) {
      const codes: string[] = Array.isArray(filters?.hostcode)
        ? filters.hostcode
        : [filters?.hostcode].filter(Boolean);
      records = codes
        .map((c) => ({ hostcode: c, hostdesc: fixture.hosts?.[c] }))
        .filter((r) => r.hostdesc);
    } else if (resource === APVMA_RESOURCES.pests) {
      const codes: string[] = Array.isArray(filters?.pestcode)
        ? filters.pestcode
        : [filters?.pestcode].filter(Boolean);
      records = codes
        .map((c) => ({ pestcode: c, pestdesc: fixture.pests?.[c] }))
        .filter((r) => r.pestdesc);
    } else if (resource === APVMA_RESOURCES.productComments) {
      records = fixture.prodcom?.[filters?.pcode] ?? [];
    }
    return Promise.resolve(respond(records));
  }) as typeof fetch;
}

function makeDeps(fixture: RegisterFixture, nowIso = "2026-08-19T00:00:00Z"): AdapterDeps {
  return { fetchFn: makeRegisterFetch(fixture), now: () => new Date(nowIso) };
}

// ---------------------------------------------------------------------------
// Mock catalogue ops
// ---------------------------------------------------------------------------

class MockOps implements MasterOps {
  rows = new Map<string, MasterRow>();
  inserts = 0;
  updates = 0;
  approvedWriteAttempts = 0;
  private nextId = 1;

  seed(partial: Partial<MasterRow>): MasterRow {
    const country = partial.registration_country ?? "AU";
    const scheme = partial.registration_scheme ?? "apvma";
    const number = partial.registration_number ?? "0";
    const key = identityKey(country, scheme, number);
    const row: MasterRow = {
      id: partial.id ?? `row-${this.nextId++}`,
      registration_country: country,
      registration_scheme: scheme,
      registration_number: number,
      registration_identity_key: key,
      registrant: partial.registrant ?? null,
      registered_product_name: partial.registered_product_name ?? "Seeded",
      common_names: partial.common_names ?? [],
      product_category: partial.product_category ?? null,
      form_type: partial.form_type ?? null,
      active_ingredients: partial.active_ingredients ?? [],
      activity_groups: partial.activity_groups ?? [],
      activity_group_scheme: partial.activity_group_scheme ?? null,
      registered_uses: partial.registered_uses ?? [],
      label_rate_bases: partial.label_rate_bases ?? [],
      label_reference: partial.label_reference ?? null,
      label_version: partial.label_version ?? null,
      verification_status: partial.verification_status ?? "unverified",
      verification_sources: partial.verification_sources ?? [],
      verification_conflicts: partial.verification_conflicts ?? [],
      verification_unresolved_fields: partial.verification_unresolved_fields ?? [],
      verified_at: partial.verified_at ?? null,
      source_kind: partial.source_kind ?? "ai_interpretation",
      source_reference: partial.source_reference ?? null,
      retrieved_at: partial.retrieved_at ?? null,
      review_status: partial.review_status ?? "candidate",
      catalogue_version: partial.catalogue_version ?? 1,
      activity_group_table_version: partial.activity_group_table_version ?? 1,
      intelligence_schema_version: partial.intelligence_schema_version ?? 1,
    };
    this.rows.set(key, row);
    return row;
  }

  selectByIdentityKey(key: string): Promise<MasterRow | null> {
    return Promise.resolve(this.rows.get(key) ?? null);
  }

  insertCandidate(payload: CandidateRowPayload): Promise<MasterRow | null> {
    const key = identityKey(
      payload.registration_country,
      payload.registration_scheme,
      payload.registration_number,
    );
    if (this.rows.has(key)) return Promise.resolve(null); // ignore-duplicates
    this.inserts += 1;
    const row: MasterRow = {
      ...payload,
      id: `row-${this.nextId++}`,
      registration_identity_key: key,
      verification_sources: payload.verification_sources,
      verification_conflicts: payload.verification_conflicts,
      verification_unresolved_fields: payload.verification_unresolved_fields,
      verified_at: null,
      catalogue_version: 1,
    };
    this.rows.set(key, row);
    return Promise.resolve(row);
  }

  // deno-lint-ignore no-explicit-any
  updateCandidate(id: string, patch: Record<string, any>): Promise<boolean> {
    for (const [key, row] of this.rows) {
      if (row.id !== id) continue;
      if (row.review_status !== "candidate") {
        // Mirrors the live PATCH filter review_status=eq.candidate: an
        // approved/retired row is structurally untouchable.
        this.approvedWriteAttempts += 1;
        return Promise.resolve(true);
      }
      this.updates += 1;
      this.rows.set(key, { ...row, ...patch });
      return Promise.resolve(true);
    }
    return Promise.resolve(false);
  }
}

// ---------------------------------------------------------------------------
// AI extraction fixture (what buildStructuredResponse would produce)
// ---------------------------------------------------------------------------

// deno-lint-ignore no-explicit-any
function aiStructured(overrides: Record<string, any> = {}): any {
  return {
    product_name: "Custodia",
    product_category: "fungicide",
    form_type: "liquid",
    registration: {
      country_code: "AU",
      scheme: "apvma",
      registration_number: null,
      registrant: "Adama Australia Pty Ltd",
      registered_product_name: "Custodia",
      label_reference: null,
      label_version: null,
    },
    active_ingredients: [
      {
        name: "Azoxystrobin",
        concentration: 120,
        concentration_unit: "g/L",
        activity_group: { scheme: "frac", code: "11", common_name: "QoI / Strobilurin" },
        group_source: "authoritative_classification",
        identity_source: "ai_interpretation",
      },
      {
        name: "Tebuconazole",
        concentration: 200,
        concentration_unit: "g/L",
        activity_group: { scheme: "frac", code: "3", common_name: "DMI / Triazole" },
        group_source: "authoritative_classification",
        identity_source: "ai_interpretation",
      },
    ],
    activity_groups: ["11", "3"],
    activity_group_scheme: "frac",
    registered_uses: [
      {
        crop: "Grapevines",
        target_raw: "Powdery mildew",
        target: "powdery_mildew",
        rates: [
          { label: "Dilute spraying", basis: "per_100_litres", value: 65, min_value: null, max_value: null, unit: "mL", raw_text: null },
        ],
        withholding_period_days: 28,
        re_entry_period_hours: null,
        restrictions: "Do not re-enter treated areas until the spray has dried.",
      },
    ],
    label_rate_bases: ["per_100_litres"],
    verification: {
      status: "partially_verified",
      sources: [
        { kind: "ai_interpretation", name: "Model extraction (gpt-4o)", reference: null, retrieved_at: "2026-08-19T00:00:00Z" },
        { kind: "authoritative_classification", name: "VineTrack activity group reference v1 (FRAC/HRAC/IRAC)", reference: null, retrieved_at: "2026-08-19T00:00:00Z" },
      ],
      conflicts: [],
      unresolved_fields: ["label_reference", "label_version", "registration_number", "re_entry_period_hours"],
      verified_at: null,
    },
    activity_group_table_version: 1,
    schema_version: 1,
    ...overrides,
  };
}

const NOW_ISO = "2026-08-19T00:00:00Z";
const NOW_MS = Date.parse(NOW_ISO);

// deno-lint-ignore no-explicit-any
function activeNamed(actives: any[], name: string): any {
  // deno-lint-ignore no-explicit-any
  return actives.find((a: any) => a.name === name);
}

// ===========================================================================
// §A — registry: jurisdiction picks the adapter, never AI
// ===========================================================================

Deno.test("registry: AU has the APVMA adapter; NZ/GB/US are declared future", () => {
  assertEquals(adapterFor("AU")?.id, "apvma", "AU adapter");
  assertEquals(adapterFor("NZ"), null, "NZ adapter is future");
  assertEquals(adapterFor("GB"), null, "GB adapter is future");
  assertEquals(adapterFor("US"), null, "US adapter is future");
  assertEquals(adapterFor(""), null, "blank country has no adapter");
  assertEquals(adapterFor("FR"), null, "unlisted country has no adapter");
  const nz = registryEntryFor("NZ");
  assert(nz !== null && nz.schemes.includes("acvm") && nz.schemes.includes("nz_epa"), "NZ schemes declared");
});

// ===========================================================================
// §H/23 + §O/40 — Custodia resolved through the normal evidence path
// ===========================================================================

Deno.test("40/23: AU vineyard + Custodia resolves AU:apvma:66541 with register-backed chemistry", async () => {
  clearApvmaCache();
  const fixture = { ...FULL_REGISTER, requestLog: [] as string[] };
  const deps = makeDeps(fixture);
  const discovery = await discoverAuthoritative("AU", "Custodia", null, deps);

  assertEquals(discovery.adapter, "apvma", "AU adapter selected");
  assertEquals(discovery.outcome, "resolved", "identity established");
  const reg = discovery.registration!;
  assertEquals(reg.registration_identity_key, "AU:apvma:66541", "canonical identity");
  assertEquals(reg.registered_product_name, "CUSTODIA 320 SC FUNGICIDE", "verbatim register name");
  assertEquals(reg.registrant, "ADAMA AUSTRALIA PTY LIMITED", "registrant of record");
  assertEquals(reg.match_mode, "formulation_suffix", "deterministic match mode");

  // Structured chemistry generated through the register + authoritative table.
  assertEquals(reg.active_ingredients.length, 2, "two actives, never merged");
  const azoxy = activeNamed(reg.active_ingredients, "Azoxystrobin");
  const tebu = activeNamed(reg.active_ingredients, "Tebuconazole");
  assertEquals(azoxy?.concentration, 120, "Azoxystrobin 120");
  assertEquals(azoxy?.concentration_unit, "g/L", "Azoxystrobin unit");
  assertEquals(azoxy?.activity_group?.code, "11", "Azoxystrobin FRAC 11");
  assertEquals(azoxy?.activity_group?.scheme, "frac", "Azoxystrobin scheme");
  assertEquals(azoxy?.identity_source, "official_register", "register identity source");
  assertEquals(tebu?.concentration, 200, "Tebuconazole 200");
  assertEquals(tebu?.activity_group?.code, "3", "Tebuconazole FRAC 3");
  assertEquals(tebu?.group_source, "authoritative_classification", "group from authoritative table");

  // Provenance present, register status carried, label approval referenced.
  assert(reg.sources.length >= 2, "official_register sources present");
  assert(reg.sources.every((s) => s.kind === "official_register"), "sources are register-kind");
  assert(reg.label_version?.includes("112233") === true, "current label approval referenced");
  assert(reg.register_status?.startsWith("R") === true, "register status recorded");

  // No foreign sources: every request stayed on the AU government register.
  assert(fixture.requestLog!.length > 0, "requests were made");
  assert(
    fixture.requestLog!.every((u) => u.startsWith("https://data.gov.au/")),
    "only the AU register was consulted",
  );

  // Candidate created once, deduplicated, as a CANDIDATE with provenance.
  const merged = mergeDiscoveryIntoStructured(aiStructured(), reg);
  const payload = buildCandidatePayload(merged, "Custodia", reg, NOW_ISO, 1)!;
  assertEquals(payload.review_status, "candidate", "automation can only enqueue candidates");
  assertEquals(payload.source_kind, "official_register", "authoritative provenance");
  assert(Boolean(payload.source_reference?.includes("data.gov.au")), "reproducible register reference");
  const ops = new MockOps();
  const outcome = await upsertCandidate(ops, payload, NOW_MS);
  assertEquals(outcome.action, "created", "candidate created");
  assertEquals(ops.rows.size, 1, "exactly one row");
});

Deno.test("23: merged Custodia keeps actives separate and both FRAC groups", () => {
  clearApvmaCache();
  return (async () => {
    const deps = makeDeps({ ...FULL_REGISTER });
    const discovery = await discoverAuthoritative("AU", "Custodia", null, deps);
    const merged = mergeDiscoveryIntoStructured(aiStructured(), discovery.registration!);

    assertEquals(merged.active_ingredients.length, 2, "two actives");
    const codes = [...merged.activity_groups].sort();
    assertEquals(codes.join(","), "11,3", "both groups, one entry each");
    assertEquals(merged.activity_group_scheme, "frac", "scheme");
    assertEquals(merged.verification.status, "partially_verified", "AI can never verify; register identity is not approval");
    assertEquals(merged.match_source, "authoritative_candidate", "candidate, not master");
    // Narrative re-entry stays narrative: no invented hours.
    assertEquals(merged.registered_uses[0].re_entry_period_hours ?? null, null, "no fabricated re-entry hours");
  })();
});

// ===========================================================================
// §H/24 + §O/43 — similar-name protection
// ===========================================================================

Deno.test("24/43: Custodia and Custodia Forte resolve independently; no substring mapping", async () => {
  clearApvmaCache();
  const deps = makeDeps({ ...FULL_REGISTER });
  const custodia = await discoverAuthoritative("AU", "Custodia", null, deps);
  assertEquals(custodia.registration?.registration_identity_key, "AU:apvma:66541", "Custodia → 66541");

  clearApvmaCache();
  const forte = await discoverAuthoritative("AU", "Custodia Forte", null, deps);
  assertEquals(forte.registration?.registration_identity_key, "AU:apvma:91636", "Custodia Forte → 91636");
  assertEquals(forte.registration?.active_ingredients.find((a) => a.name === "Azoxystrobin")?.concentration, 222, "Forte keeps its own concentrations");
});

Deno.test("24: with Custodia 320 SC lapsed from the register, 'Custodia' NEVER falls to Custodia Forte", async () => {
  clearApvmaCache();
  const deps = makeDeps(fixtureWithoutCustodia320());
  const discovery = await discoverAuthoritative("AU", "Custodia", null, deps);
  assertEquals(discovery.outcome, "unresolved", "fails closed instead of borrowing the sibling");
});

Deno.test("name discipline: correspondence and ambiguity rules", () => {
  assert(nameCorresponds("Custodia", "CUSTODIA 320 SC FUNGICIDE"), "formulation suffix corresponds");
  assert(!nameCorresponds("Custodia", "CUSTODIA FORTE FUNGICIDE"), "'forte' is never ignorable");
  assert(nameCorresponds("custodia forte", "CUSTODIA FORTE FUNGICIDE"), "category word is ignorable");
  assert(!nameCorresponds("Custodia", "MY CUSTODIA"), "substring never matches");
  assertEquals(normaliseProductName("  CUSTODIA-320  SC "), "custodia 320 sc", "normalisation");

  const twin = { ...CUSTODIA_320, pcode: "70000", fpname: "CUSTODIA 500 WG FUNGICIDE" };
  const selection = selectProductRow(["custodia"], [CUSTODIA_320, twin] as never);
  assertEquals(selection as string, "ambiguous", "two suffix matches fail closed");
});

Deno.test("hallucinated registration number never binds the wrong product", async () => {
  clearApvmaCache();
  // AI claims 91636 for "Custodia": number exists but names do not correspond
  // → the pointer is discarded; the name path still resolves 66541 correctly.
  const deps = makeDeps({ ...FULL_REGISTER });
  const withRegister = await discoverAuthoritative("AU", "Custodia", "91636", deps);
  assertEquals(withRegister.registration?.registration_identity_key, "AU:apvma:66541", "name path wins over bad pointer");

  clearApvmaCache();
  // Same bad pointer with 66541 lapsed: unresolved, never Forte.
  const deps2 = makeDeps(fixtureWithoutCustodia320());
  const lapsed = await discoverAuthoritative("AU", "Custodia", "91636", deps2);
  assertEquals(lapsed.outcome, "unresolved", "bad pointer fails closed");
});

// ===========================================================================
// §O/41 — approved master never re-enters ingestion
// ===========================================================================

Deno.test("41: an approved identity is never touched or duplicated by ingestion", async () => {
  clearApvmaCache();
  const ops = new MockOps();
  ops.seed({
    registration_number: "66541",
    review_status: "approved",
    source_kind: "official_register",
    registered_product_name: "Custodia 320 SC",
  });
  const deps = makeDeps({ ...FULL_REGISTER });
  const discovery = await discoverAuthoritative("AU", "Custodia", null, deps);
  const merged = mergeDiscoveryIntoStructured(aiStructured(), discovery.registration!);
  const payload = buildCandidatePayload(merged, "Custodia", discovery.registration!, NOW_ISO, 1)!;
  const outcome = await upsertCandidate(ops, payload, NOW_MS);
  assertEquals(outcome.action, "approved_exists", "approved row is the answer, not a new candidate");
  assertEquals(ops.inserts, 0, "no insert");
  assertEquals(ops.updates, 0, "no update");
  assertEquals(ops.rows.size, 1, "still one row");
});

// ===========================================================================
// §O/42 + 48 — dedupe and repeated lookups
// ===========================================================================

Deno.test("42: an existing AI candidate is upgraded in place by authoritative evidence", async () => {
  clearApvmaCache();
  const ops = new MockOps();
  const seeded = ops.seed({
    registration_number: "66541",
    review_status: "candidate",
    source_kind: "ai_interpretation",
    registered_product_name: "Custodia",
    retrieved_at: "2026-08-01T00:00:00Z",
  });
  const deps = makeDeps({ ...FULL_REGISTER });
  const discovery = await discoverAuthoritative("AU", "Custodia", null, deps);
  const merged = mergeDiscoveryIntoStructured(aiStructured(), discovery.registration!);
  const payload = buildCandidatePayload(merged, "Custodia", discovery.registration!, NOW_ISO, 1)!;
  const outcome = await upsertCandidate(ops, payload, NOW_MS);
  assertEquals(outcome.action, "refreshed", "existing candidate refreshed, not duplicated");
  assertEquals(outcome.reason, "authority_upgrade", "AI candidate upgraded to register evidence");
  assertEquals(ops.inserts, 0, "no second insert");
  assertEquals(ops.rows.size, 1, "one candidate per registration identity");
  const row = await ops.selectByIdentityKey(seeded.registration_identity_key);
  assertEquals(row?.source_kind, "official_register", "provenance upgraded");
  assertEquals(row?.id, seeded.id, "same row identity");
});

Deno.test("48: twenty vineyards searching the same product still yield ONE candidate", async () => {
  clearApvmaCache();
  const ops = new MockOps();
  const deps = makeDeps({ ...FULL_REGISTER });
  for (let i = 0; i < 20; i++) {
    const discovery = await discoverAuthoritative("AU", "Custodia", null, deps);
    const merged = mergeDiscoveryIntoStructured(aiStructured(), discovery.registration!);
    const payload = buildCandidatePayload(merged, "Custodia", discovery.registration!, NOW_ISO, 1)!;
    await upsertCandidate(ops, payload, NOW_MS);
  }
  assertEquals(ops.rows.size, 1, "exactly one candidate row");
  assertEquals(ops.inserts, 1, "one insert across twenty lookups");
});

Deno.test("AI-only evidence never overwrites an authoritative candidate", async () => {
  const ops = new MockOps();
  ops.seed({
    registration_number: "66541",
    review_status: "candidate",
    source_kind: "official_register",
    registered_product_name: "CUSTODIA 320 SC FUNGICIDE",
    retrieved_at: NOW_ISO,
    common_names: ["custodia 320 sc fungicide"],
  });
  const payload = buildCandidatePayload(
    { ...aiStructured(), registration: { ...aiStructured().registration, registration_number: "66541" }, match_source: "ai_candidate" },
    "Custodia",
    null, // no authoritative discovery this time
    NOW_ISO,
    1,
  )!;
  assertEquals(payload.source_kind, "ai_interpretation", "AI payload attribution");
  const ops0updates = ops.updates;
  const outcome = await upsertCandidate(ops, payload, NOW_MS);
  assertEquals(outcome.action, "reused", "existing authoritative candidate wins");
  const row = await ops.selectByIdentityKey("AU:apvma:66541");
  assertEquals(row?.source_kind, "official_register", "provenance not downgraded");
  assertEquals(row?.registered_product_name, "CUSTODIA 320 SC FUNGICIDE", "content not overwritten");
  // Only a search-alias merge is permitted for AI repeats.
  assert(ops.updates - ops0updates <= 1, "at most an alias merge");
});

// ===========================================================================
// §O/44 + 45 — jurisdiction boundaries
// ===========================================================================

Deno.test("44: foreign jurisdictions cannot run the AU adapter or accept foreign evidence", async () => {
  const deps = makeDeps({ ...FULL_REGISTER });
  const nz = await discoverAuthoritative("NZ", "Custodia", null, deps);
  assertEquals(nz.outcome, "not_supported", "NZ has no adapter yet");
  const gb = await discoverAuthoritative("GB", "Custodia", null, deps);
  assertEquals(gb.outcome, "not_supported", "GB has no adapter yet");
  // A GB-registered payload can never become an AU candidate: the candidate
  // payload carries the response's own country, and the AU merge only ever
  // stamps AU register identities.
  const gbStructured = aiStructured({
    registration: {
      country_code: "GB",
      scheme: "other",
      registration_number: "16393",
      registrant: "Adama Agricultural Solutions UK Ltd",
      registered_product_name: "Custodia",
      label_reference: null,
      label_version: null,
    },
  });
  const payload = buildCandidatePayload(gbStructured, "Custodia", null, NOW_ISO, 1)!;
  assertEquals(payload.registration_country, "GB", "foreign identity stays foreign");
  assert(
    identityKey(payload.registration_country, payload.registration_scheme, payload.registration_number) !== "AU:apvma:66541",
    "foreign registration is a separate product",
  );
});

Deno.test("45: missing country runs no authoritative ingestion", async () => {
  const fixture = { ...FULL_REGISTER, requestLog: [] as string[] };
  const deps = makeDeps(fixture);
  const result = await discoverAuthoritative("", "Custodia", null, deps);
  assertEquals(result.outcome, "no_country", "fails closed");
  assertEquals(fixture.requestLog!.length, 0, "no source fetch without a country");
});

// ===========================================================================
// §O/46 — partial extraction: nothing fabricated
// ===========================================================================

Deno.test("46: WHP absent stays absent; register constituent outage keeps identity but invents no chemistry", async () => {
  clearApvmaCache();
  // AI use without a withholding period.
  const noWhp = aiStructured();
  delete noWhp.registered_uses[0].withholding_period_days;
  const deps = makeDeps({ ...FULL_REGISTER });
  const discovery = await discoverAuthoritative("AU", "Custodia", null, deps);
  const merged = mergeDiscoveryIntoStructured(noWhp, discovery.registration!);
  assertEquals(merged.registered_uses[0].withholding_period_days ?? null, null, "no fabricated WHP");
  const payload = buildCandidatePayload(merged, "Custodia", discovery.registration!, NOW_ISO, 1)!;
  assertEquals(payload.registered_uses[0].withholding_period_days ?? null, null, "candidate stores the gap honestly");

  // Constituent resource down: identity resolved, chemistry unresolved.
  clearApvmaCache();
  const broken: RegisterFixture = {
    ...FULL_REGISTER,
    failResources: new Set([APVMA_RESOURCES.productConstituents]),
  };
  const partial = await discoverAuthoritative("AU", "Custodia", null, makeDeps(broken));
  assertEquals(partial.outcome, "resolved", "identity still established");
  assertEquals(partial.registration?.active_ingredients.length, 0, "no invented register actives");
  assert(
    partial.registration!.unresolved_fields.includes("active_ingredients"),
    "chemistry gap recorded",
  );
});

// ===========================================================================
// §O/47 — source disagreement becomes a structured conflict
// ===========================================================================

Deno.test("47: register vs AI concentration disagreement is recorded, never silently resolved", async () => {
  clearApvmaCache();
  const wrongAI = aiStructured();
  wrongAI.active_ingredients[0].concentration = 250; // register says 120
  const deps = makeDeps({ ...FULL_REGISTER });
  const discovery = await discoverAuthoritative("AU", "Custodia", null, deps);
  const merged = mergeDiscoveryIntoStructured(wrongAI, discovery.registration!);

  assertEquals(merged.verification.status, "conflict", "evidence state is conflict");
  // deno-lint-ignore no-explicit-any
  const conflict = merged.verification.conflicts.find((c: any) => c.field === "concentration");
  assert(Boolean(conflict), "concentration conflict recorded");
  assertEquals(conflict.active_ingredient_name, "Azoxystrobin", "names the active");
  assert(conflict.extracted_value.includes("250"), "AI value preserved");
  assert(conflict.authoritative_value.includes("120"), "register value preserved");
  assertEquals(conflict.authoritative_source, "official_register", "authority attributed");
  // Register value is served, but the conflict travels with it.
  assertEquals(activeNamed(merged.active_ingredients, "Azoxystrobin")?.concentration, 120, "register value served");

  const payload = buildCandidatePayload(merged, "Custodia", discovery.registration!, NOW_ISO, 1)!;
  assertEquals(payload.verification_status, "conflict", "candidate carries the conflict");
  assertEquals(payload.review_status, "candidate", "conflicted candidate is not approvable by automation");
});

// ===========================================================================
// §O/49 + §G — master refresh
// ===========================================================================

function approvedCustodiaRow(ops: MockOps): MasterRow {
  return ops.seed({
    registration_number: "66541",
    review_status: "approved",
    source_kind: "official_register",
    registered_product_name: "CUSTODIA 320 SC FUNGICIDE",
    registrant: "ADAMA AUSTRALIA PTY LIMITED",
    product_category: "fungicide",
    form_type: "liquid",
    label_version: "APVMA label approval 112233 (5/09/2012 0:00)",
    retrieved_at: NOW_ISO,
    catalogue_version: 4,
    active_ingredients: [
      { name: "Azoxystrobin", concentration: 120, concentration_unit: "g/L" },
      { name: "Tebuconazole", concentration: 200, concentration_unit: "g/L" },
    ],
  });
}

Deno.test("49: refresh detects material change without mutating the approved row", async () => {
  clearApvmaCache();
  const ops = new MockOps();
  const row = approvedCustodiaRow(ops);
  const changedRegister: RegisterFixture = {
    ...FULL_REGISTER,
    products: [{ ...CUSTODIA_320, sname: "NEW HOLDER PTY LTD" }, CUSTODIA_FORTE],
  };
  const result = await refreshMasterRow(row, makeDeps(changedRegister));
  assertEquals(result.outcome, "material_change", "material change detected");
  assertEquals(result.changes.length, 1, "one change");
  assertEquals(result.changes[0].field, "registrant", "registrant changed");
  // The reviewable update is the RETURNED diff; the approved row is untouched.
  const patch = buildCandidateRefreshPatch(row, result, NOW_ISO);
  assertEquals(patch, null, "no write path exists for approved rows");
  assertEquals(ops.approvedWriteAttempts, 0, "no write was attempted");
  assertEquals((await ops.selectByIdentityKey(row.registration_identity_key))?.registrant, "ADAMA AUSTRALIA PTY LIMITED", "row unchanged");
  assertEquals((await ops.selectByIdentityKey(row.registration_identity_key))?.catalogue_version, 4, "revision unchanged");
});

Deno.test("refresh outcomes: no change, stale evidence, chemistry conflict, delisting, source down", async () => {
  const ops = new MockOps();
  const row = approvedCustodiaRow(ops);

  clearApvmaCache();
  const same = await refreshMasterRow(row, makeDeps({ ...FULL_REGISTER }));
  assertEquals(same.outcome, "no_material_change", "identical + fresh");

  clearApvmaCache();
  const staleRow = { ...row, retrieved_at: "2026-01-01T00:00:00Z" };
  const stale = await refreshMasterRow(staleRow, makeDeps({ ...FULL_REGISTER }));
  assertEquals(stale.outcome, "evidence_refreshed", "identical + stale evidence");

  clearApvmaCache();
  const chemistryChanged: RegisterFixture = {
    ...FULL_REGISTER,
    prodcon: {
      ...FULL_REGISTER.prodcon,
      "66541": [
        { pcode: "66541", ccode: "PMAZ", ctype: "A", camount: "150.000000", cucode: "g/L" },
        { pcode: "66541", ccode: "TZTB", ctype: "A", camount: "200.000000", cucode: "g/L" },
      ],
    },
  };
  const conflict = await refreshMasterRow(row, makeDeps(chemistryChanged));
  assertEquals(conflict.outcome, "conflict", "chemistry disagreement is a conflict, no arbitrary winner");

  clearApvmaCache();
  const delisted = await refreshMasterRow(row, makeDeps(fixtureWithoutCustodia320()));
  assertEquals(delisted.outcome, "material_change", "delisting is material");
  assertEquals(delisted.changes[0].field, "registration_status", "status change named");

  clearApvmaCache();
  const down: RegisterFixture = {
    ...FULL_REGISTER,
    failResources: new Set([APVMA_RESOURCES.product]),
  };
  const unavailable = await refreshMasterRow(row, makeDeps(down));
  assertEquals(unavailable.outcome, "source_unavailable", "source down is not 'not registered'");
});

Deno.test("refresh patches apply only to candidate rows", async () => {
  clearApvmaCache();
  const ops = new MockOps();
  const candidate = ops.seed({
    registration_number: "66541",
    review_status: "candidate",
    source_kind: "official_register",
    registered_product_name: "CUSTODIA 320 SC FUNGICIDE",
    registrant: "OLD NAME PTY LTD",
    retrieved_at: "2026-01-01T00:00:00Z",
    active_ingredients: [
      { name: "Azoxystrobin", concentration: 120, concentration_unit: "g/L" },
      { name: "Tebuconazole", concentration: 200, concentration_unit: "g/L" },
    ],
  });
  const result = await refreshMasterRow(candidate, makeDeps({ ...FULL_REGISTER }));
  assertEquals(result.outcome, "material_change", "registrant differs");
  const patch = buildCandidateRefreshPatch(candidate, result, NOW_ISO)!;
  assert(patch !== null, "candidate patch produced");
  assertEquals(patch.registrant, "ADAMA AUSTRALIA PTY LIMITED", "register value applied to candidate");
  await ops.updateCandidate(candidate.id, patch);
  assertEquals((await ops.selectByIdentityKey(candidate.registration_identity_key))?.registrant, "ADAMA AUSTRALIA PTY LIMITED", "candidate refreshed");
});

// ===========================================================================
// §M/36 — source unavailable falls through honestly
// ===========================================================================

Deno.test("36: register outage is 'source_unavailable', never 'not registered', and AI path survives", async () => {
  clearApvmaCache();
  const down: RegisterFixture = {
    ...FULL_REGISTER,
    failResources: new Set([APVMA_RESOURCES.product]),
  };
  const discovery = await discoverAuthoritative("AU", "Custodia", null, makeDeps(down));
  assertEquals(discovery.outcome, "source_unavailable", "outage reported as outage");
  assert(Boolean(discovery.error_category), "error category recorded");

  // The AI result is untouched by the outage and still enqueues an AI candidate
  // (existing rules) — with honest AI provenance, never register provenance.
  const structured = aiStructured({
    registration: { ...aiStructured().registration, registration_number: "66541" },
  });
  const payload = buildCandidatePayload(structured, "Custodia", null, NOW_ISO, 1)!;
  assertEquals(payload.source_kind, "ai_interpretation", "no borrowed authority");
  const envelope = discoveryEnvelope(discovery);
  assertEquals(envelope.outcome, "source_unavailable", "provenance state visible to clients");
});

// ===========================================================================
// §J/28 — candidate response envelope
// ===========================================================================

Deno.test("28: authoritative candidate response is useful but never a master match", async () => {
  clearApvmaCache();
  const ops = new MockOps();
  const deps = makeDeps({ ...FULL_REGISTER });
  const discovery = await discoverAuthoritative("AU", "Custodia", null, deps);
  const merged = mergeDiscoveryIntoStructured(aiStructured(), discovery.registration!);
  const payload = buildCandidatePayload(merged, "Custodia", discovery.registration!, NOW_ISO, 1)!;
  const outcome = await upsertCandidate(ops, payload, NOW_MS);
  const envelope = candidateEnvelope(outcome.row!);

  assertEquals(merged.match_source, "authoritative_candidate", "distinct from master");
  assertEquals(envelope.catalogue_status, "candidate", "status is candidate");
  assertEquals(envelope.registration_identity_key, "AU:apvma:66541", "identity travels");
  assert(typeof envelope.master_chemical_id === "string" && envelope.master_chemical_id.length > 0, "id present");
  // The master envelope key is reserved for approved matches only.
  assertEquals(merged.master ?? null, null, "no master block on a candidate response");
});

Deno.test("register-only response (AI outage) is honest: register facts only, uses unresolved", async () => {
  clearApvmaCache();
  const deps = makeDeps({ ...FULL_REGISTER });
  const discovery = await discoverAuthoritative("AU", "Custodia", null, deps);
  const structured = buildRegisterOnlyStructured(discovery.registration!, 1);
  assertEquals(structured.product_name, "CUSTODIA 320 SC FUNGICIDE", "register name");
  assertEquals(structured.active_ingredients.length, 2, "register chemistry");
  assertEquals(structured.registered_uses.length, 0, "no invented uses");
  assert(structured.verification.unresolved_fields.includes("registered_uses"), "uses unresolved");
  assert(structured.verification.unresolved_fields.includes("label_reference"), "label reference unresolved");
  assertEquals(structured.match_source, "authoritative_candidate", "candidate class");
  assertEquals(structured.verification.status, "partially_verified", "register-backed but not approved");
});

// ===========================================================================
// §L — cache: load shedding, country-scoped, provenance-preserving
// ===========================================================================

Deno.test("33/34: repeated discovery is served from the country-scoped cache", async () => {
  clearApvmaCache();
  const fixture = { ...FULL_REGISTER, requestLog: [] as string[] };
  const deps = makeDeps(fixture);
  const first = await discoverAuthoritative("AU", "Custodia", null, deps);
  const requestsAfterFirst = fixture.requestLog!.length;
  const second = await discoverAuthoritative("AU", "Custodia", null, deps);
  assertEquals(second.cache, "hit", "second lookup is a cache hit");
  assertEquals(fixture.requestLog!.length, requestsAfterFirst, "no extra register fetches");
  assertEquals(
    second.registration?.registration_identity_key,
    first.registration?.registration_identity_key,
    "same identity",
  );
});

Deno.test("34: the cache never serves across country or source boundaries", () => {
  const cache = new SourceCache();
  const now = Date.parse(NOW_ISO);
  cache.set("AU", "apvma", "discover:custodia|", { hello: true }, 60_000, now, NOW_ISO, "AU:apvma:66541");
  assert(cache.get("AU", "apvma", "discover:custodia|", now) !== null, "same country+source hits");
  assertEquals(cache.get("NZ", "apvma", "discover:custodia|", now), null, "cross-country miss");
  assertEquals(cache.get("AU", "hse", "discover:custodia|", now), null, "cross-source miss");
  assertEquals(cache.get("AU", "apvma", "discover:custodia|", now + 61_000), null, "TTL expiry");
});

// ===========================================================================
// Identity + candidate-only guarantees
// ===========================================================================

Deno.test("identity key mirrors sql/199: uppercased trimmed number, country-scoped", () => {
  assertEquals(identityKey("AU", "apvma", " 66541 "), "AU:apvma:66541", "canonical form");
  assertEquals(identityKey("GB", "other", "16393"), "GB:other:16393", "foreign identity distinct");
});

Deno.test("10: automated ingestion can only ever create candidates", async () => {
  clearApvmaCache();
  const ops = new MockOps();
  const deps = makeDeps({ ...FULL_REGISTER });
  const discovery = await discoverAuthoritative("AU", "Custodia Forte", null, deps);
  const merged = mergeDiscoveryIntoStructured(aiStructured({ product_name: "Custodia Forte" }), discovery.registration!);
  const payload = buildCandidatePayload(merged, "Custodia Forte", discovery.registration!, NOW_ISO, 1)!;
  assertEquals(payload.review_status, "candidate", "payload pinned to candidate");
  const outcome = await upsertCandidate(ops, payload, NOW_MS);
  assertEquals(outcome.row?.review_status, "candidate", "stored as candidate");
  for (const row of ops.rows.values()) {
    assertEquals(row.review_status, "candidate", "nothing auto-approved");
  }
});

// ===========================================================================
// Stage 4 — official label evidence (AU/APVMA approved-label claim data)
// ===========================================================================

/** Forte-correct AI extraction (registration and chemistry agree with the
 * register) so Stage 4 tests exercise LABEL merging, not Stage 3 conflicts. */
// deno-lint-ignore no-explicit-any
function forteAi(overrides: Record<string, any> = {}): any {
  return aiStructured({
    product_name: "Custodia Forte",
    active_ingredients: [
      {
        name: "Azoxystrobin",
        concentration: 222,
        concentration_unit: "g/L",
        activity_group: { scheme: "frac", code: "11", common_name: "QoI / Strobilurin" },
        group_source: "authoritative_classification",
        identity_source: "ai_interpretation",
      },
      {
        name: "Tebuconazole",
        concentration: 370,
        concentration_unit: "g/L",
        activity_group: { scheme: "frac", code: "3", common_name: "DMI / Triazole" },
        group_source: "authoritative_classification",
        identity_source: "ai_interpretation",
      },
    ],
    registered_uses: [
      {
        crop: "Grapevines",
        target_raw: "Powdery mildew",
        target: "powdery_mildew",
        rates: [
          { label: "Dilute spraying", basis: "per_100_litres", value: 40, min_value: null, max_value: null, unit: "mL", raw_text: null },
        ],
        withholding_period_days: 28,
        re_entry_period_hours: null,
        restrictions: "Do not re-enter treated areas until the spray has dried.",
      },
    ],
    ...overrides,
  });
}

Deno.test("49: label statement parsing is strict — seq reassembly, WHP forms, re-entry, correspondence", () => {
  const text = assembleProductComments(FORTE_PRODCOM);
  assert(
    text.includes("GRAPEVINES: DO NOT HARVEST FOR 4 WEEKS AFTER"),
    "chunks reassemble in seq order, mid-word splits joined",
  );
  assertEquals(whpDaysFromStatement("DO NOT HARVEST FOR 4 WEEKS AFTERAPPLICATION.", "withholding"), 28, "weeks → days");
  assertEquals(whpDaysFromStatement("DO NOT HARVEST FOR 15 DAYS AFTER APPLICATION.", "other"), 15, "harvest statements are self-descriptive");
  assertEquals(whpDaysFromStatement("NOT REQUIRED WHEN USED AS DIRECTED.", "withholding"), 0, "label-stated 'not required' = 0 days");
  assertEquals(whpDaysFromStatement("NOT REQUIRED WHEN USED AS DIRECTED.", "other"), null, "'not required' binds only inside a withholding section");
  assertEquals(whpDaysFromStatement("APPLY IN AT LEAST 100 L WATER PER HECTARE", "withholding"), null, "numbers are never guessed into a WHP");
  assertEquals(reentryHoursFromStatement("DO NOT allow entry into treated areas until the spray has dried."), null, "a condition is not a period");
  assertEquals(reentryHoursFromStatement("Do not re-enter treated areas for 24 hours."), 24, "explicit hours");
  assertEquals(reentryHoursFromStatement("Do not re-enter for 2 days."), 48, "explicit days converted");
  assertEquals(reentryHoursFromStatement("DO NOT HARVEST FOR 14 DAYS"), null, "harvest wording is not re-entry");
  assert(cropsCorrespond("GRAPEVINE", "GRAPEVINES"), "register/label plurals correspond");
  assert(cropsCorrespond("Grapes (winegrapes)", "GRAPEVINE"), "AI grape wording corresponds");
  assert(!cropsCorrespond("GRAPEVINE", "ALMONDS"), "different crops never correspond");
  assert(targetsCorrespond("Downy mildew", "DOWNY MILDEW ON GRAPE"), "crop qualifier stripped");
  assert(targetsCorrespond("Botrytis", "BOTRYTIS CINEREA"), "word-boundary prefix");
  assert(!targetsCorrespond("Powdery mildew", "DOWNY MILDEW ON GRAPE"), "different targets never correspond");
});

Deno.test("50: the adapter resolves the approved label's use claims for Custodia Forte 91636", async () => {
  clearApvmaCache();
  const discovery = await discoverAuthoritative("AU", "Custodia Forte", null, makeDeps({ ...FULL_REGISTER }));
  assertEquals(discovery.outcome, "resolved", "Forte resolves");
  const reg = discovery.registration!;
  assertEquals(reg.registration_identity_key, "AU:apvma:91636", "Forte identity");
  const evidence = reg.label_evidence!;
  assert(evidence !== null && evidence !== undefined, "label evidence resolved");
  assertEquals(evidence.claims.length, 8, "all label use claims carried");

  const grape = evidence.claims.filter((c) => c.crop === "GRAPEVINE");
  assertEquals(grape.length, 3, "three grapevine claims");
  assertEquals(grape.find((c) => c.target_raw === "POWDERY MILDEW")?.target, "powdery_mildew", "clean target mapping");
  assertEquals(grape.find((c) => c.target_raw === "BOTRYTIS CINEREA")?.target, "botrytis", "botrytis mapping");
  assertEquals(grape.find((c) => c.target_raw === "DOWNY MILDEW ON GRAPE")?.target, "downy_mildew", "downy mapping");
  for (const c of grape) {
    assertEquals(c.withholding_period_days, 28, "grape WHP 4 weeks = 28 days from the label statement");
    assertEquals(c.re_entry_period_hours ?? null, null, "no re-entry statement → no re-entry period, never fabricated");
  }
  assert(
    grape[0].statements.some((s) => s.startsWith("GRAPEVINES: DO NOT HARVEST FOR 4 WEEKS")),
    "verbatim label statement preserved",
  );
  assertEquals(evidence.claims.find((c) => c.crop === "ALMOND")?.withholding_period_days, 0, "label-stated 'not required' → 0 days");
  assertEquals(evidence.claims.find((c) => c.crop === "MACADAMIA")?.withholding_period_days, 15, "macadamia 15 days");

  assert(!reg.unresolved_fields.includes("registered_uses"), "uses resolved by label evidence");
  assert(reg.unresolved_fields.includes("rates:GRAPEVINE"), "rates await the label document — never invented");
  assert(reg.unresolved_fields.includes("re_entry_period_hours"), "absent re-entry stays an honest gap");
  assert(
    reg.sources.some((s) => s.kind === "manufacturer_label" && s.name.includes("registered use claims")),
    "label evidence attributed to manufacturer_label with a reproducible reference",
  );
});

Deno.test("51: merged uses are label-backed with field-level provenance; AI rates carried, never promoted", async () => {
  clearApvmaCache();
  const discovery = await discoverAuthoritative("AU", "Custodia Forte", null, makeDeps({ ...FULL_REGISTER }));
  const merged = mergeDiscoveryIntoStructured(forteAi(), discovery.registration!);

  assertEquals(merged.registered_uses.length, 8, "the label's claim set is served");
  // deno-lint-ignore no-explicit-any
  const powdery = merged.registered_uses.find((u: any) => u.crop === "GRAPEVINE" && u.target_raw === "POWDERY MILDEW");
  assertEquals(powdery.provenance?.claim, "manufacturer_label", "claim provenance");
  assertEquals(powdery.rates.length, 1, "AI rate carried onto the matching claim");
  assertEquals(powdery.rates[0].value, 40, "rate value preserved");
  assertEquals(powdery.provenance?.rates, "ai_interpretation", "rates stay AI-attributed — never promoted");
  assertEquals(powdery.withholding_period_days, 28, "label WHP served");
  assertEquals(powdery.provenance?.withholding_period, "manufacturer_label", "WHP is label-backed");
  assert(String(powdery.restrictions ?? "").startsWith("GRAPEVINES: DO NOT HARVEST"), "verbatim label statement as restrictions");

  // deno-lint-ignore no-explicit-any
  const botrytis = merged.registered_uses.find((u: any) => u.target_raw === "BOTRYTIS CINEREA");
  assertEquals(botrytis.rates.length, 0, "no AI rate for botrytis — stays empty, never borrowed");
  assertEquals(botrytis.provenance?.rates ?? null, null, "no rate provenance without rates");

  assert(!merged.verification.unresolved_fields.includes("registered_uses"), "whole-array gap resolved");
  assert(merged.verification.unresolved_fields.includes("rates:GRAPEVINE"), "per-crop rate gap awaits admin review");
  assertEquals(merged.verification.status, "partially_verified", "agreeing evidence → no conflict");
  assertEquals(merged.label_rate_bases.length, 1, "bases from carried rates");
  assert(
    merged.verification.sources.some((s: { kind: string }) => s.kind === "manufacturer_label"),
    "label evidence cited",
  );
});

Deno.test("52: AI WHP disagreement with the label is a structured conflict; the label value is served", async () => {
  clearApvmaCache();
  const discovery = await discoverAuthoritative("AU", "Custodia Forte", null, makeDeps({ ...FULL_REGISTER }));
  const ai = forteAi();
  ai.registered_uses[0].withholding_period_days = 21;
  const merged = mergeDiscoveryIntoStructured(ai, discovery.registration!);

  // deno-lint-ignore no-explicit-any
  const powdery = merged.registered_uses.find((u: any) => u.crop === "GRAPEVINE" && u.target_raw === "POWDERY MILDEW");
  assertEquals(powdery.withholding_period_days, 28, "label value served");
  // deno-lint-ignore no-explicit-any
  const conflict = merged.verification.conflicts.find((c: any) => c.field === "withholding_period_days");
  assert(conflict !== undefined, "disagreement recorded");
  assertEquals(conflict.extracted_source, "ai_interpretation", "AI side attributed");
  assertEquals(conflict.authoritative_source, "manufacturer_label", "label side attributed");
  assertEquals(merged.verification.status, "conflict", "status honesty");
});

Deno.test("53: AI-only uses are dropped with a conflict — the label's claim set is authoritative", async () => {
  clearApvmaCache();
  const discovery = await discoverAuthoritative("AU", "Custodia Forte", null, makeDeps({ ...FULL_REGISTER }));
  const ai = forteAi();
  ai.registered_uses.push({
    crop: "Citrus",
    target_raw: "Black spot",
    rates: [{ label: "", basis: "per_hectare", value: 1, unit: "L" }],
    withholding_period_days: 7,
  });
  const merged = mergeDiscoveryIntoStructured(ai, discovery.registration!);

  assertEquals(merged.registered_uses.length, 8, "citrus never served");
  // deno-lint-ignore no-explicit-any
  assert(!merged.registered_uses.some((u: any) => /citrus/i.test(String(u.crop))), "no invented claim");
  // deno-lint-ignore no-explicit-any
  const conflict = merged.verification.conflicts.find((c: any) => c.field === "registered_uses");
  assert(conflict !== undefined && conflict.extracted_value.includes("Citrus"), "dropped use recorded as a conflict");
  assertEquals(conflict.authoritative_source, "manufacturer_label", "label authority cited");
});

Deno.test("54: distinct grape uses stay distinct — rates never collapse across targets", async () => {
  clearApvmaCache();
  const discovery = await discoverAuthoritative("AU", "Custodia Forte", null, makeDeps({ ...FULL_REGISTER }));
  const ai = forteAi();
  ai.registered_uses.push({
    crop: "Grapes",
    target_raw: "Botrytis",
    rates: [{ label: "Bunch closure", basis: "per_100_litres", value: 80, min_value: null, max_value: null, unit: "mL", raw_text: null }],
    withholding_period_days: 28,
  });
  const merged = mergeDiscoveryIntoStructured(ai, discovery.registration!);

  // deno-lint-ignore no-explicit-any
  const powdery = merged.registered_uses.find((u: any) => u.target_raw === "POWDERY MILDEW");
  // deno-lint-ignore no-explicit-any
  const botrytis = merged.registered_uses.find((u: any) => u.target_raw === "BOTRYTIS CINEREA");
  // deno-lint-ignore no-explicit-any
  const downy = merged.registered_uses.find((u: any) => u.target_raw === "DOWNY MILDEW ON GRAPE");
  assertEquals(powdery.rates[0]?.value, 40, "powdery keeps its own rate");
  assertEquals(botrytis.rates[0]?.value, 80, "botrytis keeps its own rate");
  assertEquals(downy.rates.length, 0, "downy has no AI rate — stays empty");
  assertEquals(merged.verification.conflicts.length, 0, "both AI uses matched label claims");
});

Deno.test("55: re-entry is never fabricated — an AI value is carried but stays AI-attributed", async () => {
  clearApvmaCache();
  const discovery = await discoverAuthoritative("AU", "Custodia Forte", null, makeDeps({ ...FULL_REGISTER }));
  const ai = forteAi();
  ai.registered_uses[0].re_entry_period_hours = 24;
  const merged = mergeDiscoveryIntoStructured(ai, discovery.registration!);

  // deno-lint-ignore no-explicit-any
  const powdery = merged.registered_uses.find((u: any) => u.target_raw === "POWDERY MILDEW");
  assertEquals(powdery.re_entry_period_hours, 24, "AI detail carried where the label is silent");
  assertEquals(powdery.provenance?.re_entry, "ai_interpretation", "…but clearly AI-attributed, never promoted");
  // deno-lint-ignore no-explicit-any
  const downy = merged.registered_uses.find((u: any) => u.target_raw === "DOWNY MILDEW ON GRAPE");
  assertEquals(downy.re_entry_period_hours ?? null, null, "no borrowed re-entry on unmatched claims");
  assert(merged.verification.unresolved_fields.includes("re_entry_period_hours"), "gap stays honest for admin review");
});

Deno.test("56: label evidence failure is fail-soft — register identity and chemistry stand", async () => {
  // Claims source down: registration resolves, AI uses stand, nothing invented.
  clearApvmaCache();
  const claimsDown: RegisterFixture = {
    ...FULL_REGISTER,
    failResources: new Set([APVMA_RESOURCES.productUses]),
  };
  const d1 = await discoverAuthoritative("AU", "Custodia Forte", null, makeDeps(claimsDown));
  assertEquals(d1.outcome, "resolved", "identity stands");
  assertEquals(d1.registration?.label_evidence ?? null, null, "no label evidence claimed");
  assertEquals(d1.registration?.active_ingredients.length, 2, "chemistry stands");
  const merged1 = mergeDiscoveryIntoStructured(forteAi(), d1.registration!);
  assertEquals(merged1.registered_uses.length, 1, "AI uses stand unchanged");
  assertEquals(merged1.registered_uses[0].provenance ?? null, null, "no label provenance without label evidence");
  assert(
    !merged1.verification.sources.some((s: { kind: string }) => s.kind === "manufacturer_label"),
    "no label source cited",
  );
  assert(!merged1.verification.unresolved_fields.includes("rates:GRAPEVINE"), "no label-scoped gaps without evidence");

  // Statements source down: claims stand; WHP stays an honest per-crop gap.
  clearApvmaCache();
  const statementsDown: RegisterFixture = {
    ...FULL_REGISTER,
    failResources: new Set([APVMA_RESOURCES.productComments]),
  };
  const d2 = await discoverAuthoritative("AU", "Custodia Forte", null, makeDeps(statementsDown));
  const evidence = d2.registration!.label_evidence!;
  assertEquals(evidence.claims.length, 8, "claims survive a statements outage");
  assertEquals(evidence.claims[0].withholding_period_days ?? null, null, "WHP not invented without its statement");
  assert(d2.registration!.unresolved_fields.includes("withholding_period:GRAPEVINE"), "per-crop WHP gap recorded");
});

Deno.test("57: register-only lookup (AI outage) serves label claims with empty rates", async () => {
  clearApvmaCache();
  const discovery = await discoverAuthoritative("AU", "Custodia Forte", null, makeDeps({ ...FULL_REGISTER }));
  const structured = buildRegisterOnlyStructured(discovery.registration!, 1);

  assertEquals(structured.registered_uses.length, 8, "label claims served without any AI");
  // deno-lint-ignore no-explicit-any
  for (const u of structured.registered_uses as any[]) {
    assertEquals(u.rates.length, 0, "no rates invented");
    assertEquals(u.provenance?.claim, "manufacturer_label", "claims attributed");
  }
  // deno-lint-ignore no-explicit-any
  const grape = structured.registered_uses.find((u: any) => u.target_raw === "POWDERY MILDEW");
  assertEquals(grape.withholding_period_days, 28, "label WHP served");
  assertEquals(structured.verification.status, "partially_verified", "register-backed but not approved");
  assert(structured.verification.unresolved_fields.includes("rates:GRAPEVINE"), "rates await the label document");
  assert(!structured.verification.unresolved_fields.includes("registered_uses"), "uses no longer a whole-array gap");
});

Deno.test("58: master_refresh re-checks label evidence — drift is material, stored AI rates and the row identity survive", async () => {
  clearApvmaCache();
  const ops = new MockOps();
  const discovery = await discoverAuthoritative("AU", "Custodia Forte", null, makeDeps({ ...FULL_REGISTER }));
  const merged = mergeDiscoveryIntoStructured(forteAi(), discovery.registration!);
  const payload = buildCandidatePayload(merged, "Custodia Forte", discovery.registration!, NOW_ISO, 1)!;
  const outcome = await upsertCandidate(ops, payload, NOW_MS);
  const row = outcome.row!;
  const originalId = row.id;

  // The APVMA publishes a revised label: grape WHP drops to 3 weeks.
  clearApvmaCache();
  const revised: RegisterFixture = {
    ...FULL_REGISTER,
    prodcom: {
      "91636": [{
        pcode: "91636",
        seq: 1,
        applic:
          "WITHHOLDING PERIODS\nHarvest\nALMONDS: NOT REQUIRED WHEN USED AS DIRECTED.\nGRAPEVINES: DO NOT HARVEST FOR 3 WEEKS AFTER APPLICATION.\nMACADAMIAS: DO NOT HARVEST FOR 15 DAYS AFTER APPLICATION.",
      }],
    },
  };
  const result = await refreshMasterRow(row, makeDeps(revised));
  assertEquals(result.outcome, "material_change", "label drift is a material change");
  assert(result.changes.some((c) => c.field === "registered_uses"), "uses diff surfaced");

  const patch = buildCandidateRefreshPatch(row, result, NOW_ISO)!;
  assert(patch !== null, "candidate refresh may be applied");
  // deno-lint-ignore no-explicit-any
  const powdery = (patch.registered_uses as any[]).find((u) => u.target_raw === "POWDERY MILDEW");
  assertEquals(powdery.withholding_period_days, 21, "fresh label WHP applied");
  assertEquals(powdery.rates[0]?.value, 40, "stored AI rate carried through the refresh");
  assertEquals(powdery.provenance?.rates, "ai_interpretation", "carried rate stays AI-attributed");

  await ops.updateCandidate(row.id, patch);
  const stored = await ops.selectByIdentityKey("AU:apvma:91636");
  assertEquals(stored!.id, originalId, "Master UUID preserved — refresh never re-keys");
  assertEquals(stored!.review_status, "candidate", "still a candidate — never auto-approved");

  // Approved rows are structurally untouchable by the refresh patch.
  const approved = ops.seed({
    registration_number: "55555",
    review_status: "approved",
    registered_product_name: "APPROVED PRODUCT",
  });
  assertEquals(buildCandidateRefreshPatch(approved, result, NOW_ISO), null, "no patch for approved rows");
});

Deno.test("59: Custodia 66541 stays fail-closed — Forte's label evidence never substitutes", async () => {
  clearApvmaCache();
  const lapsed = fixtureWithoutCustodia320();
  const byName = await discoverAuthoritative("AU", "Custodia", null, makeDeps(lapsed));
  assertEquals(byName.outcome, "unresolved", "lapsed Custodia never resolves");
  assertEquals(byName.registration ?? null, null, "no registration bound");

  clearApvmaCache();
  const byHint = await discoverAuthoritative("AU", "Custodia", "66541", makeDeps(lapsed));
  assertEquals(byHint.outcome, "unresolved", "hint to a lapsed number stays unresolved");
  assertEquals(byHint.registration ?? null, null, "91636's label evidence never leaks onto 66541");
});
