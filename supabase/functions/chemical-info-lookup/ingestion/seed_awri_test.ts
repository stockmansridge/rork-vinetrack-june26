// Stage 5 tests — AWRI Dog Book seed dry-run (61-66).
//
// The seed process must uphold every standing invariant: candidates only,
// facts never invented, APVMA the sole registration authority, no fuzzy
// resolution, lapsed/cancelled products fail safely and stay visible,
// dedupe by AU:apvma:<number> only, idempotent reruns, zero writes in a
// dry run.
//
//   cd supabase/functions/chemical-info-lookup && deno test ingestion/

import {
  assert,
  assertEquals,
  assertStringIncludes,
} from "jsr:@std/assert@1";
import {
  buildComparisonSql,
  formatSeedReport,
  runSeedDryRun,
  type AwriSeedManifest,
  type RegisterProductRow,
  type SeedResolution,
} from "./seed_awri.ts";
import { normaliseProductName } from "./apvma.ts";
import manifestJson from "./seeds/awri_dogbook_2026_27.json" with { type: "json" };

const realManifest = manifestJson as unknown as AwriSeedManifest;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

function row(
  pcode: string,
  fpname: string,
  regcode: string | null = "R",
  expdate: string | null = "30/06/2029 0:00",
): RegisterProductRow {
  return {
    pcode,
    fpname,
    sname: "FIXTURE REGISTRANT PTY LTD",
    hlevel1: "FUNGICIDE",
    fdesc: "SUSPENSION CONCENTRATE",
    regcode,
    expdate,
  };
}

function fixtureManifest(
  names: Array<Partial<AwriSeedManifest["entries"][number]> & { awri_product_name: string }>,
  cancelled: AwriSeedManifest["cancelled_products"] = [],
): AwriSeedManifest {
  return {
    manifest_version: 1,
    source: {
      id: "awri_dogbook_2026_27",
      edition: "2026/27",
      compiled: "2026-06-01",
      title: "Agrochemicals registered for use in Australian viticulture 2026/27",
    },
    table2_rows_transcribed: names.length,
    entries: names.map((n) => ({
      awri_product_name: n.awri_product_name,
      apvma_registration_number: null,
      active_constituents: n.active_constituents ?? ["fixture active"],
      activity_groups: n.activity_groups ?? [],
      re_entry_codes: n.re_entry_codes ?? [],
      sections: n.sections ?? ["fungicide"],
      expansion: n.expansion ?? "plain",
      listed_as: n.listed_as ?? [n.awri_product_name],
    })),
    cancelled_products: cancelled,
  };
}

function byName(resolutions: SeedResolution[], name: string): SeedResolution {
  const hit = resolutions.find((r) => r.awri_product_name === name);
  if (!hit) throw new Error(`no resolution for ${name}`);
  return hit;
}

// ---------------------------------------------------------------------------
// 61 — the versioned manifest itself
// ---------------------------------------------------------------------------

Deno.test("61: AWRI 2026/27 manifest is deterministic reference data — no registration facts, no duplicates, no invented numbers", () => {
  assertEquals(realManifest.manifest_version, 1, "versioned manifest");
  assertEquals(realManifest.source.id, "awri_dogbook_2026_27", "source id");
  assertEquals(realManifest.source.edition, "2026/27", "edition");
  assertEquals(realManifest.source.compiled, "2026-06-01", "compiled date");
  assert(realManifest.entries.length >= 600, `expected 600+ unique products, got ${realManifest.entries.length}`);
  assertEquals(realManifest.cancelled_products.length, 5, "booklet p.29 cancelled list");

  const seen = new Set<string>();
  const allowedKeys = new Set([
    "awri_product_name",
    "apvma_registration_number",
    "active_constituents",
    "activity_groups",
    "re_entry_codes",
    "sections",
    "expansion",
    "listed_as",
  ]);
  for (const entry of realManifest.entries) {
    const key = normaliseProductName(entry.awri_product_name);
    assert(key.length > 0, `empty product name: ${JSON.stringify(entry)}`);
    assert(!seen.has(key), `duplicate manifest name: ${entry.awri_product_name}`);
    seen.add(key);
    // The booklet publishes NO registration numbers — the manifest can never
    // invent one (identity comes from the register alone).
    assertEquals(entry.apvma_registration_number, null, `${entry.awri_product_name}: number must be null`);
    assert(entry.active_constituents.length > 0, `${entry.awri_product_name}: active missing`);
    assert(entry.sections.length > 0, `${entry.awri_product_name}: section missing`);
    for (const k of Object.keys(entry)) {
      assert(allowedKeys.has(k), `${entry.awri_product_name}: unexpected manifest field ${k}`);
    }
  }
  // Structural: no manifest FIELD may carry WHP/re-entry-hours/rate/label
  // facts — AWRI can never supply catalogue facts. (Product NAMES may contain
  // words like "Concentrate"; only field names matter here.)
  const fieldNames = new Set<string>();
  for (const entry of realManifest.entries) Object.keys(entry).forEach((k) => fieldNames.add(k));
  for (const c of realManifest.cancelled_products) Object.keys(c).forEach((k) => fieldNames.add(k));
  for (const name of fieldNames) {
    assert(
      !/withholding|re_entry_period_hours|rate|label|registered_uses/.test(name),
      `manifest field '${name}' must not carry catalogue facts`,
    );
  }
});

