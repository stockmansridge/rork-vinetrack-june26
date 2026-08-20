// Stage 5E tests — remaining-unresolved AWRI name classification.
//
// Focus areas, in order of importance:
//   1. Identity safety: variant designators (FORTE, ULTRA, DUO, …) can never
//      be dropped from either side at any tier; approved-actives rows can
//      never be matched; ties fail closed.
//   2. Register-fact corroboration: active constituents and concentrations
//      can only corroborate or ELIMINATE — never invent a match; positive
//      contradictions remove a row, missing data downgrades to probable.
//   3. Dry-run guarantees: pure classification, zero writes, deterministic.

import {
  assert,
  assertEquals,
  assertExists,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  buildRegisterIndex,
  classifyUnresolved,
  collectCandidatePcodes,
  corroborateActives,
  formatMatchReport,
  normaliseNameLoose,
  numericsAgree,
  parseManifestActive,
  type ClassifyInput,
  type RegisterActive,
  type Stage5EResolution,
  type Stage5EResult,
  type UnmatchedInput,
} from "./seed_awri_match.ts";
import type { AwriSeedEntry, AwriSeedManifest, RegisterProductRow } from "./seed_awri.ts";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function entry(name: string, actives: string[]): AwriSeedEntry {
  return {
    awri_product_name: name,
    apvma_registration_number: null,
    active_constituents: actives,
    activity_groups: [],
    re_entry_codes: [],
    sections: ["fungicide"],
    expansion: "plain",
    listed_as: [name],
  };
}

function manifest(
  entries: AwriSeedEntry[],
  cancelledNames: string[] = [],
): AwriSeedManifest {
  return {
    manifest_version: 1,
    source: { id: "awri_dogbook_2026_27", edition: "2026/27" },
    table2_rows_transcribed: entries.length,
    entries,
    cancelled_products: cancelledNames.map((n) => ({
      awri_product_name: n,
      active_constituent: "",
      status: "cancelled",
      last_use_date: "2025-01-01",
    })),
  };
}

function row(
  pcode: string,
  fpname: string,
  sname = "ACME CROP SCIENCE PTY LTD",
  regcode = "R",
): RegisterProductRow {
  return { pcode, fpname, sname, hlevel1: null, fdesc: null, regcode, expdate: null };
}

function unmatched(name: string): UnmatchedInput {
  return { awri_product_name: name, expansion: "plain", sections: ["fungicide"] };
}

function classify(
  entries: AwriSeedEntry[],
  names: string[],
  rows: RegisterProductRow[],
  actives: Record<string, RegisterActive[]> = {},
  existing: string[] = [],
  cancelledNames: string[] = [],
): Stage5EResult {
  const input: ClassifyInput = {
    manifest: manifest(entries, cancelledNames),
    unresolved: names.map(unmatched),
    registerRows: rows,
    activesByPcode: new Map(Object.entries(actives)),
    existingIdentities: new Set(existing),
  };
  return classifyUnresolved(input);
}

function only(result: Stage5EResult, name: string): Stage5EResolution {
  const found = result.resolutions.find((r) => r.awri_product_name === name);
  assertExists(found, `resolution missing for ${name}`);
  return found;
}

const AZOXY: RegisterActive[] = [{ name: "AZOXYSTROBIN", amount: 250 }];

// ---------------------------------------------------------------------------
// 1. Normalisation — typography only, never merging distinct tokens
// ---------------------------------------------------------------------------

Deno.test("1: boundary normalisation equates 250SC and 250 SC without rewriting brands", () => {
  assertEquals(normaliseNameLoose("Agristar 250SC"), "agristar 250 sc");
  assertEquals(normaliseNameLoose("AGRISTAR 250 SC"), "agristar 250 sc");
  assertEquals(normaliseNameLoose("Bi-Thrin 100EC"), "bi thrin 100 ec");
  assertEquals(normaliseNameLoose("A-Star® 250 SC"), "a star 250 sc");
  // Splitting never joins: distinct brands stay distinct.
  assert(normaliseNameLoose("AlphaCy") !== normaliseNameLoose("Alpha Cy 100"));
});

// ---------------------------------------------------------------------------
// 2. Variant-token safety — the non-negotiable guard
// ---------------------------------------------------------------------------

