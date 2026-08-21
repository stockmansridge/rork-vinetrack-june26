// Master review preview tests (Stage 2 R2-B) — the stored-preview trust
// boundary's edge half.
//
// Required scenario coverage:
//   P01 normal material-change preview (stored, admin-bound, exact patch,
//       CAS base revision, DB-owned expiry echoed)
//   P02 unchanged → no preview row
//   P03 resolver unavailable → no preview row
//   P04 identity mismatch → identity guard refused, no writable preview
//   P05 delisting → material to report, nothing writable, no preview row
//   P06 evidence refresh → evidence-only patch stored
//   P07 chemistry conflict → conflict-recording patch, chemistry untouched
//   P08 forbidden patch key rejected at store time (fail closed)
//   P09 preview never mutates the master row; store failure contained
//   P10 resolver patch contract validation matrix (sql/203 mirror)
//   P11 candidate gate preserved after the builder refactor
//   P12 every reviewed-builder output satisfies the resolver contract

import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { MasterRow, ResolvedRegistration } from "./contract.ts";
import {
  buildCandidateRefreshPatch,
  buildRefreshPatch,
  type RefreshResult,
} from "./refresh.ts";
import {
  type PreviewInsertPayload,
  type PreviewStore,
  RESOLVER_PATCH_CONTRACT_KEYS,
  type ReviewPreviewDeps,
  runMasterReviewPreview,
  type StoredPreview,
  validateResolverPatch,
} from "./review_preview.ts";

const NOW_ISO = "2026-08-21T00:00:00.000Z";
const ADMIN_ID = "9a1e0000-1111-2222-3333-444455556666";

// ---------------------------------------------------------------------------
// Fixtures — synthetic identities only (never real catalogue rows)
// ---------------------------------------------------------------------------

function masterRow(overrides: Partial<MasterRow> = {}): MasterRow {
  return {
    id: "b2b90000-0000-4000-8000-000000000001",
    registration_country: "AU",
    registration_scheme: "apvma",
    registration_number: "T2B-90001",
    registration_identity_key: "AU:apvma:T2B-90001",
    registrant: "ORIGINAL HOLDINGS PTY LTD",
    registered_product_name: "R2B Preview Fixture Fungicide",
    common_names: [],
    product_category: "fungicide",
    form_type: "liquid",
    active_ingredients: [
      { name: "Tebuconazole", concentration: 430, concentration_unit: "g/L" },
    ],
    activity_groups: ["3"],
    activity_group_scheme: "frac",
    registered_uses: [],
    label_rate_bases: [],
    label_reference: null,
    label_version: "APVMA label approval 900011 (1/07/2025 0:00)",
    verification_status: "verified",
    verification_sources: [{
      kind: "official_register",
      name: "APVMA PubCRIS register extract",
      reference: "pubcris:T2B-90001",
      retrieved_at: NOW_ISO,
    }],
    verification_conflicts: [],
    verification_unresolved_fields: [],
    verified_at: NOW_ISO,
    source_kind: "official_register",
    source_reference: "pubcris:T2B-90001",
    retrieved_at: NOW_ISO,
    review_status: "approved",
    catalogue_version: 4,
    activity_group_table_version: 1,
    intelligence_schema_version: 1,
    ...overrides,
  };
}

function registration(
  overrides: Partial<ResolvedRegistration> = {},
): ResolvedRegistration {
  return {
    country_code: "AU",
    scheme: "apvma",
    registration_number: "T2B-90001",
    registration_identity_key: "AU:apvma:T2B-90001",
    registered_product_name: "R2B Preview Fixture Fungicide",
    registrant: "NEW HOLDER PTY LTD",
    product_category: "fungicide",
    form_type: "liquid",
    label_version: "APVMA label approval 900012 (1/08/2026 0:00)",
    register_status: "R, expires 30/06/2030",
    active_ingredients: [{
      name: "Tebuconazole",
      concentration: 430,
      concentration_unit: "g/L",
      identity_source: "official_register",
    }],
    unresolved_fields: [],
    sources: [{
      kind: "official_register",
      name: "APVMA PubCRIS register extract",
      reference: "pubcris:T2B-90001",
      retrieved_at: NOW_ISO,
    }],
    match_mode: "register_number_verified",
    ...overrides,
  };
}

