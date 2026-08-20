// Stage 5B tests — apply the reviewed AWRI seed (67-74).
//
// The apply mechanism must uphold every standing invariant AND the Stage 5B
// requirements: candidates only, insert-only (existing rows untouched in any
// review state — 91636 skipped unchanged), exact reviewed identities only,
// live register re-verification before any write, AWRI carried as
// viticulture_reference evidence metadata only, unresolved/conflict rows
// excluded, stop/resume-safe state, rerun idempotence, and one failed
// product never aborting the batch.
//
//   cd supabase/functions/chemical-info-lookup && deno test ingestion/

import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import type {
  CandidateRowPayload,
  DiscoveryResult,
  MasterRow,
  ResolvedRegistration,
} from "./contract.ts";
import { runSeedApply, SEED_SOURCES, type SeedOps } from "./seed_apply.ts";
import {
  type ApplyArtifact,
  type ApplyItem,
  buildApplyBatch,
  classifyApplyResponse,
  initialApplyState,
  planPending,
  preMarkVerified,
  processPending,
  recordOutcome,
  summariseApply,
  TERMINAL_APPLY_OUTCOMES,
} from "./seed_awri_apply.ts";
import artifactJson from "./seeds/awri_dogbook_2026_27.dryrun.json" with { type: "json" };

const realArtifact = artifactJson as unknown as ApplyArtifact;
const NOW_ISO = "2026-08-20T06:00:00.000Z";
const TABLE_VERSION = 3;
const AWRI = SEED_SOURCES.awri_dogbook_2026_27;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

function masterRow(overrides: Partial<MasterRow> = {}): MasterRow {
  return {
    id: "00000000-0000-0000-0000-000000000001",
    registration_country: "AU",
    registration_scheme: "apvma",
    registration_number: "91636",
    registration_identity_key: "AU:apvma:91636",
    registrant: "ADAMA AUSTRALIA PTY LIMITED",
    registered_product_name: "CUSTODIA FORTE FUNGICIDE",
    common_names: ["custodia forte"],
    product_category: "fungicide",
    form_type: "liquid",
    active_ingredients: [],
    activity_groups: [],
    activity_group_scheme: null,
    registered_uses: [],
    label_rate_bases: [],
    label_reference: null,
    label_version: null,
    verification_status: "partially_verified",
    verification_sources: [],
    verification_conflicts: [],
    verification_unresolved_fields: [],
    verified_at: null,
    source_kind: "official_register",
    source_reference: null,
    retrieved_at: NOW_ISO,
    review_status: "candidate",
    catalogue_version: 1,
    activity_group_table_version: TABLE_VERSION,
    intelligence_schema_version: 1,
    ...overrides,
  };
}

function fixtureRegistration(
  pcode: string,
  fpname: string,
  registerStatus = "R, expires 30/06/2029 0:00",
): ResolvedRegistration {
  return {
    country_code: "AU",
    scheme: "apvma",
    registration_number: pcode,
    registration_identity_key: `AU:apvma:${pcode}`,
    registered_product_name: fpname,
    registrant: "FIXTURE REGISTRANT PTY LTD",
    product_category: "fungicide",
    form_type: "liquid",
    label_version: `APVMA label approval ${pcode}/1 (2025-01-01)`,
    register_status: registerStatus,
    active_ingredients: [
      {
        name: "Fixture Active",
        concentration: 500,
        concentration_unit: "g/L",
        activity_group: null,
        group_source: null,
        identity_source: "official_register",
      },
    ],
    unresolved_fields: ["label_reference", "registered_uses"],
    sources: [
      {
        kind: "official_register",
        name: `APVMA PubCRIS register extract — product ${pcode} (${registerStatus})`,
        reference: `https://data.gov.au/data/api/3/action/datastore_search?pcode=${pcode}`,
        retrieved_at: NOW_ISO,
      },
    ],
    match_mode: "register_number_verified",
    label_evidence: null,
  };
}