// ---------------------------------------------------------------------------
// 62 — deterministic resolution discipline (never fuzzy)
// ---------------------------------------------------------------------------

Deno.test("62: seed resolution reuses the adapter discipline — exact wins, suffix unique resolves, ties and unknowns fail closed", () => {
  const register = [
    row("66541", "CUSTODIA"),
    row("91636", "CUSTODIA FORTE"),
    row("52427", "AMISTAR 250 SC FUNGICIDE"),
    row("60011", "SWITCH FUNGICIDE"),
    row("60012", "SWITCH 62.5 WG FUNGICIDE"),
  ];
  const manifest = fixtureManifest([
    { awri_product_name: "Custodia" },
    { awri_product_name: "Custodia Forte" },
    { awri_product_name: "Amistar 250 SC" },
    { awri_product_name: "Switch" },
    { awri_product_name: "Bacchus WG" },
  ]);
  const result = runSeedDryRun(manifest, register);

  const custodia = byName(result.resolutions, "Custodia");
  assertEquals(custodia.kind, "resolved_current");
  assertEquals(custodia.registration_identity_key, "AU:apvma:66541", "Custodia never reaches Forte");
  assertEquals(custodia.match_mode, "exact_name");

  const forte = byName(result.resolutions, "Custodia Forte");
  assertEquals(forte.registration_identity_key, "AU:apvma:91636");

  const amistar = byName(result.resolutions, "Amistar 250 SC");
  assertEquals(amistar.kind, "resolved_current");
  assertEquals(amistar.registration_identity_key, "AU:apvma:52427");
  assertEquals(amistar.match_mode, "formulation_suffix", "category suffix rule");

  assertEquals(byName(result.resolutions, "Switch").kind, "unresolved_ambiguous", "two suffix matches fail closed");
  assertEquals(byName(result.resolutions, "Bacchus WG").kind, "unresolved_no_match", "absence stays visible, never guessed");

  assertEquals(result.counts.candidate_eligible_identities, 3);
  assertEquals(result.counts.unresolved_total, 2);
  assertEquals(result.invariants.apvma_remains_authoritative, "PASS");
});

// ---------------------------------------------------------------------------
// 63 — lapsed/cancelled fail-safe (visible, never replaced, never seeded)
// ---------------------------------------------------------------------------

Deno.test("63: not-current registrations and AWRI-cancelled names classify as conflicts — never candidate-eligible, never silently swapped", () => {
  const register = [
    row("40001", "OLDPROD FUNGICIDE", "S"), // suspended — not current
    row("40002", "JASPER 520 EC HERBICIDE", "R"), // current, but AWRI-cancelled
    row("40003", "SAFEPROD FUNGICIDE", "R"),
  ];
  const manifest = fixtureManifest(
    [
      { awri_product_name: "Oldprod" },
      { awri_product_name: "Jasper 520 EC" },
      { awri_product_name: "Safeprod" },
    ],
    [
      {
        awri_product_name: "Jasper 520 EC",
        active_constituent: "haloxyfop-R methyl ester",
        status: "Use quickly",
        last_use_date: "2026-08-25",
      },
      {
        awri_product_name: "Fyfanon 440 EW",
        active_constituent: "malathion",
        status: "DO NOT USE",
        last_use_date: "2026-05-01",
      },
    ],
  );
  const result = runSeedDryRun(manifest, register);

  const old = byName(result.resolutions, "Oldprod");
  assertEquals(old.kind, "resolved_not_current", "suspended stays visible as conflict");
  assertStringIncludes(old.register_status ?? "", "S");

  const jasper = byName(result.resolutions, "Jasper 520 EC");
  assertEquals(jasper.awri_cancelled_listed, true);
  assertEquals(jasper.kind, "resolved_current", "register state reported truthfully");

  // Neither may be seeded; both identities live in the conflict bucket.
  assertEquals(result.candidate_identities, ["AU:apvma:40003"], "only the clean product is candidate-eligible");
  assert(result.conflict_identities.includes("AU:apvma:40001"));
  assert(result.conflict_identities.includes("AU:apvma:40002"));

  // Cancelled list stays visible even when it never resolves (Fyfanon).
  assertEquals(result.cancelled_list_resolutions.length, 2);
  const fyfanon = result.cancelled_list_resolutions.find((c) => c.awri_product_name === "Fyfanon 440 EW");
  assertEquals(fyfanon?.kind, "unresolved_no_match");
  // Conflict bucket: Oldprod + Jasper (entry) + Fyfanon (cancelled-only row).
  assertEquals(result.counts.conflicts_cancelled_lapsed, 3);
});