function materialChangeResult(): RefreshResult {
  return {
    outcome: "material_change",
    changes: [
      {
        field: "registrant",
        current: "ORIGINAL HOLDINGS PTY LTD",
        authoritative: "NEW HOLDER PTY LTD",
      },
      {
        field: "label_version",
        current: "APVMA label approval 900011 (1/07/2025 0:00)",
        authoritative: "APVMA label approval 900012 (1/08/2026 0:00)",
      },
    ],
    registration: registration(),
  };
}

class MockStore implements PreviewStore {
  calls: string[] = [];
  inserts: PreviewInsertPayload[] = [];
  purges: string[] = [];
  failInsert = false;
  throwInsert = false;
  nextId = "5e0d0000-0000-4000-8000-0000000000aa";
  nextExpiresAt = "2026-08-21T00:30:00.000Z";

  insertPreview(payload: PreviewInsertPayload): Promise<StoredPreview | null> {
    this.calls.push("insert");
    if (this.throwInsert) return Promise.reject(new Error("storage exploded"));
    if (this.failInsert) return Promise.resolve(null);
    this.inserts.push(structuredClone(payload));
    return Promise.resolve({ id: this.nextId, expires_at: this.nextExpiresAt });
  }

  purgeExpired(nowIso: string): Promise<void> {
    this.calls.push("purge");
    this.purges.push(nowIso);
    return Promise.resolve();
  }
}

function deps(store: MockStore): ReviewPreviewDeps {
  return { store, nowIso: () => NOW_ISO };
}

// ---------------------------------------------------------------------------
// P01 — normal material-change preview
// ---------------------------------------------------------------------------

Deno.test("P01: material change stores a resolver-built, admin-bound preview", async () => {
  const store = new MockStore();
  const row = masterRow();
  const result = materialChangeResult();
  const res = await runMasterReviewPreview(row, result, ADMIN_ID, deps(store));

  assertEquals(res.preview_stored, true, "preview stored");
  assertEquals(res.preview_id, store.nextId, "opaque preview id returned");
  assertEquals(res.expires_at, store.nextExpiresAt, "DB-stamped expiry echoed");
  assertEquals(res.outcome, "material_change");
  assertEquals(res.identity_guard, { status: "passed" });
  assertEquals(res.no_preview_reason, undefined);
  assertEquals(res.error, undefined);

  // The display patch IS the reviewed builder's output, byte for byte.
  const expectedPatch = buildRefreshPatch(row, result, NOW_ISO)!;
  assertEquals(res.proposed_patch, expectedPatch, "display copy = reviewed builder output");

  // Stored payload: server-side, admin-bound, CAS revision — nothing else.
  assertEquals(store.inserts.length, 1, "exactly one insert");
  const stored = store.inserts[0];
  assertEquals(stored.master_chemical_id, row.id);
  assertEquals(stored.requested_by, ADMIN_ID, "preview bound to the requesting admin");
  assertEquals(stored.base_revision, 4, "CAS token = row catalogue_version");
  assertEquals(res.base_revision, 4);
  assertEquals(stored.outcome, "material_change");
  assertEquals(stored.proposed_patch, expectedPatch, "stored patch = reviewed builder output");
  assertEquals(stored.changes, result.changes, "diff snapshot stored for audit/portal");
  assert(!("expires_at" in stored), "expiry is the DB default (30 min), never edge-sent");
  assert(!("consumed_at" in stored), "consumption is apply-RPC-only");
  assert(!("id" in stored), "id is DB-generated");

  for (const key of Object.keys(stored.proposed_patch)) {
    assert(
      RESOLVER_PATCH_CONTRACT_KEYS.includes(key),
      `stored patch key ${key} is inside the resolver contract`,
    );
  }
  assertEquals(stored.proposed_patch.registrant, "NEW HOLDER PTY LTD");
  assertEquals(stored.proposed_patch.source_kind, "official_register");

  assertEquals(store.calls, ["purge", "insert"], "stale purge runs before the insert");
  assertEquals(store.purges, [NOW_ISO]);

  assertEquals(res.master, {
    master_chemical_id: row.id,
    catalogue_status: "approved",
    master_revision: 4,
    registration_identity_key: "AU:apvma:T2B-90001",
  });
  assertEquals(res.current.registrant, "ORIGINAL HOLDINGS PTY LTD", "current snapshot = row values");
  assertEquals(res.current.verification_status, "verified");
  assertEquals(
    Object.keys(res.current).sort(),
    [...RESOLVER_PATCH_CONTRACT_KEYS].sort(),
    "current snapshot covers exactly the resolver-contract surface",
  );
});