function resolvedDiscovery(reg: ResolvedRegistration): DiscoveryResult {
  return { outcome: "resolved", adapter: "apvma", registration: reg, cache: "miss" };
}

class FakeSeedOps implements SeedOps {
  selectCalls = 0;
  insertCalls: CandidateRowPayload[] = [];
  constructor(
    private selectResults: Array<MasterRow | null>,
    private insertResult: MasterRow | null | ((p: CandidateRowPayload) => MasterRow),
  ) {}
  // deno-lint-ignore require-await
  async selectByIdentityKey(_key: string): Promise<MasterRow | null> {
    this.selectCalls += 1;
    return this.selectResults.length ? this.selectResults.shift() ?? null : null;
  }
  // deno-lint-ignore require-await
  async insertCandidate(payload: CandidateRowPayload): Promise<MasterRow | null> {
    this.insertCalls.push(payload);
    return typeof this.insertResult === "function"
      ? this.insertResult(payload)
      : this.insertResult;
  }
}

function trackedDiscover(result: DiscoveryResult): {
  calls: number;
  fn: (q: string, h: string) => Promise<DiscoveryResult>;
} {
  const tracker = {
    calls: 0,
    fn: (_q: string, _h: string): Promise<DiscoveryResult> => {
      tracker.calls += 1;
      return Promise.resolve(result);
    },
  };
  return tracker;
}

const input = (number: string, name: string) => ({
  registration_number: number,
  product_name: name,
  seed_source_id: "awri_dogbook_2026_27",
});

// ---------------------------------------------------------------------------
// 67 — existing rows are skipped unchanged, in every review state
// ---------------------------------------------------------------------------

Deno.test("67: an existing row in ANY review state returns already_exists with ZERO writes — 91636 is skipped unchanged and the register is never consulted", async () => {
  for (const status of ["candidate", "approved", "retired"]) {
    const ops = new FakeSeedOps([masterRow({ review_status: status })], null);
    const discover = trackedDiscover(resolvedDiscovery(fixtureRegistration("91636", "CUSTODIA FORTE FUNGICIDE")));
    const outcome = await runSeedApply(
      input("91636", "Custodia Forte"),
      ops,
      discover.fn,
      NOW_ISO,
      TABLE_VERSION,
    );
    assertEquals(outcome.outcome, "already_exists");
    assertEquals(outcome.review_status, status);
    assertEquals(outcome.registration_identity_key, "AU:apvma:91636");
    assertEquals(outcome.writes, 0);
    assertEquals(ops.insertCalls.length, 0, "insert must never run for an existing row");
    assertEquals(discover.calls, 0, "discovery must never run for an existing row");
  }
  // Structural: the ops surface seeding receives has no update capability.
  const seedOps: SeedOps = new FakeSeedOps([], null);
  assert(!("updateCandidate" in seedOps) || typeof (seedOps as Record<string, unknown>).updateCandidate !== "function");
});

// ---------------------------------------------------------------------------
// 68 — the created path: candidate-only payload with AWRI evidence metadata
// ---------------------------------------------------------------------------