Deno.test("2a: bare parent never reaches its FORTE variant at any tier", () => {
  const result = classify(
    [entry("Custodia", ["tebuconazole + azoxystrobin"])],
    ["Custodia"],
    [row("91636", "CUSTODIA FORTE FUNGICIDE", "ADAMA AUSTRALIA PTY LIMITED")],
    { "91636": [{ name: "TEBUCONAZOLE", amount: 200 }, { name: "AZOXYSTROBIN", amount: 120 }] },
  );
  assertEquals(only(result, "Custodia").match_class, "no_apvma_match");
});

Deno.test("2b: DUO/ULTRA can never be dropped — not forward, reverse, registrant, or subsequence", () => {
  const result = classify(
    [entry("Weedmaster", ["glyphosate"]), entry("Serenade Ultra", ["Bacillus subtilis"])],
    ["Weedmaster"],
    [
      row("60001", "WEEDMASTER DUO HERBICIDE", "NUFARM AUSTRALIA LIMITED"),
      row("60002", "NUFARM WEEDMASTER DUO", "NUFARM AUSTRALIA LIMITED"),
    ],
    { "60001": [{ name: "GLYPHOSATE", amount: 470 }] },
  );
  assertEquals(only(result, "Weedmaster").match_class, "no_apvma_match");
});

Deno.test("2c: a variant token INSIDE the requested name must match like any token", () => {
  const result = classify(
    [entry("Alpha Forte 250 SC", ["alpha-cypermethrin"])],
    ["Alpha Forte 250 SC"],
    [
      row("65245", "CONQUEST ALPHA FORTE 250 SC INSECTICIDE", "CONQUEST CROP PROTECTION PTY LTD"),
      row("65246", "CONQUEST ALPHA 250 SC INSECTICIDE", "CONQUEST CROP PROTECTION PTY LTD"),
    ],
    { "65245": [{ name: "ALPHA-CYPERMETHRIN", amount: 250 }] },
  );
  const r = only(result, "Alpha Forte 250 SC");
  assertEquals(r.match_class, "deterministic_match");
  assertEquals(r.tier, "registrant_prefix");
  assertEquals(r.matched?.registration_number, "65245");
});

Deno.test("2d: requested name with a variant token never falls back to the plain product", () => {
  const result = classify(
    [entry("Custodia Duo", ["tebuconazole + azoxystrobin"])],
    ["Custodia Duo"],
    [row("50000", "CUSTODIA FUNGICIDE", "ADAMA AUSTRALIA PTY LIMITED")],
    { "50000": [{ name: "TEBUCONAZOLE", amount: 200 }, { name: "AZOXYSTROBIN", amount: 120 }] },
  );
  assertEquals(only(result, "Custodia Duo").match_class, "no_apvma_match");
});

// ---------------------------------------------------------------------------
// 3. Tier behaviour
// ---------------------------------------------------------------------------

Deno.test("3a: glued formulation suffix resolves deterministically under boundary normalisation", () => {
  const result = classify(
    [entry("Glister 680 SG", ["glyphosate-mas"])],
    ["Glister 680 SG"],
    [
      row("60560", "GLISTER 680SG HERBICIDE", "SINON AUSTRALIA PTY LIMITED"),
      row("60205", "GLISTER 360 HERBICIDE", "SINON AUSTRALIA PTY LIMITED"),
    ],
    { "60560": [{ name: "GLYPHOSATE PRESENT AS THE MONO-AMMONIUM SALT", amount: 680 }] },
  );
  const r = only(result, "Glister 680 SG");
  assertEquals(r.match_class, "deterministic_match");
  assertEquals(r.tier, "formulation_suffix");
});

Deno.test("3b: registrant prefix is verified against the row's own holder", () => {
  const result = classify(
    [entry("A-Star 250 SC", ["azoxystrobin"])],
    ["A-Star 250 SC"],
    [row("85084", "Sinon A-star 250 SC Fungicide", "SINON AUSTRALIA PTY LIMITED")],
    { "85084": AZOXY },
  );
  const r = only(result, "A-Star 250 SC");
  assertEquals(r.match_class, "deterministic_match");
  assertEquals(r.tier, "registrant_prefix");
  assertEquals(r.corroboration, "pass");
});