// ---------------------------------------------------------------------------
// 64 — dedupe by AU:apvma:<number> ONLY
// ---------------------------------------------------------------------------

Deno.test("64: two AWRI names resolving to one registration dedupe by identity key — one candidate, duplicate counted and listed", () => {
  const register = [row("50001", "TWINNAME 500 SC FUNGICIDE")];
  const manifest = fixtureManifest([
    { awri_product_name: "Twinname 500 SC" },
    { awri_product_name: "Twinname" },
  ]);
  const result = runSeedDryRun(manifest, register);

  assertEquals(result.counts.names_resolved_total, 2);
  assertEquals(result.candidate_identities, ["AU:apvma:50001"]);
  assertEquals(result.counts.duplicate_identities_removed, 1);
  assertEquals(result.duplicates.length, 1);
  assertEquals(result.duplicates[0].registration_identity_key, "AU:apvma:50001");
  assertEquals(result.duplicates[0].awri_product_names.length, 2);
});

// ---------------------------------------------------------------------------
// 65 — idempotence, zero writes, report + SQL are read-only
// ---------------------------------------------------------------------------

Deno.test("65: dry run is pure and idempotent — identical output on rerun, zero database operations, read-only SQL", () => {
  const register = [
    row("66541", "CUSTODIA"),
    row("70001", "SOMEPROD FUNGICIDE", "S"),
  ];
  const manifest = fixtureManifest([
    { awri_product_name: "Custodia" },
    { awri_product_name: "Someprod" },
    { awri_product_name: "Missing Product" },
  ]);
  const first = runSeedDryRun(manifest, register);
  const second = runSeedDryRun(manifest, register);
  assertEquals(JSON.stringify(first), JSON.stringify(second), "rerunning the same edition changes nothing");

  assertEquals(first.counts.database_changes, 0);
  assertEquals(first.counts.production_writes, 0);
  assertEquals(first.counts.already_in_master, null, "pending manual SQL, never guessed");
  assertEquals(first.counts.would_create_candidates, null, "pending manual SQL, never guessed");
  assertEquals(first.invariants.dry_run_no_writes, "PASS");

  const report = formatSeedReport(first, "fixture");
  for (const line of [
    "AWRI edition/source:",
    "Unique products found:",
    "With APVMA registration:",
    "Already in Master: PENDING MANUAL SQL",
    "Would create Candidates: PENDING MANUAL SQL",
    "Unresolved:",
    "Conflicts / cancelled / lapsed:",
    "Duplicate identities removed:",
    "APVMA remains authoritative: PASS",
    "Dry run (no writes): PASS",
    "Database changes: NONE",
    "Production writes: NONE",
  ]) {
    assertStringIncludes(report, line);
  }

  const sql = buildComparisonSql(first);
  assertStringIncludes(sql, "READ-ONLY");
  assertStringIncludes(sql, "left join public.master_chemicals");
  assertStringIncludes(sql, "'AU:apvma:' || n");
  assertStringIncludes(sql, "66541");
  assert(
    !/\b(insert|update|delete|drop|alter|truncate|grant)\b/i.test(sql),
    "comparison SQL must contain zero write statements",
  );
});

// ---------------------------------------------------------------------------
// 66 — fail-closed posture against an empty register
// ---------------------------------------------------------------------------

Deno.test("66: full 2026/27 manifest against an unavailable/empty register yields zero candidates — absence is never 'not registered'", () => {
  const result = runSeedDryRun(realManifest, []);
  assertEquals(result.candidate_identities.length, 0);
  assertEquals(result.counts.names_resolved_total, 0);
  assertEquals(result.counts.unresolved_total, realManifest.entries.length);
  assertEquals(result.invariants.apvma_remains_authoritative, "PASS");
  assertEquals(result.counts.production_writes, 0);
});