Deno.test("68: creating a candidate pins review_status=candidate and source_kind=official_register, and carries EXACTLY ONE viticulture_reference evidence entry — facts stay register-sourced", async () => {
  const reg = fixtureRegistration("58340", "FIXTURE SHIELD 250 SC FUNGICIDE");
  const ops = new FakeSeedOps([null], (p) =>
    masterRow({
      registration_number: p.registration_number,
      registration_identity_key: `AU:apvma:${p.registration_number}`,
      registered_product_name: p.registered_product_name,
      review_status: p.review_status,
    }));
  const discover = trackedDiscover(resolvedDiscovery(reg));

  const outcome = await runSeedApply(
    input("58340", "Fixture Shield"),
    ops,
    discover.fn,
    NOW_ISO,
    TABLE_VERSION,
  );

  assertEquals(outcome.outcome, "created");
  assertEquals(outcome.registration_identity_key, "AU:apvma:58340");
  assertEquals(outcome.writes, 1);
  assertEquals(ops.insertCalls.length, 1);

  const payload = ops.insertCalls[0];
  assertEquals(payload.review_status, "candidate");
  assertEquals(payload.source_kind, "official_register");
  assertEquals(payload.registration_country, "AU");
  assertEquals(payload.registration_scheme, "apvma");
  assertEquals(payload.registered_product_name, "FIXTURE SHIELD 250 SC FUNGICIDE");
  assert(payload.common_names.includes("fixture shield"), "AWRI name becomes a search alias");

  const vitiSources = payload.verification_sources.filter((s) => s.kind === "viticulture_reference");
  assertEquals(vitiSources.length, 1, "exactly one AWRI evidence entry");
  assertEquals(vitiSources[0].reference, AWRI.reference);
  assert(vitiSources[0].name.includes("2026/27"));
  assert(
    payload.verification_sources.some((s) => s.kind === "official_register"),
    "register evidence must be present",
  );
  // AWRI contributes evidence metadata ONLY — chemistry stays register-sourced.
  assert(
    payload.active_ingredients.every((a) => a.identity_source === "official_register"),
  );
});

// ---------------------------------------------------------------------------
// 69 — fail-safe classification: no write on any non-clean path
// ---------------------------------------------------------------------------

Deno.test("69: unresolved/ambiguous re-verification, register drift to not-current, source outage and identity mismatch all end with ZERO writes", async () => {
  const cases: Array<{
    discovery: DiscoveryResult;
    expect: string;
    retryable?: boolean;
  }> = [
    { discovery: { outcome: "unresolved", adapter: "apvma", cache: "miss" }, expect: "unresolved" },
    { discovery: { outcome: "ambiguous", adapter: "apvma", cache: "miss" }, expect: "unresolved" },
    {
      discovery: {
        outcome: "source_unavailable",
        adapter: "apvma",
        error_category: "timeout",
        cache: "miss",
      },
      expect: "failed",
      retryable: true,
    },
    {
      discovery: resolvedDiscovery(
        fixtureRegistration("69584", "JASPER 520 EC HERBICIDE", "A, expires 30/06/2020 0:00"),
      ),
      expect: "conflict",
    },
    {
      // Register resolved a DIFFERENT identity than the reviewed one.
      discovery: resolvedDiscovery(fixtureRegistration("99999", "SOMETHING ELSE FUNGICIDE")),
      expect: "failed",
      retryable: false,
    },
  ];

  for (const c of cases) {
    const ops = new FakeSeedOps([null], null);
    const discover = trackedDiscover(c.discovery);
    const outcome = await runSeedApply(
      input("69584", "Jasper 520 EC"),
      ops,
      discover.fn,
      NOW_ISO,
      TABLE_VERSION,
    );
    assertEquals(outcome.outcome, c.expect, JSON.stringify(c.discovery.outcome));
    assertEquals(outcome.writes, 0);
    assertEquals(ops.insertCalls.length, 0, "no insert on any non-clean path");
    if (c.retryable !== undefined) assertEquals(outcome.retryable, c.retryable);
  }
});

// ---------------------------------------------------------------------------
// 70 — input validation refuses before any I/O
// ---------------------------------------------------------------------------

Deno.test("70: unknown seed source, malformed number and missing name are refused BEFORE any catalogue or register I/O", async () => {
  const bad = [
    { registration_number: "58340", product_name: "Fixture", seed_source_id: "not_a_source" },
    { registration_number: "12ab", product_name: "Fixture", seed_source_id: "awri_dogbook_2026_27" },
    { registration_number: "12", product_name: "Fixture", seed_source_id: "awri_dogbook_2026_27" },
    { registration_number: "58340", product_name: "  ", seed_source_id: "awri_dogbook_2026_27" },
  ];
  for (const b of bad) {
    const ops = new FakeSeedOps([null], null);
    const discover = trackedDiscover({ outcome: "unresolved", adapter: "apvma", cache: "miss" });
    const outcome = await runSeedApply(b, ops, discover.fn, NOW_ISO, TABLE_VERSION);
    assertEquals(outcome.outcome, "failed");
    assertEquals(outcome.retryable, false);
    assertEquals(outcome.writes, 0);
    assertEquals(ops.selectCalls, 0, "no catalogue I/O on validation failure");
    assertEquals(discover.calls, 0, "no register I/O on validation failure");
  }
});