Deno.test("3c: a brand prefix that is NOT the holder lands in token_subsequence as probable", () => {
  const result = classify(
    [entry("Airone WG", ["copper as oxychloride + hydroxide"])],
    ["Airone WG"],
    [row("81027", "RELYON AIRONE WG FUNGICIDE", "GOWAN CROP PROTECTION AUSTRALIA PTY LTD")],
    {
      "81027": [
        { name: "COPPER (CU) PRESENT AS COPPER OXYCHLORIDE", amount: 245 },
        { name: "COPPER (CU) PRESENT AS CUPRIC HYDROXIDE", amount: 245 },
      ],
    },
  );
  const r = only(result, "Airone WG");
  assertEquals(r.match_class, "probable_manual_review");
  assertEquals(r.tier, "token_subsequence");
  assertEquals(r.corroboration, "pass");
});

Deno.test("3d: reverse formulation suffix with corroborated strength is deterministic", () => {
  const result = classify(
    [entry("Bravo 500 SC", ["chlorothalonil"])],
    ["Bravo 500 SC"],
    [row("41000", "BRAVO", "SYNGENTA AUSTRALIA PTY LTD")],
    { "41000": [{ name: "CHLOROTHALONIL", amount: 500 }] },
  );
  const r = only(result, "Bravo 500 SC");
  assertEquals(r.match_class, "deterministic_match");
  assertEquals(r.tier, "reverse_formulation_suffix");
});

Deno.test("3e: approved-actives rows (regcode A) are structurally unmatchable", () => {
  const result = classify(
    [entry("Copper Sulphate", ["copper"])],
    ["Copper Sulphate"],
    [row("11111", "COPPER SULPHATE", "SOME HOLDER", "A")],
  );
  assertEquals(only(result, "Copper Sulphate").match_class, "no_apvma_match");
});

// ---------------------------------------------------------------------------
// 4. Corroboration — eliminate on contradiction, downgrade on absence
// ---------------------------------------------------------------------------

Deno.test("4a: wrong active eliminates an exact-name row instead of matching it", () => {
  const result = classify(
    [entry("Meteor", ["azoxystrobin"])],
    ["Meteor"],
    [row("70001", "METEOR", "ACME CROP SCIENCE PTY LTD")],
    { "70001": [{ name: "PARAQUAT PRESENT AS DICHLORIDE", amount: 250 }] },
  );
  assertEquals(only(result, "Meteor").match_class, "no_apvma_match");
});

Deno.test("4b: combined '+' actives require every part; '/' offers alternatives", () => {
  const azoTebu: RegisterActive[] = [
    { name: "AZOXYSTROBIN", amount: 120 },
    { name: "TEBUCONAZOLE", amount: 200 },
  ];
  assertEquals(corroborateActives(["tebuconazole + azoxystrobin"], azoTebu), "pass");
  assertEquals(
    corroborateActives(["tebuconazole + azoxystrobin"], [{ name: "AZOXYSTROBIN", amount: 120 }]),
    "mismatch",
  );
  assertEquals(
    corroborateActives(
      ["potassium bicarbonate / potassium bicarbonate + silicate"],
      [{ name: "POTASSIUM BICARBONATE", amount: 940 }],
    ),
    "pass",
  );
});

Deno.test("4c: salt shorthand and cross-spellings corroborate; enantiomer qualifiers distinguish", () => {
  assertEquals(
    corroborateActives(["glyphosate-mas"], [{
      name: "GLYPHOSATE PRESENT AS THE MONO-AMMONIUM SALT",
      amount: 680,
    }]),
    "pass",
  );
  assertEquals(
    corroborateActives(["sulfur (elemental or crystalline)"], [{ name: "SULPHUR", amount: 800 }]),
    "pass",
  );
  assertEquals(
    corroborateActives(["Bacillus thuringiensis subsp. kurstaki"], [{
      name: "BACILLUS THURINGIENSIS BERLINER.VAR.KURSTAKI",
      amount: null,
    }]),
    "pass",
  );
  // metalaxyl-M is NOT plain metalaxyl — the qualifier is identity.
  assertEquals(
    corroborateActives(["metalaxyl-M + mancozeb"], [
      { name: "METALAXYL", amount: 100 },
      { name: "MANCOZEB", amount: 640 },
    ]),
    "mismatch",
  );
  assertEquals(parseManifestActive("copper as oxychloride + hydroxide").length, 1);
});