// ---------------------------------------------------------------------------
// P02 — unchanged → no preview
// ---------------------------------------------------------------------------

Deno.test("P02: no_material_change stores nothing", async () => {
  const store = new MockStore();
  const res = await runMasterReviewPreview(
    masterRow(),
    {
      outcome: "no_material_change",
      changes: [],
      registration: registration({ registrant: "ORIGINAL HOLDINGS PTY LTD" }),
    },
    ADMIN_ID,
    deps(store),
  );
  assertEquals(res.preview_stored, false);
  assertEquals(res.no_preview_reason, "no_material_change");
  assertEquals(res.preview_id, null);
  assertEquals(res.expires_at, null);
  assertEquals(res.proposed_patch, null);
  assertEquals(res.identity_guard, { status: "passed" });
  assertEquals(store.calls, [], "no store traffic at all");
});

// ---------------------------------------------------------------------------
// P03 — resolver unavailable → no preview
// ---------------------------------------------------------------------------

Deno.test("P03: source_unavailable stores nothing and reports the outage", async () => {
  const store = new MockStore();
  const res = await runMasterReviewPreview(
    masterRow(),
    {
      outcome: "source_unavailable",
      changes: [],
      error_category: "register_http_500",
    },
    ADMIN_ID,
    deps(store),
  );
  assertEquals(res.preview_stored, false);
  assertEquals(res.no_preview_reason, "source_unavailable");
  assertEquals(res.error_category, "register_http_500");
  assertEquals(res.identity_guard, { status: "not_evaluated" });
  assertEquals(res.preview_id, null);
  assertEquals(res.proposed_patch, null);
  assertEquals(store.calls, []);
});

// ---------------------------------------------------------------------------
// P04 — identity mismatch → guard refused, no writable preview
// ---------------------------------------------------------------------------

Deno.test("P04: registration-number mismatch refuses a writable preview", async () => {
  const store = new MockStore();
  const row = masterRow();
  const result: RefreshResult = {
    outcome: "material_change",
    changes: [{
      field: "registration_number",
      current: "T2B-90001",
      authoritative: "T2B-90002",
    }],
    registration: registration({
      registration_number: "T2B-90002",
      registration_identity_key: "AU:apvma:T2B-90002",
    }),
  };
  const res = await runMasterReviewPreview(row, result, ADMIN_ID, deps(store));
  assertEquals(res.identity_guard, {
    status: "refused",
    reason: "registration_number_mismatch",
    current_registration_number: "T2B-90001",
    register_registration_number: "T2B-90002",
  });
  assertEquals(res.preview_stored, false);
  assertEquals(res.no_preview_reason, "identity_mismatch");
  assertEquals(res.preview_id, null);
  assertEquals(
    res.proposed_patch,
    null,
    "a DIFFERENT product's register facts are never offered as a patch",
  );
  assertEquals(store.calls, [], "nothing stored — rekey is its own gated RPC");
  assertEquals(res.changes, result.changes, "mismatch stays visible for the rekey decision");
});

// ---------------------------------------------------------------------------
// P05 — delisting: material to report, nothing writable
// ---------------------------------------------------------------------------

Deno.test("P05: delisting is material to report with nothing writable", async () => {
  const store = new MockStore();
  const result: RefreshResult = {
    outcome: "material_change",
    changes: [{
      field: "registration_status",
      current: "listed in the master catalogue",
      authoritative: "no current register listing found for this identity",
    }],
  };
  const res = await runMasterReviewPreview(masterRow(), result, ADMIN_ID, deps(store));
  assertEquals(res.preview_stored, false);
  assertEquals(res.no_preview_reason, "no_writable_patch");
  assertEquals(res.identity_guard, { status: "not_evaluated" });
  assertEquals(res.changes.length, 1, "the delisting is still reported");
  assertEquals(store.calls, []);
});

// ---------------------------------------------------------------------------
// P06 — evidence refresh stores an evidence-only patch
// ---------------------------------------------------------------------------

