// Candidate discovery regression tests — the "Dithane Rainshield" close-out
// defect: searching a PARTIAL product name returned "no registered product"
// because the search path reused the strict identity resolver (verification)
// as its only register access, and a partial name deliberately never
// resolves strictly. Discovery and verification are now SEPARATE:
//
//   * discovery (this file's subject) lists plausible register CANDIDATES
//     from partial names, registered names, registration numbers, and pure
//     case/spacing variants — several when ambiguous, never a silent pick,
//     never any authority;
//   * verification is unchanged: the strict resolver runs on the EXACT
//     selected identity (verbatim register name + registration number) and
//     remains the only place authority is established.
//
// The Dithane fixture is LIVE APVMA PubCRIS data (retrieved 2026-08-21):
// product 59688 "DITHANE RAINSHIELD NEO TEC FUNGICIDE", UPL AUSTRALIA PTY
// LTD, FUNGICIDE, WATER DISPERSIBLE GRANULE, regcode R (expires 30/06/2026),
// constituent CRDMC = MANCOZEB 750 g/kg. Nothing in the implementation knows
// the name.
//
// Required scenario coverage:
//   D01 partial name           "Dithane rainshield"        → candidate 59688
//   D02 fuller name            "Dithane Rainshield Neo Tec" → candidate 59688
//       (strict rank) AND the strict resolver itself resolves
//   D03 registration number    "59688"                      → candidate 59688
//   D04 case differences       "dItHaNe RAINSHIELD"         → candidate 59688
//   D05 spacing differences    "Rain shield"                → candidate 59688
//   D06 ambiguous name → MULTIPLE candidates, strict resolver stays
//       fail-closed (ambiguous), and the NUMBER-disambiguated selection
//       resolves through register_number_verified
//   D07 selected candidate resolves through the authoritative APVMA path
//       (name-only AND name+number)
//   D08 candidates are structurally authority-free (identity/display only)
//   D09 jurisdiction gate: no adapter / no country → no candidates
//   D10 fail-soft: register outage → [] (search never breaks)
//   D11 discoveryMatchRank unit rules (token-boundary discipline; substrings
//       still impossible)

import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  discoverAuthoritative,
  discoverRegisterCandidates,
} from "./ingest.ts";
import { APVMA_RESOURCES, clearApvmaCache } from "./apvma.ts";
import { discoveryMatchRank } from "./matching.ts";
import type { AdapterDeps } from "./contract.ts";

// ---------------------------------------------------------------------------
// Register fixture — live PubCRIS values for APVMA 59688 plus an ambiguity
// family (two pack registrations sharing ONE verbatim name, a real PubCRIS
// phenomenon) and unrelated noise.
// ---------------------------------------------------------------------------

// deno-lint-ignore no-explicit-any
type Row = Record<string, any>;

const DITHANE = {
  pcode: "59688",
  fpname: "DITHANE RAINSHIELD NEO TEC FUNGICIDE",
  sname: "UPL AUSTRALIA PTY LTD",
  hlevel1: "FUNGICIDE",
  fdesc: "WATER DISPERSIBLE GRANULE",
  regcode: "R",
  expdate: "30/06/2026 0:00",
};

const CUSTODIA_A = {
  pcode: "66541",
  fpname: "CUSTODIA 320 SC FUNGICIDE",
  sname: "ADAMA AUSTRALIA PTY LIMITED",
  hlevel1: "FUNGICIDE",
  fdesc: "SUSPENSION CONCENTRATE",
  regcode: "R",
  expdate: "30/06/2029 0:00",
};

// Same verbatim register name, different registration (pack registration).
const CUSTODIA_B = { ...CUSTODIA_A, pcode: "66999" };

const CUSTODIA_FORTE = {
  pcode: "70001",
  fpname: "CUSTODIA FORTE FUNGICIDE",
  sname: "ADAMA AUSTRALIA PTY LIMITED",
  hlevel1: "FUNGICIDE",
  fdesc: "SUSPENSION CONCENTRATE",
  regcode: "R",
  expdate: "30/06/2029 0:00",
};