Deno.test("4d: missing constituent data can only downgrade to probable, never invent or eliminate", () => {
  const result = classify(
    [entry("A-Star 250 SC", ["azoxystrobin"])],
    ["A-Star 250 SC"],
    [row("85084", "Sinon A-star 250 SC Fungicide", "SINON AUSTRALIA PTY LIMITED")],
    {}, // no constituent data at all
  );
  const r = only(result, "A-Star 250 SC");
  assertEquals(r.match_class, "probable_manual_review");
  assertEquals(r.corroboration, "unknown");
});

Deno.test("4e: a different concentration is a different product — numeric disagreement eliminates", () => {
  const result = classify(
    [entry("Bravo 500 SC", ["chlorothalonil"])],
    ["Bravo 500 SC"],
    [row("41000", "BRAVO", "SYNGENTA AUSTRALIA PTY LTD")],
    { "41000": [{ name: "CHLOROTHALONIL", amount: 720 }] },
  );
  assertEquals(only(result, "Bravo 500 SC").match_class, "no_apvma_match");
  assert(!numericsAgree(["bravo", "500", "sc"], ["bravo"], [{ name: "CHLOROTHALONIL", amount: 720 }]));
  assert(numericsAgree(["bravo", "500", "sc"], ["bravo"], [{ name: "CHLOROTHALONIL", amount: 500 }]));
});

// ---------------------------------------------------------------------------
// 5. Ties fail closed; register facts may break a tie only into "probable"
// ---------------------------------------------------------------------------

Deno.test("5a: two surviving rows are ambiguous, never a pick", () => {
  const bt: RegisterActive[] = [{ name: "BACILLUS THURINGIENSIS SUBSPECIES KURSTAKI", amount: null }];
  const result = classify(
    [entry("Delfin WG", ["Bacillus thuringiensis subsp. kurstaki"])],
    ["Delfin WG"],
    [
      row("45608", "DELFIN WG BIOLOGICAL INSECTICIDE", "CERTIS U.S.A. L.L.C."),
      row("62681", "SIPCAM DELFIN WG BIOLOGICAL INSECTICIDE", "SIPCAM PACIFIC AUSTRALIA PTY LTD"),
    ],
    { "45608": bt, "62681": bt },
  );
  const r = only(result, "Delfin WG");
  assertEquals(r.match_class, "ambiguous");
  assertEquals(r.ambiguous_rows.length, 2);
  assertEquals(r.matched, null);
});

Deno.test("5b: a tie broken by register facts is probable, not deterministic", () => {
  const result = classify(
    [entry("Warden 100", ["azoxystrobin"])],
    ["Warden 100"],
    [
      row("80001", "ACME WARDEN 100 FUNGICIDE", "ACME CROP SCIENCE PTY LTD"),
      row("80002", "ACME WARDEN 100 HERBICIDE", "ACME CROP SCIENCE PTY LTD"),
    ],
    {
      "80001": [{ name: "AZOXYSTROBIN", amount: 100 }],
      "80002": [{ name: "GLYPHOSATE", amount: 100 }], // contradicted -> eliminated
    },
  );
  const r = only(result, "Warden 100");
  assertEquals(r.match_class, "probable_manual_review");
  assertEquals(r.tie_broken_by_register_facts, true);
  assertEquals(r.matched?.registration_number, "80001");
});

// ---------------------------------------------------------------------------
// 6. Existing identities, cancelled guard, rollups, purity
// ---------------------------------------------------------------------------

Deno.test("6a: a match landing on an existing Master identity is an alias, not a new candidate", () => {
  const result = classify(
    [entry("Rondo 360", ["glyphosate"])],
    ["Rondo 360"],
    [row("30462", "RONDO 360 HERBICIDE", "ACME CROP SCIENCE PTY LTD")],
    { "30462": [{ name: "GLYPHOSATE", amount: 360 }] },
    ["AU:apvma:30462"],
  );
  const r = only(result, "Rondo 360");
  assertEquals(r.match_class, "deterministic_match");
  assertEquals(r.identity_already_in_master, true);
  assertEquals(result.counts.identity_already_in_master, 1);
  assertEquals(result.counts.distinct_new_identities, 0);
});

Deno.test("6b: AWRI-cancelled names are structurally excluded from classification", () => {
  const result = classify(
    [entry("Oldchem", ["carbaryl"])],
    ["Oldchem"],
    [row("20001", "OLDCHEM INSECTICIDE", "ACME CROP SCIENCE PTY LTD")],
    {},
    [],
    ["Oldchem"],
  );
  assertEquals(result.resolutions.length, 0);
  assertEquals(result.counts.excluded_cancelled_listed, 1);
});