Deno.test("P06: evidence_refreshed stores an evidence-only patch", async () => {
  const store = new MockStore();
  const row = masterRow({ retrieved_at: "2026-01-01T00:00:00.000Z" });
  const result: RefreshResult = {
    outcome: "evidence_refreshed",
    changes: [],
    registration: registration({ registrant: row.registrant }),
  };
  const res = await runMasterReviewPreview(row, result, ADMIN_ID, deps(store));
  assertEquals(res.preview_stored, true);
  const patch = store.inserts[0].proposed_patch;
  assertEquals(
    Object.keys(patch).sort(),
    ["retrieved_at", "source_kind", "source_reference", "verification_sources"],
    "evidence columns only — no canonical facts",
  );
  assertEquals(patch.source_kind, "official_register");
  assertEquals(patch.retrieved_at, NOW_ISO);
});

// ---------------------------------------------------------------------------
// P07 — conflict stores a conflict-recording patch
// ---------------------------------------------------------------------------

Deno.test("P07: chemistry conflict stores a conflict record, never new chemistry", async () => {
  const store = new MockStore();
  const row = masterRow();
  const result: RefreshResult = {
    outcome: "conflict",
    changes: [{
      field: "active_ingredients",
      current: "Tebuconazole 430 g/L",
      authoritative: "Tebuconazole 400 g/L",
    }],
    registration: registration(),
  };
  const res = await runMasterReviewPreview(row, result, ADMIN_ID, deps(store));
  assertEquals(res.preview_stored, true);
  const patch = store.inserts[0].proposed_patch;
  assertEquals(patch.verification_status, "conflict");
  assert(
    Array.isArray(patch.verification_conflicts) &&
      patch.verification_conflicts.length === 1,
    "the disagreement is recorded as a structured conflict",
  );
  assertEquals(patch.verification_conflicts[0].authoritative_source, "official_register");
  assert(
    !("active_ingredients" in patch),
    "stored chemistry is never replaced by a refresh (no arbitrary winner)",
  );
});

// ---------------------------------------------------------------------------
// P08 — forbidden patch key rejected at store time
// ---------------------------------------------------------------------------

Deno.test("P08: non-contract patch is rejected before storage (fail closed)", async () => {
  const store = new MockStore();
  const row = masterRow();
  const result = materialChangeResult();

  const forbidden = await runMasterReviewPreview(row, result, ADMIN_ID, {
    ...deps(store),
    buildPatchFn: () => ({
      registered_product_name: "X",
      review_status: "approved",
    }),
  });
  assertEquals(forbidden.error, "patch_contract_violation");
  assertEquals(forbidden.error_detail, "forbidden_key=review_status");
  assertEquals(forbidden.preview_stored, false);
  assertEquals(forbidden.preview_id, null);
  assertEquals(forbidden.proposed_patch, null, "a non-conforming patch is never exposed");
  assertEquals(store.calls, [], "nothing reached the store");

  const wrongType = await runMasterReviewPreview(row, result, ADMIN_ID, {
    ...deps(store),
    buildPatchFn: () => ({ registered_product_name: null }),
  });
  assertEquals(wrongType.error, "patch_contract_violation");
  assertEquals(wrongType.error_detail, "key registered_product_name must be a string");

  const empty = await runMasterReviewPreview(row, result, ADMIN_ID, {
    ...deps(store),
    buildPatchFn: () => ({}),
  });
  assertEquals(empty.error, "patch_contract_violation");
  assertEquals(empty.error_detail, "proposed_patch must be a non-empty object");
  assertEquals(store.calls, [], "still nothing stored");
});

// ---------------------------------------------------------------------------
// P09 — a preview (success OR failure) never mutates the master row
// ---------------------------------------------------------------------------

Deno.test("P09: preview never mutates the master row; store failure is contained", async () => {
  const row = masterRow();
  const snapshot = JSON.stringify(row);

  const ok = new MockStore();
  const succeeded = await runMasterReviewPreview(row, materialChangeResult(), ADMIN_ID, deps(ok));
  assertEquals(succeeded.preview_stored, true);
  assertEquals(JSON.stringify(row), snapshot, "successful preview left the row untouched");

  const failing = new MockStore();
  failing.failInsert = true;
  const failed = await runMasterReviewPreview(row, materialChangeResult(), ADMIN_ID, deps(failing));
  assertEquals(failed.error, "preview_store_failed");
  assertEquals(failed.preview_stored, false);
  assertEquals(failed.preview_id, null);
  assertEquals(JSON.stringify(row), snapshot, "failed store left the row untouched");

  const throwing = new MockStore();
  throwing.throwInsert = true;
  const threw = await runMasterReviewPreview(row, materialChangeResult(), ADMIN_ID, deps(throwing));
  assertEquals(threw.error, "preview_store_failed");
  assertEquals(JSON.stringify(row), snapshot, "throwing store left the row untouched");
});