const NOISE = {
  pcode: "80160",
  fpname: "Sprayseal Pruning Wound Treatment",
  sname: "OMNIA SPECIALITIES (AUSTRALIA) PTY LTD",
  hlevel1: "FUNGICIDE",
  fdesc: "SUSPENSION CONCENTRATE",
  regcode: "R",
  expdate: "30/06/2030 0:00",
};

interface Fixture {
  products: Row[];
  prodcon: Record<string, Row[]>;
  constit: Record<string, string>;
  labelreg: Record<string, Row[]>;
  produse: Record<string, Row[]>;
  hosts: Record<string, string>;
  pests: Record<string, string>;
  prodcom: Record<string, Row[]>;
  requestLog: string[];
}

function dithaneFixture(): Fixture {
  return {
    products: [DITHANE, CUSTODIA_A, CUSTODIA_B, CUSTODIA_FORTE, NOISE],
    prodcon: {
      "59688": [
        { pcode: "59688", ccode: "CRDMC", ctype: "A", camount: "750.000000", cucode: "g/kg" },
      ],
    },
    constit: { CRDMC: "MANCOZEB" },
    labelreg: {
      "59688": [{ pcode: "59688", regno: "110042", regdate: "1/07/2024 0:00" }],
    },
    produse: {
      "59688": [{ pcode: "59688", hostcode: "FRVG", pestcode: "YDOWM" }],
    },
    hosts: { FRVG: "GRAPEVINE" },
    pests: { YDOWM: "DOWNY MILDEW" },
    prodcom: {
      "59688": [{
        pcode: "59688",
        seq: 1,
        applic:
          "WITHHOLDING PERIODS\nHarvest\nGRAPES: DO NOT HARVEST FOR 14 DAYS AFTER APPLICATION.",
      }],
    },
    requestLog: [],
  };
}

/**
 * Live-faithful CKAN emulation (same as resolver_test.ts): full-text q
 * matches when EVERY whitespace token of q appears as a whole WORD of the
 * product name. q="Rain shield" therefore retrieves ZERO rows for
 * "…RAINSHIELD…" — only the compact retrieval variant finds it, exactly as
 * on the live datastore.
 */
function wordsMatch(q: string, fpname: string): boolean {
  const words = new Set(fpname.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean));
  return q.toLowerCase().split(/\s+/).filter(Boolean).every((t) => words.has(t));
}

/** Scalar or array filter → list of accepted values. */
// deno-lint-ignore no-explicit-any
function filterValues(v: any): string[] | null {
  if (v === undefined || v === null) return null;
  return Array.isArray(v) ? v.map(String) : [String(v)];
}