// ---------------------------------------------------------------------------
// 71 — concurrent-creation race stays write-safe
// ---------------------------------------------------------------------------

Deno.test("71: a row appearing mid-request (duplicate-safe insert returns null) classifies already_exists — never a second row, never an update", async () => {
  const raced = masterRow({ review_status: "candidate" });
  const ops = new FakeSeedOps([null, raced], null);
  const discover = trackedDiscover(
    resolvedDiscovery(fixtureRegistration("91636", "CUSTODIA FORTE FUNGICIDE")),
  );
  const outcome = await runSeedApply(
    input("91636", "Custodia Forte"),
    ops,
    discover.fn,
    NOW_ISO,
    TABLE_VERSION,
  );
  assertEquals(outcome.outcome, "already_exists");
  assertEquals(outcome.writes, 0);
  assertEquals(ops.insertCalls.length, 1, "insert was attempted once, skipped by the uniqueness guard");
});

// ---------------------------------------------------------------------------
// 72 — the batch is EXACTLY the reviewed identities
// ---------------------------------------------------------------------------

Deno.test("72: buildApplyBatch on the reviewed artifact yields exactly 197 identities — 91636 pre-verified and never sent, 196 sendable, conflicts and unresolved structurally excluded", () => {
  const items = buildApplyBatch(realArtifact);
  assertEquals(items.length, 197);

  const identities = new Set(items.map((i) => i.registration_identity_key));
  assertEquals(identities.size, 197, "identities unique");
  assertEquals(
    new Set(realArtifact.candidate_identities),
    identities,
    "batch == reviewed candidate_identities, nothing more, nothing less",
  );

  for (const conflict of realArtifact.conflict_identities) {
    assert(!identities.has(conflict), `conflict ${conflict} must not enter the batch`);
  }
  assert(!identities.has("AU:apvma:69584"), "Jasper 520 EC excluded");
  assert(!identities.has("AU:apvma:51150"), "Fyfanon 440 EW excluded");

  const preVerified = items.filter((i) => i.pre_verified_review_status);
  assertEquals(preVerified.length, 1);
  assertEquals(preVerified[0].registration_identity_key, "AU:apvma:91636");
  assertEquals(preVerified[0].pre_verified_review_status, "candidate");

  const state = preMarkVerified(initialApplyState("awri_dogbook_2026_27", NOW_ISO), items, NOW_ISO);
  assertEquals(planPending(items, state).length, 196, "196 sendable identities");

  for (const item of items) {
    assert(/^\d{3,8}$/.test(item.registration_number));
    assertEquals(item.registration_identity_key, `AU:apvma:${item.registration_number}`);
    assert(item.awri_product_name.trim().length > 0);
  }

  // Tampered artifacts are refused outright.
  assertThrows(() =>
    buildApplyBatch({
      ...realArtifact,
      candidate_identities: [...realArtifact.candidate_identities, "AU:apvma:69584"],
    })
  );
  assertThrows(() =>
    buildApplyBatch({
      ...realArtifact,
      candidate_identities: [...realArtifact.candidate_identities, "AU:apvma:12345"],
    })
  );
});

// ---------------------------------------------------------------------------
// 73 — stop/resume and rerun idempotence
// ---------------------------------------------------------------------------