// ---------------------------------------------------------------------------
// P10 — resolver patch contract validation matrix (sql/203 mirror)
// ---------------------------------------------------------------------------

Deno.test("P10: resolver patch contract validation matrix", () => {
  const full: Record<string, unknown> = {
    registered_product_name: "Name",
    registrant: null,
    product_category: "fungicide",
    form_type: null,
    label_version: "v2",
    label_reference: "https://elabels.example.gov/label.pdf",
    registered_uses: [],
    label_rate_bases: ["per_hectare"],
    verification_status: "partially_verified",
    verification_sources: [],
    verification_conflicts: null,
    verification_unresolved_fields: ["rates:grapes"],
    retrieved_at: NOW_ISO,
    source_kind: "official_register",
    source_reference: null,
  };
  assertEquals(validateResolverPatch(full), null, "all 15 contract keys accepted");
  assertEquals(
    Object.keys(full).length,
    RESOLVER_PATCH_CONTRACT_KEYS.length,
    "the contract is exactly 15 keys",
  );

  assertEquals(validateResolverPatch(null), "proposed_patch must be a non-empty object");
  assertEquals(validateResolverPatch([]), "proposed_patch must be a non-empty object");
  assertEquals(validateResolverPatch({}), "proposed_patch must be a non-empty object");
  assertEquals(validateResolverPatch("x"), "proposed_patch must be a non-empty object");
  assertEquals(
    validateResolverPatch({ verification_status: null }),
    "key verification_status must be a string",
  );
  assertEquals(validateResolverPatch({ source_kind: 3 }), "key source_kind must be a string");
  assertEquals(
    validateResolverPatch({ registrant: 7 }),
    "key registrant must be a string or null",
  );
  assertEquals(
    validateResolverPatch({ registered_uses: {} }),
    "key registered_uses must be an array",
  );
  assertEquals(
    validateResolverPatch({ verification_sources: "x" }),
    "key verification_sources must be an array or null",
  );
  // The keys a hostile client would most like to smuggle:
  assertEquals(
    validateResolverPatch({ registered_product_name: "A", catalogue_version: 9 }),
    "forbidden_key=catalogue_version",
  );
  assertEquals(
    validateResolverPatch({ registration_number: "999" }),
    "forbidden_key=registration_number",
  );
  assertEquals(
    validateResolverPatch({ review_status: "approved" }),
    "forbidden_key=review_status",
  );
  assertEquals(
    validateResolverPatch({ id: "someone-elses-row" }),
    "forbidden_key=id",
  );
});

// ---------------------------------------------------------------------------
// P11 — builder refactor regression: candidate gate preserved
// ---------------------------------------------------------------------------

Deno.test("P11: candidate gate preserved; one reviewed builder behind both paths", () => {
  const result = materialChangeResult();
  const approved = masterRow();
  const candidate = masterRow({ review_status: "candidate" });
  assertEquals(
    buildCandidateRefreshPatch(approved, result, NOW_ISO),
    null,
    "approved rows still have no in-place write path",
  );
  assertEquals(
    buildCandidateRefreshPatch(candidate, result, NOW_ISO),
    buildRefreshPatch(candidate, result, NOW_ISO),
    "candidate wrapper output identical to the shared builder",
  );
});

// ---------------------------------------------------------------------------
// P12 — every reviewed-builder output satisfies the resolver contract
// ---------------------------------------------------------------------------

Deno.test("P12: every reviewed-builder output satisfies the resolver patch contract", () => {
  const row = masterRow();
  const cases: RefreshResult[] = [
    materialChangeResult(),
    { outcome: "evidence_refreshed", changes: [], registration: registration() },
    {
      outcome: "conflict",
      changes: [{ field: "active_ingredients", current: "a", authoritative: "b" }],
      registration: registration(),
    },
  ];
  for (const result of cases) {
    const patch = buildRefreshPatch(row, result, NOW_ISO);
    assert(patch !== null, `${result.outcome} produced a patch`);
    assertEquals(
      validateResolverPatch(patch),
      null,
      `${result.outcome} patch conforms to the contract`,
    );
  }
});
