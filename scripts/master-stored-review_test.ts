// deno-lint-ignore-file no-import-prefix
import { assertEquals, assertRejects, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { applyStoredReview, confirmCoverEvidence, inspectStoredReview, parseStoredReviewArgs, preparationRequest, prepareStoredReview, type ReviewApi, type StoredReviewPreview } from "./master-stored-review.ts";
import { finishBackfillPreview, type BackfillPreviewResponse } from "../supabase/functions/chemical-info-lookup/ingestion/master_backfill_preview.ts";
import type { MasterRow } from "../supabase/functions/chemical-info-lookup/ingestion/contract.ts";

const id = "0086e68a-8694-4639-9922-2daf0a5274c8";
const previewId = "10000000-0000-4000-8000-000000000001";
const label = "https://www.adama.com/australia/sites/adama_australia/files/product-documents/2025-01/10150_Adama_Simanex_A4xWebLabel_F_0.pdf";
const expiry = "2030-09-28T12:00:00Z";

function fixture() {
  let lookups = 0;
  let inserts = 0;
  let applies = 0;
  let owner = "admin";
  let row = { id, registration_country: "AU", registration_scheme: "apvma", registration_number: "62917",
    registration_identity_key: "AU:apvma:62917", registered_product_name: "SIMANEX 900 WG HERBICIDE", registrant: "ADAMA AUSTRALIA PTY LIMITED",
    active_ingredients: [{ name: "simazine", concentration: 900, concentration_unit: "g/kg", activity_group: { scheme: "hrac", code: "5" } }],
    activity_groups: ["5"], activity_group_scheme: "hrac", resistance_classification_state: "classified",
    product_category: "herbicide", registered_uses: [], viticulture_rates: { per_hectare: [], per_100_litres: [] },
    verification_sources: [], verification_unresolved_fields: [], review_status: "candidate", catalogue_version: 1 } as unknown as MasterRow;
  let stored: StoredReviewPreview | null = null;
  const api: ReviewApi = {
    currentUser: () => Promise.resolve(owner), master: () => Promise.resolve(row),
    prepare: async (_id, _diagnostic) => {
      lookups++;
      return await finishBackfillPreview(row, owner, { detail: {
        registration: { registration_number: "62917", manufacturer_label_url: label, manufacturer_label_verified: true,
          manufacturer_label_retrieval_method: "web_search_index", manufacturer_label_identifiers: { numbers: ["62917"], printed_values: ["62917"] } },
        registered_uses: [{ crop: "Grapevines", target: "Suppression: ryegrass", conditions: "State: QLD; Soil: light",
          restrictions: "At least two years old", rates: [{ rate_id: "rate_v1_simanex_light", basis: "per_hectare",
            value: 2, unit: "kg", raw_text: "2 kg", label: "State: QLD; Soil: light" }] }],
      } }, false, { insertPreview: (payload) => {
        inserts++;
        stored = { id: previewId, master_chemical_id: id, base_revision: 1, requested_by: owner,
          expires_at: expiry, consumed_at: null, proposed_patch: payload.proposed_patch };
        return Promise.resolve({ id: previewId, expires_at: expiry });
      } });
    },
    stored: () => stored ? Promise.resolve(stored) : Promise.reject(new Error("not stored")),
    apply: (p, m, reason) => {
      assertEquals([p, m, reason], [previewId, id, "Reviewed label"]);
      applies++;
      row = { ...row, ...stored!.proposed_patch, catalogue_version: 2 } as MasterRow;
      stored = { ...stored!, consumed_at: "2026-09-28T11:00:00Z" };
      return Promise.resolve({ status: "applied", result_revision: 2 });
    },
  };
  return { api, counters: () => ({ lookups, inserts, applies }), changeOwner: (value: string) => { owner = value; },
    changeRow: (value: MasterRow) => { row = value; }, row: () => row,
    changeStored: (change: (s: StoredReviewPreview) => StoredReviewPreview) => { stored = change(stored!); } };
}

Deno.test("one lookup stores a full preview; inspect and audited apply use the same hashed server patch with no new research", async () => {
  const f = fixture();
  const prepared = await prepareStoredReview(f.api, id);
  assertEquals(prepared.response.status, "preview_ready");
  assertEquals(f.counters(), { lookups: 1, inserts: 1, applies: 0 });
  const manifest = prepared.manifest!;
  assertEquals(manifest.preview_id, previewId);
  assertEquals(manifest.registration_identity_key, "AU:apvma:62917");
  assertEquals(manifest.proposed_patch_sha256.length, 64);
  const inspected = await inspectStoredReview(f.api, manifest, () => Date.parse("2026-09-28T11:00:00Z"));
  assertEquals(inspected.pending, true);
  const patch = inspected.patch as Record<string, unknown>;
  assertEquals((patch.verification_sources as Array<{ reference: string; retrieval_method: string }>)[0].reference, label);
  assertEquals((patch.verification_sources as Array<{ reference: string; retrieval_method: string }>)[0].retrieval_method, "web_search_index");
  assertEquals((patch.registered_uses as Array<{ target: string; restrictions: string; rates: Array<{ basis: string }> }>)[0].target, "Suppression: ryegrass");
  assertEquals((patch.registered_uses as Array<{ target: string; restrictions: string; rates: Array<{ basis: string }> }>)[0].restrictions, "At least two years old");
  assertEquals((patch.registered_uses as Array<{ target: string; restrictions: string; rates: Array<{ basis: string }> }>)[0].rates[0].basis, "per_hectare");
  assertEquals(f.counters().lookups, 1);
  assertEquals(await applyStoredReview(f.api, manifest, "Reviewed label"), { status: "applied", result_revision: 2 });
  assertEquals(f.counters(), { lookups: 1, inserts: 1, applies: 1 });
  assertEquals(f.row().registered_uses, patch.registered_uses);
  await assertRejects(() => applyStoredReview(f.api, manifest, "Reviewed label"));
  assertEquals(f.counters(), { lookups: 1, inserts: 1, applies: 1 });
});

Deno.test("invalid identity or merge conflict creates no preview; expired, stale, stolen, tampered and reasonless previews cannot apply", async () => {
  const f = fixture();
  f.changeRow({ ...f.row(), registration_identity_key: "AU:apvma:wrong" });
  assertEquals((await prepareStoredReview(f.api, id)).manifest, null);
  assertEquals(f.counters().inserts, 0);
  f.changeRow({ ...f.row(), registration_identity_key: "AU:apvma:62917" });
  const manifest = (await prepareStoredReview(f.api, id)).manifest!;
  const check = async () => { await assertRejects(() => applyStoredReview(f.api, manifest, "Reviewed label")); assertEquals(f.counters().applies, 0); };
  await assertRejects(() => applyStoredReview(f.api, manifest, " "));
  f.changeOwner("other-admin"); await check(); f.changeOwner("admin");
  f.changeStored((s) => ({ ...s, proposed_patch: { ...s.proposed_patch, registered_uses: [] } })); await check();
  // Use a separate fixture for stale and expired conditions, not a second lookup during apply.
  const fresh = fixture(); const approved = (await prepareStoredReview(fresh.api, id)).manifest!;
  fresh.changeRow({ ...fresh.row(), catalogue_version: 2 });
  await assertRejects(() => applyStoredReview(fresh.api, approved, "Reviewed label"));
  fresh.changeRow({ ...fresh.row(), catalogue_version: 1 });
  fresh.changeStored((s) => ({ ...s, expires_at: "2020-01-01T00:00:00Z" }));
  await assertRejects(() => applyStoredReview(fresh.api, approved, "Reviewed label"));
  assertEquals(fresh.counters().applies, 0);
  await assertRejects(() => applyStoredReview(fresh.api, { ...approved, proposed_patch_sha256: "0".repeat(64) }, "Reviewed label"));
});

Deno.test("indexed success still cannot store a preview when full Master merge conflicts", async () => {
  const f = fixture();
  let lookups = 0;
  const api = { ...f.api, prepare: async () => {
    lookups++;
    return await finishBackfillPreview(f.row(), "admin", { detail: {
      registration: { registration_number: "62917", manufacturer_label_url: label, manufacturer_label_verified: true },
      verification: { conflicts: [{ field: "rates", reason: "different stored dose" }] },
    } }, false, { insertPreview: () => { throw new Error("conflicting merge must not store"); } });
  } };
  const result = await prepareStoredReview(api, id);
  assertEquals(result.manifest, null);
  assertEquals(result.response.status, "evidence_conflict");
  assertEquals(lookups, 1);
  assertEquals(f.counters().inserts, 0);
});

Deno.test("failed indexed identity check stays non-writable and diagnostic never promotes snapshot to evidence", async () => {
  const snapshot = { complete: false, validator_version: 1, reason: "incomplete_test_snapshot" };
  assertEquals(snapshot.complete, false);
  assertEquals(snapshot.validator_version, 1);
  let calls = 0;
  const f = fixture();
  const api = { ...f.api, prepare: (_id: string, diagnostic: boolean) => {
    calls++;
    assertEquals(diagnostic, true);
    return Promise.resolve({ status: "identity_conflict", master_chemical_id: id,
      registration_identity_key: "AU:apvma:62917", base_revision: 1, review_status: "candidate", preview_id: null,
      expires_at: null, proposed_patch: null, evidence: { reason: "product_identity_mismatch" },
      indexed_diagnostic: { snapshot, outcome: "captured" } } as unknown as BackfillPreviewResponse);
  } };
  const result = await prepareStoredReview(api, id, true);
  assertEquals(result.manifest, null);
  assertEquals(result.response.indexed_diagnostic?.snapshot?.complete, snapshot.complete);
  assertEquals(result.response.indexed_diagnostic?.snapshot?.validator_version, snapshot.validator_version);
  assertEquals(calls, 1);
  assertEquals(f.counters(), { lookups: 0, inserts: 0, applies: 0 });
});

Deno.test("unsigned real cover evidence requires matching PDF and explicit cover-only confirmation", async () => {
  const candidate = JSON.parse(await Deno.readTextFile("docs/weedmaster-acceptance/visual_review_candidate.json"));
  const pdf = await Deno.readFile("docs/weedmaster-acceptance/weedmaster_duo_documented.pdf");
  const answer = `CONFIRM COVER ${candidate.document_sha256}`;
  await assertRejects(() => confirmCoverEvidence(candidate, pdf, null));
  await assertRejects(() => confirmCoverEvidence(candidate, pdf, "yes"));
  await assertRejects(() => confirmCoverEvidence({ ...candidate, confirm_review: true }, pdf, answer));
  await assertRejects(() => confirmCoverEvidence({ ...candidate, reviewed_by: "synthetic" }, pdf, answer));
  await assertRejects(() => confirmCoverEvidence(candidate, new Uint8Array([1, 2, 3]), answer));
  const evidence = await confirmCoverEvidence(candidate, pdf, answer);
  assertEquals(evidence.confirm_review, true);
  assertEquals(evidence.verbatim, candidate.verbatim);
  assertEquals("reviewed_by" in evidence, false);
  assertEquals("reviewed_at" in evidence, false);
  assertEquals(candidate.confirm_review, false);
  assertEquals(preparationRequest(id, false, evidence), { action: "master_backfill_preview_v2",
    master_chemical_id: id, reviewed_visual_declaration: evidence });
  assertEquals(preparationRequest(id, false), { action: "master_backfill_preview_v2", master_chemical_id: id });
  assertEquals(preparationRequest(id, true, evidence).capture_indexed_response, true);
});

Deno.test("prepare forwards confirmed cover only to one live-row preview; identity mismatch never calls prepare", async () => {
  const f = fixture();
  const evidence = { confirm_review: true, verbatim: "human-confirmed cover" };
  const calls: Array<Record<string, unknown> | undefined> = [];
  const api: ReviewApi = { ...f.api, prepare: (id, diagnostic, declaration) => {
    calls.push(declaration);
    return f.api.prepare(id, diagnostic, declaration);
  } };
  await assertRejects(() => prepareStoredReview(api, id, false, evidence, "AU:apvma:53576"));
  assertEquals(calls.length, 0);
  assertEquals(f.counters().applies, 0);
  const result = await prepareStoredReview(api, id, false, evidence, "AU:apvma:62917");
  assertEquals(calls, [evidence]);
  assertEquals(result.manifest?.master_chemical_id, id);
  assertEquals(f.counters().applies, 0);
});

Deno.test("mode parser forbids mixing dry-run, capture, execute, batch and client patch options", () => {
  const valid = parseStoredReviewArgs(["prepare", "--master-id", id, "--manifest", "m.json", "--report", "r.json", "--diagnostic", "d.json"]);
  assertEquals(valid.id, id);
  const cover = parseStoredReviewArgs(["prepare", "--master-id", id, "--manifest", "m.json", "--report", "r.json",
    "--evidence-file", "cover.json", "--document", "label.pdf", "--expected-identity", "AU:apvma:53576"]);
  assertEquals(cover.evidenceFile, "cover.json");
  assertThrows(() => parseStoredReviewArgs(["prepare", "--master-id", id, "--manifest", "m.json", "--report", "r.json", "--evidence-file", "cover.json"]));
  assertThrows(() => parseStoredReviewArgs(["apply", "--manifest", "m.json", "--reason", "Reviewed", "--evidence-file", "cover.json"]));
  for (const extra of ["--dry-run", "--execute", "--patch", "--limit", "--capture-indexed-response"])
    assertThrows(() => parseStoredReviewArgs(["apply", "--manifest", "m.json", "--reason", "Reviewed", extra, "x"]));
  assertThrows(() => parseStoredReviewArgs(["prepare", "--master-id", id, "--manifest", "m.json", "--report", "m.json"]));
});