Deno.test("73: terminal outcomes are never re-sent, failed items retry, and a fully-terminal state makes a rerun send NOTHING", () => {
  const item = (n: string, pre: string | null = null): ApplyItem => ({
    registration_identity_key: `AU:apvma:${n}`,
    registration_number: n,
    awri_product_name: `Fixture ${n}`,
    registered_product_name: null,
    pre_verified_review_status: pre,
  });
  const items = [item("100", "candidate"), item("200"), item("300"), item("400")];

  let state = preMarkVerified(initialApplyState("awri_dogbook_2026_27", NOW_ISO), items, NOW_ISO);
  assertEquals(state.records["AU:apvma:100"].outcome, "already_exists");
  assertEquals(state.records["AU:apvma:100"].attempts, 0, "pre-mark is not an attempt");
  assertEquals(planPending(items, state).map((i) => i.registration_number), ["200", "300", "400"]);

  state = recordOutcome(state, "AU:apvma:200", "created", "", NOW_ISO);
  state = recordOutcome(state, "AU:apvma:300", "failed", "transport error", NOW_ISO);
  state = recordOutcome(state, "AU:apvma:400", "conflict", "no longer current", NOW_ISO);
  assertEquals(
    planPending(items, state).map((i) => i.registration_number),
    ["300"],
    "only the failed item retries",
  );

  state = recordOutcome(state, "AU:apvma:300", "unresolved", "did not verify", NOW_ISO);
  assertEquals(state.records["AU:apvma:300"].attempts, 2);
  assertEquals(planPending(items, state).length, 0, "rerun sends nothing — idempotent");

  for (const t of ["created", "already_exists", "unresolved", "conflict"]) {
    assert(TERMINAL_APPLY_OUTCOMES.has(t));
  }
  assert(!TERMINAL_APPLY_OUTCOMES.has("failed"));

  const summary = summariseApply(items, state);
  assertEquals(summary, {
    total: 4,
    pre_verified: 1,
    created: 1,
    already_exists: 1,
    unresolved: 1,
    conflict: 1,
    failed: 0,
    pending: 0,
  });
});

// ---------------------------------------------------------------------------
// 74 — one failed product never aborts the batch; state persists per item
// ---------------------------------------------------------------------------

Deno.test("74: a throwing send is contained — the batch continues, the failure is recorded as retryable state, and state persists after EVERY item", async () => {
  const item = (n: string): ApplyItem => ({
    registration_identity_key: `AU:apvma:${n}`,
    registration_number: n,
    awri_product_name: `Fixture ${n}`,
    registered_product_name: null,
    pre_verified_review_status: null,
  });
  const pending = [item("111"), item("222"), item("333")];

  let persistCount = 0;
  const persisted: string[] = [];
  const state = await processPending(
    pending,
    (i) => {
      if (i.registration_number === "222") throw new Error("socket hang up");
      return Promise.resolve({ outcome: "created", detail: "" });
    },
    initialApplyState("awri_dogbook_2026_27", NOW_ISO),
    () => NOW_ISO,
    (s) => {
      persistCount += 1;
      persisted.push(Object.keys(s.records).sort().join(","));
    },
  );

  assertEquals(state.records["AU:apvma:111"].outcome, "created");
  assertEquals(state.records["AU:apvma:222"].outcome, "failed");
  assert(state.records["AU:apvma:222"].detail.includes("socket hang up"));
  assertEquals(state.records["AU:apvma:333"].outcome, "created", "batch continued past the failure");
  assertEquals(persistCount, 3, "state persisted after every item");
  assertEquals(persisted[0], "AU:apvma:111", "first persist happened before later sends");

  // HTTP classification: auth failures are terminal-for-this-run failures,
  // server outcomes pass through, anything unknown fails safe.
  assertEquals(classifyApplyResponse(403, { error: "Not authorised" }).outcome, "failed");
  assert(classifyApplyResponse(403, {}).detail.includes("admin JWT"));
  assertEquals(
    classifyApplyResponse(200, { outcome: "created", detail: "x" }),
    { outcome: "created", detail: "x" },
  );
  assertEquals(classifyApplyResponse(200, { outcome: "weird" }).outcome, "failed");
  assertEquals(classifyApplyResponse(502, null).outcome, "failed");
});