Deno.test("6c: every input is classified exactly once and counts add up", () => {
  const result = classify(
    [
      entry("Custodia", ["tebuconazole + azoxystrobin"]),
      entry("A-Star 250 SC", ["azoxystrobin"]),
      entry("Airone WG", ["copper as oxychloride + hydroxide"]),
    ],
    ["Custodia", "A-Star 250 SC", "Airone WG"],
    [
      row("91636", "CUSTODIA FORTE FUNGICIDE", "ADAMA AUSTRALIA PTY LIMITED"),
      row("85084", "Sinon A-star 250 SC Fungicide", "SINON AUSTRALIA PTY LIMITED"),
      row("81027", "RELYON AIRONE WG FUNGICIDE", "GOWAN CROP PROTECTION AUSTRALIA PTY LTD"),
    ],
    { "85084": AZOXY },
  );
  const c = result.counts;
  assertEquals(c.input_unresolved, 3);
  assertEquals(
    c.deterministic_match + c.probable_manual_review + c.ambiguous + c.no_apvma_match,
    result.resolutions.length,
  );
  assertEquals(result.resolutions.length, 3);
  assertEquals(result.invariants.apvma_remains_authoritative, "PASS");
  assertEquals(result.invariants.dry_run_no_writes, "PASS");
  assertEquals(c.database_changes, 0);
  assertEquals(c.production_writes, 0);
});

Deno.test("6d: duplicate identities across names are rolled up for review", () => {
  const rows = [row("77001", "ECOSULF 800 WG FUNGICIDE", "ACME CROP SCIENCE PTY LTD")];
  const actives = { "77001": [{ name: "SULPHUR", amount: 800 }] };
  const result = classify(
    [entry("Ecosulf 800 WG", ["sulfur"]), entry("Ecosulf 800WG", ["sulfur"])],
    ["Ecosulf 800 WG", "Ecosulf 800WG"],
    rows,
    actives,
  );
  assertEquals(result.counts.distinct_new_identities, 1);
  assertEquals(result.duplicates.length, 1);
  assertEquals(result.duplicates[0].awri_product_names.length, 2);
});

Deno.test("6e: classification is pure and deterministic — identical inputs, identical output", () => {
  const run = (): string =>
    JSON.stringify(classify(
      [entry("A-Star 250 SC", ["azoxystrobin"]), entry("Custodia", ["tebuconazole + azoxystrobin"])],
      ["A-Star 250 SC", "Custodia"],
      [
        row("85084", "Sinon A-star 250 SC Fungicide", "SINON AUSTRALIA PTY LIMITED"),
        row("91636", "CUSTODIA FORTE FUNGICIDE", "ADAMA AUSTRALIA PTY LIMITED"),
      ],
      { "85084": AZOXY },
    ));
  assertEquals(run(), run());
});

Deno.test("6f: collectCandidatePcodes covers every tier's rows for the runner to corroborate", () => {
  const index = buildRegisterIndex([
    row("85084", "Sinon A-star 250 SC Fungicide", "SINON AUSTRALIA PTY LIMITED"),
    row("81027", "RELYON AIRONE WG FUNGICIDE", "GOWAN CROP PROTECTION AUSTRALIA PTY LTD"),
    row("41000", "BRAVO", "SYNGENTA AUSTRALIA PTY LTD"),
    row("99999", "UNRELATED PRODUCT", "SOMEONE ELSE PTY LTD"),
  ]);
  const pcodes = collectCandidatePcodes(["A-Star 250 SC", "Airone WG", "Bravo 500 SC"], index);
  assertEquals(pcodes, ["41000", "81027", "85084"]);
});

Deno.test("6g: report contains every required Stage 5E field", () => {
  const result = classify(
    [entry("A-Star 250 SC", ["azoxystrobin"])],
    ["A-Star 250 SC"],
    [row("85084", "Sinon A-star 250 SC Fungicide", "SINON AUSTRALIA PTY LIMITED")],
    { "85084": AZOXY },
  );
  const report = formatMatchReport(result, "51+ passed");
  for (
    const line of [
      "Input unresolved:",
      "Newly deterministic:",
      "Probable/manual review:",
      "Ambiguous:",
      "No match:",
      "Database changes: NONE",
      "Production writes: NONE",
    ]
  ) {
    assert(report.includes(line), `report missing "${line}"`);
  }
});