function makeFetch(fixture: Fixture): typeof fetch {
  const respond = (records: Row[]): Response =>
    new Response(JSON.stringify({ success: true, result: { records } }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  return ((input: Request | URL | string): Promise<Response> => {
    const url = new URL(String(input));
    fixture.requestLog.push(url.toString());
    if (url.hostname !== "data.gov.au") {
      // Label-document discovery hosts are rejected — that path is fail-soft
      // by contract and must never affect these results.
      return Promise.reject(new Error(`forbidden host: ${url.hostname}`));
    }
    const resource = url.searchParams.get("resource_id") ?? "";
    const q = url.searchParams.get("q");
    const filtersRaw = url.searchParams.get("filters");
    // deno-lint-ignore no-explicit-any
    const filters: any = filtersRaw ? JSON.parse(filtersRaw) : null;

    let records: Row[] = [];
    if (resource === APVMA_RESOURCES.product) {
      records = fixture.products;
      const pcodes = filterValues(filters?.pcode);
      if (pcodes) records = records.filter((r) => pcodes.includes(String(r.pcode)));
      if (q) records = records.filter((r) => wordsMatch(q, String(r.fpname)));
    } else if (resource === APVMA_RESOURCES.productConstituents) {
      const pcodes = filterValues(filters?.pcode) ?? [];
      records = pcodes.flatMap((p) => fixture.prodcon[p] ?? []);
    } else if (resource === APVMA_RESOURCES.constituentNames) {
      const codes = filterValues(filters?.ccode) ?? [];
      records = codes.map((c) => ({ ccode: c, cname: fixture.constit[c] })).filter((r) => r.cname);
    } else if (resource === APVMA_RESOURCES.labelRegistrations) {
      const pcodes = filterValues(filters?.pcode) ?? [];
      records = pcodes.flatMap((p) => fixture.labelreg[p] ?? []);
    } else if (resource === APVMA_RESOURCES.productUses) {
      const pcodes = filterValues(filters?.pcode) ?? [];
      records = pcodes.flatMap((p) => fixture.produse[p] ?? []);
    } else if (resource === APVMA_RESOURCES.hosts) {
      const codes = filterValues(filters?.hostcode) ?? [];
      records = codes.map((c) => ({ hostcode: c, hostdesc: fixture.hosts[c] })).filter((r) => r.hostdesc);
    } else if (resource === APVMA_RESOURCES.pests) {
      const codes = filterValues(filters?.pestcode) ?? [];
      records = codes.map((c) => ({ pestcode: c, pestdesc: fixture.pests[c] })).filter((r) => r.pestdesc);
    } else if (resource === APVMA_RESOURCES.productComments) {
      const pcodes = filterValues(filters?.pcode) ?? [];
      records = pcodes.flatMap((p) => fixture.prodcom[p] ?? []);
    }
    return Promise.resolve(respond(records));
  }) as typeof fetch;
}

function deps(fixture: Fixture): AdapterDeps {
  return { fetchFn: makeFetch(fixture), now: () => new Date("2026-08-21T00:00:00Z") };
}

// ---------------------------------------------------------------------------
// D01–D05: the regression queries all surface APVMA 59688
// ---------------------------------------------------------------------------

Deno.test("D01 partial name 'Dithane rainshield' lists candidate 59688", async () => {
  clearApvmaCache();
  const f = dithaneFixture();
  const candidates = await discoverRegisterCandidates("AU", "Dithane rainshield", deps(f));
  assert(candidates.length >= 1, "expected at least one candidate");
  const top = candidates[0];
  assertEquals(top.registration_number, "59688");
  assertEquals(top.registered_product_name, "DITHANE RAINSHIELD NEO TEC FUNGICIDE");
  assertEquals(top.registrant, "UPL AUSTRALIA PTY LTD");
  assertEquals(top.product_category, "fungicide");
  assertEquals(top.register_status, "R, expires 30/06/2026 0:00");
  // Partial name: NOT a strict correspondence — discovery rank 1.
  assertEquals(top.match_rank, 1);
  // Display chemistry rides along, attributed nowhere (display only).
  assertEquals(top.actives_summary, "Mancozeb 750 g/kg");
  assertEquals(top.activity_groups, ["M3"]);
});

Deno.test("D02 fuller name ranks strictly AND still resolves strictly", async () => {
  clearApvmaCache();
  const f = dithaneFixture();
  const candidates = await discoverRegisterCandidates("AU", "Dithane Rainshield Neo Tec", deps(f));
  assert(candidates.length >= 1);
  assertEquals(candidates[0].registration_number, "59688");
  // "FUNGICIDE" is a droppable formulation/category suffix → strict tier.
  assertEquals(candidates[0].match_rank, 0);

  // The strict resolver never regressed for this query.
  clearApvmaCache();
  const d = await discoverAuthoritative("AU", "Dithane Rainshield Neo Tec", null, deps(f));
  assertEquals(d.outcome, "resolved");
  assertEquals(d.registration?.registration_number, "59688");
  assertEquals(d.registration?.match_mode, "formulation_suffix");
});

Deno.test("D03 bare registration number '59688' lists the product", async () => {
  clearApvmaCache();
  const f = dithaneFixture();
  const candidates = await discoverRegisterCandidates("AU", "59688", deps(f));
  assertEquals(candidates.length, 1);
  assertEquals(candidates[0].registration_number, "59688");
  assertEquals(candidates[0].registered_product_name, "DITHANE RAINSHIELD NEO TEC FUNGICIDE");
  assertEquals(candidates[0].match_rank, 0);
});

Deno.test("D04 case differences still discover", async () => {
  clearApvmaCache();
  const f = dithaneFixture();
  const candidates = await discoverRegisterCandidates("AU", "dItHaNe RAINSHIELD", deps(f));
  assert(candidates.length >= 1);
  assertEquals(candidates[0].registration_number, "59688");
});

Deno.test("D05 spacing differences discover via compact retrieval", async () => {
  clearApvmaCache();
  const f = dithaneFixture();
  // Live CKAN behaviour: q="Rain shield" retrieves ZERO rows ("rainshield"
  // is one word) — the compact retrieval variant finds it, and the
  // token-boundary run match ranks it.
  const candidates = await discoverRegisterCandidates("AU", "Rain shield", deps(f));
  assert(candidates.length >= 1, "compact variant should retrieve the row");
  assertEquals(candidates[0].registration_number, "59688");
  assertEquals(candidates[0].match_rank, 1);
});

// ---------------------------------------------------------------------------
// D06: ambiguity → multiple candidates, strict stays fail-closed, and the
// number-disambiguated selection resolves
// ---------------------------------------------------------------------------

Deno.test("D06 ambiguous name returns candidates; strict resolver fails closed; number disambiguates", async () => {
  clearApvmaCache();
  const f = dithaneFixture();

  // Discovery: every plausible row is LISTED — both pack registrations of
  // "CUSTODIA 320 SC FUNGICIDE" and the FORTE variant (a human may mean it;
  // the strict matcher would never auto-bind it).
  const candidates = await discoverRegisterCandidates("AU", "Custodia", deps(f));
  const numbers = candidates.map((c) => c.registration_number).sort();
  assertEquals(numbers, ["66541", "66999", "70001"]);
  // The identically-named pair rank strictly; FORTE only as loose discovery.
  const forte = candidates.find((c) => c.registration_number === "70001");
  assertEquals(forte?.match_rank, 1);

  // Verification is untouched: the same query stays AMBIGUOUS — no silent
  // selection ever leaves the resolver.
  clearApvmaCache();
  const strict = await discoverAuthoritative("AU", "Custodia", null, deps(f));
  assertEquals(strict.outcome, "ambiguous");

  // The operator picks ONE candidate; its registration number + verbatim
  // name resolve deterministically through the register-number path.
  clearApvmaCache();
  const selected = await discoverAuthoritative(
    "AU",
    "CUSTODIA 320 SC FUNGICIDE",
    "66999",
    deps(f),
  );
  assertEquals(selected.outcome, "resolved");
  assertEquals(selected.registration?.registration_number, "66999");
  assertEquals(selected.registration?.match_mode, "register_number_verified");
  assertEquals(selected.registration?.registration_identity_key, "AU:apvma:66999");
});

// ---------------------------------------------------------------------------
// D07: the selected Dithane candidate resolves through the authoritative path
// ---------------------------------------------------------------------------

Deno.test("D07 selected candidate resolves via the strict APVMA path (name and name+number)", async () => {
  clearApvmaCache();
  const f = dithaneFixture();

  // Name+number (what the apps send after a candidate is selected).
  const byNumber = await discoverAuthoritative(
    "AU",
    "DITHANE RAINSHIELD NEO TEC FUNGICIDE",
    "59688",
    deps(f),
  );
  assertEquals(byNumber.outcome, "resolved");
  const reg = byNumber.registration!;
  assertEquals(reg.match_mode, "register_number_verified");
  assertEquals(reg.registration_identity_key, "AU:apvma:59688");
  assertEquals(reg.registered_product_name, "DITHANE RAINSHIELD NEO TEC FUNGICIDE");
  assertEquals(reg.registrant, "UPL AUSTRALIA PTY LTD");
  // Register-backed chemistry, attributed to the register.
  assertEquals(reg.active_ingredients.length, 1);
  assertEquals(reg.active_ingredients[0].name, "Mancozeb");
  assertEquals(reg.active_ingredients[0].concentration, 750);
  assertEquals(reg.active_ingredients[0].identity_source, "official_register");
  // Official label evidence resolved from the register's claim data.
  assertEquals(reg.label_evidence?.claims?.[0]?.crop, "GRAPEVINE");
  assertEquals(reg.label_evidence?.claims?.[0]?.target_raw, "DOWNY MILDEW");
  assert(reg.sources.every((s) =>
    s.kind === "official_register" || s.kind === "manufacturer_label"
  ));

  // Verbatim-name-only selection (clients without the number) also resolves.
  clearApvmaCache();
  const byName = await discoverAuthoritative(
    "AU",
    "DITHANE RAINSHIELD NEO TEC FUNGICIDE",
    null,
    deps(f),
  );
  assertEquals(byName.outcome, "resolved");
  assertEquals(byName.registration?.registration_number, "59688");
  assertEquals(byName.registration?.match_mode, "exact_name");
});

// ---------------------------------------------------------------------------
// D08–D10: authority boundaries and failure containment
// ---------------------------------------------------------------------------

Deno.test("D08 candidates are structurally authority-free", async () => {
  clearApvmaCache();
  const f = dithaneFixture();
  const candidates = await discoverRegisterCandidates("AU", "Dithane rainshield", deps(f));
  assert(candidates.length >= 1);
  // Identity + display ONLY: no uses, no rates, no label facts, no
  // verification evidence, no provenance — nothing a client could mistake
  // for a resolved product.
  assertEquals(
    Object.keys(candidates[0]).sort(),
    [
      "actives_summary",
      "activity_groups",
      "match_rank",
      "product_category",
      "register_status",
      "registered_product_name",
      "registrant",
      "registration_number",
    ],
  );
});

Deno.test("D09 jurisdiction gate: no adapter / no country → no candidates", async () => {
  clearApvmaCache();
  const f = dithaneFixture();
  assertEquals(await discoverRegisterCandidates("NZ", "Dithane rainshield", deps(f)), []);
  assertEquals(await discoverRegisterCandidates("", "Dithane rainshield", deps(f)), []);
  assertEquals(await discoverRegisterCandidates("XX", "Dithane rainshield", deps(f)), []);
});

Deno.test("D10 register outage → empty candidates, never an exception", async () => {
  clearApvmaCache();
  const failing: AdapterDeps = {
    fetchFn: (() => Promise.reject(new Error("network down"))) as typeof fetch,
    now: () => new Date("2026-08-21T00:00:00Z"),
  };
  assertEquals(await discoverRegisterCandidates("AU", "Dithane rainshield", failing), []);
});

// ---------------------------------------------------------------------------
// D11: discovery rank unit rules — generosity is bounded, substrings stay
// structurally impossible, and rank is ordering only
// ---------------------------------------------------------------------------

Deno.test("D11 discoveryMatchRank keeps token-boundary discipline", () => {
  const NAME = "DITHANE RAINSHIELD NEO TEC FUNGICIDE";
  // Strict correspondences rank 0.
  assertEquals(discoveryMatchRank("DITHANE RAINSHIELD NEO TEC FUNGICIDE", NAME), 0);
  assertEquals(discoveryMatchRank("Dithane Rainshield Neo Tec", NAME), 0);
  // Contiguous token runs (any position, any case/spacing) rank 1.
  assertEquals(discoveryMatchRank("Dithane rainshield", NAME), 1);
  assertEquals(discoveryMatchRank("rain shield", NAME), 1);
  assertEquals(discoveryMatchRank("NEO TEC", NAME), 1);
  // Ordered whole-token subsequence ranks 2.
  assertEquals(discoveryMatchRank("dithane fungicide", NAME), 2);
  // Out-of-order tokens do not match.
  assertEquals(discoveryMatchRank("fungicide dithane", NAME), null);
  // Substrings inside a token can never match — same guarantee as the
  // strict matcher.
  assertEquals(discoveryMatchRank("custodia", "MYCUSTODIA FUNGICIDE"), null);
  assertEquals(discoveryMatchRank("rain", NAME), null);
  // Unrelated names do not match.
  assertEquals(discoveryMatchRank("Prosaro", NAME), null);
  // Empty query never matches.
  assertEquals(discoveryMatchRank("", NAME), null);
});
