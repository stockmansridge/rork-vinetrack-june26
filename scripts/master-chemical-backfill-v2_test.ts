// deno-lint-ignore-file no-import-prefix
import { assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { applyPreviewIfExecuting, containRowFailure, executeReviewedPreview, parseCaptureArgs, parseReviewedPlan, patchFingerprint, pendingIds, reviewedRow, safeDiagnosticReason, saveIndexedDiagnostic, selectBackfillRows } from "./master-chemical-backfill-v2.ts";
import { finishBackfillPreview, type BackfillPreviewResponse } from "../supabase/functions/chemical-info-lookup/ingestion/master_backfill_preview.ts";
import { storeBackfillPreview, writeLookupCache } from "../supabase/functions/chemical-info-lookup/ingestion/master_backfill.ts";
import type { MasterRow } from "../supabase/functions/chemical-info-lookup/ingestion/contract.ts";

Deno.test("capture runner rejects incompatible modes and never saves an absent provider response", async () => {
  const id = "10000000-0000-4000-8000-000000000629";
  const valid = ["--dry-run", "--master-id", id, "--limit", "1", "--capture-indexed-response", "diagnostic.json"];
  assertEquals(parseCaptureArgs(valid), { masterId: id, file: "diagnostic.json" });
  for (const invalid of [
    valid.filter((arg) => arg !== "--dry-run"), valid.map((arg) => arg === "1" ? "2" : arg),
    [...valid, "--execute"], [...valid, "--resume"], [...valid, "--plan", "plan.json"],
    [...valid, "--checkpoint", "checkpoint.json"], [...valid, "--use-plan"],
    [...valid, "--retry-failed"], [...valid, "--master-id", id],
  ]) assertThrows(() => parseCaptureArgs(invalid));
  const response = { master_chemical_id: id, base_revision: 1,
    indexed_diagnostic: { snapshot: null, outcome: "no_indexed_response" } } as BackfillPreviewResponse;
  let refused = false;
  try { await saveIndexedDiagnostic(response, id, 1, "diagnostic.json"); } catch { refused = true; }
  assertEquals(refused, true);
});

Deno.test("dry-run cannot insert preview, write V2 cache or apply Master review", async () => {
  const calls: string[] = [];
  const previewStore = { insertPreview: () => { calls.push("previewStore.insertPreview"); return Promise.resolve({ id: "preview" }); } };
  const writeWebV2Cache = () => { calls.push("writeWebV2Cache"); return Promise.resolve(); };
  const masterReviewApply = () => { calls.push("master_review_apply"); return Promise.resolve({ status: "applied" }); };
  assertEquals(await storeBackfillPreview(true, previewStore.insertPreview), null);
  await writeLookupCache(true, true, writeWebV2Cache);
  assertEquals(await applyPreviewIfExecuting(false, "preview", masterReviewApply), null);
  assertEquals(calls, []);
});

Deno.test("canary selection is stable by id and only incomplete by default", () => {
  const row = (id: string, state: "unresolved" | "classified") => ({
    id, registration_country: "AU", registration_scheme: "apvma", registration_number: "90143",
    registration_identity_key: "AU:apvma:90143", registered_product_name: id, product_category: "herbicide",
    active_ingredients: [{ name: "Glufosinate-ammonium", concentration: 200, concentration_unit: "g/L", activity_group: { scheme: "hrac", code: "10" } }],
    activity_groups: ["10"], resistance_classification_state: state, registered_uses: [],
    viticulture_rates: { per_hectare: [], per_100_litres: [] },
    verification_sources: [{ kind: "manufacturer_label", name: "Label", reference: "https://cropsure.com/wp-content/uploads/2023/03/cropsure-beast-200-herbicide-label-v2.pdf" }],
    verification_unresolved_fields: [],
  }) as unknown as MasterRow;
  assertEquals(selectBackfillRows([row("z", "unresolved"), row("a", "classified"), row("b", "unresolved")], null, 1).map((r) => r.id), ["b"]);
  assertEquals(selectBackfillRows([row("z", "unresolved")], "z", 1).map((r) => r.id), ["z"]);
});

Deno.test("one failing lookup is contained and the next row still runs", async () => {
  let visited = 0;
  const first = await containRowFailure(() => { visited++; return Promise.reject(new Error("timeout")); });
  const second = await containRowFailure(() => { visited++; return Promise.resolve("preview_ready"); });
  assertEquals(first.error, true);
  assertEquals(second.value, "preview_ready");
  assertEquals(visited, 2);
});

Deno.test("canonical patch fingerprint ignores nested object ordering, not array order or text", async () => {
  const a = { registered_uses: [{ crop: "GRAPE", rates: [{ unit: "mL/100 L", value: 400 }], restrictions: "A" }],
    verification_sources: [{ kind: "manufacturer_label", reference: "label" }] };
  const b = { verification_sources: [{ reference: "label", kind: "manufacturer_label" }],
    registered_uses: [{ restrictions: "A", rates: [{ value: 400, unit: "mL/100 L" }], crop: "GRAPE" }] };
  assertEquals(await patchFingerprint(a), await patchFingerprint(b));
  assertEquals(await patchFingerprint(a) === await patchFingerprint({ ...a, registered_uses: [{ ...a.registered_uses[0], restrictions: "B" }] }), false);
  assertEquals(await patchFingerprint(a) === await patchFingerprint({ ...a, verification_sources: [...a.verification_sources, { kind: "other" }] }), false);
  assertEquals(await patchFingerprint({ values: ["a", "b"] }) === await patchFingerprint({ values: ["b", "a"] }), false);
});

Deno.test("TALSTAR reviewed plan rejects extraction drift before any apply or audit; stored second pass is inert", async () => {
  const label = "https://www.fmc.com/label/talstar-250-ec-label.pdf";
  const rate = { label: "Fig longicorn", rate_id: "rate_v1_talstar_fig", basis: "per_100_litres" as const, min_value: 400, max_value: 400,
    unit: "mL/100 L", raw_text: "400 mL/100 L" };
  const row = {
    id: "04376d16-6e66-455e-a0a4-f02c8007bc64", registration_country: "AU", registration_scheme: "apvma",
    registration_number: "60987", registration_identity_key: "AU:apvma:60987", registered_product_name: "TALSTAR 250 EC INSECTICIDE/MITICIDE",
    registrant: "FMC", product_category: "insecticide", active_ingredients: [{ name: "Bifenthrin", concentration: 250,
      concentration_unit: "g/L", activity_group: { scheme: "irac", code: "3A", common_name: "Pyrethroid" },
      group_source: "authoritative_classification" }], activity_groups: ["3A"], activity_group_scheme: "irac",
    resistance_classification_state: "classified", registered_uses: [
      ...Array.from({ length: 82 }, (_, i) => ({ crop: `Other crop ${i}`, target_raw: `Other pest ${i}`, rates: [] })),
      { crop: "GRAPE", target_raw: "FIG LONGICORN", rates: [] }],
    viticulture_rates: { per_hectare: [], per_100_litres: [] }, label_rate_bases: [],
    verification_sources: [{ kind: "manufacturer_label", name: "Manufacturer commercial label", reference: label }],
    verification_unresolved_fields: [], review_status: "candidate", catalogue_version: 1,
  } as unknown as MasterRow;
  const detail = (restrictions: string) => ({ registration: { registration_number: "60987", manufacturer_label_url: label },
    registered_uses: [{ crop: "Grapes", target_raw: "Fig longicorn (Acalolepta vastator)", rates: [rate],
      restrictions, withholding_period_days: 7, re_entry_period_hours: 12 }] });
  let previewWrites = 0;
  let masterWrites = 0;
  let auditActions = 0;
  const store = { insertPreview: () => { previewWrites++; return Promise.resolve({ id: `preview-${previewWrites}` }); } };
  const first = await finishBackfillPreview(row, "admin", { detail: detail("Apply as directed") }, true, store);
  assertEquals(first.status, "preview_ready");
  assertEquals((first.proposed_patch?.registered_uses as unknown[]).length, 83);
  assertEquals((first.proposed_patch?.registered_uses as Array<{ crop: string }>).filter((use) => use.crop === "GRAPE").length, 1);
  assertEquals((first.proposed_patch?.viticulture_rates as { per_100_litres: unknown[] }).per_100_litres, [rate]);
  const plan = parseReviewedPlan([await reviewedRow(row, first)])[0];
  assertEquals(plan.reviewed_status, "preview_ready");
  assertEquals(plan.proposed_patch_sha256?.length, 64);
  assertEquals(previewWrites, 0);
  const fresh = await finishBackfillPreview(row, "admin", { detail: detail("Follow the directions for use") }, false, store);
  const checked = await executeReviewedPreview(plan, row, fresh, () => {
    masterWrites++; auditActions++; return Promise.resolve({ status: "applied" });
  });
  assertEquals(checked.status, "preview_drift");
  assertEquals(checked.reason, "proposed_patch_sha256");
  assertEquals(masterWrites, 0);
  assertEquals(auditActions, 0);
  assertEquals(previewWrites, 1);
  const stored = { ...row, ...first.proposed_patch, catalogue_version: 2 } as MasterRow;
  const second = await finishBackfillPreview(stored, "admin", { detail: detail("Follow the directions for use") }, false, store);
  assertEquals(second.status, "no_material_change");
  assertEquals(second.preview_id, null);
  assertEquals(second.proposed_patch, null);
  assertEquals(stored.registered_uses.length, 83);
  assertEquals(stored.registered_uses.filter((use) => use.crop === "GRAPE").length, 1);
  assertEquals(stored.viticulture_rates?.per_100_litres, [rate]);
  assertEquals(previewWrites, 1);
  assertEquals(masterWrites, 0);
  assertEquals(auditActions, 0);
});

Deno.test("unapproved canary statuses and revision/identity/status drift never apply", async () => {
  const id = "04376d16-6e66-455e-a0a4-f02c8007bc64";
  const identity = "AU:apvma:60987";
  const row = { id, registration_identity_key: identity, catalogue_version: 2 } as MasterRow;
  const patch = { registered_uses: [{ crop: "GRAPE" }] };
  const response = { status: "preview_ready", master_chemical_id: id, registration_identity_key: identity,
    base_revision: 2, proposed_patch: patch, preview_id: "preview", evidence: {},
    review_status: "candidate", current: {}, expires_at: null,
    findings: { classified: false, not_applicable: false, vineyard_rates_added: false, no_vineyard_use: false } } as BackfillPreviewResponse;
  let writes = 0;
  const apply = () => { writes++; return Promise.resolve("applied"); };
  const approved = parseReviewedPlan([{ id, registration_identity_key: identity, base_revision: 2,
    reviewed_status: "preview_ready", proposed_patch_sha256: await patchFingerprint(patch) }])[0];
  assertEquals((await executeReviewedPreview(approved, row, response, apply)).result, "applied");
  writes = 0;
  for (const status of ["manufacturer_label_not_found", "identity_conflict", "evidence_conflict", "no_material_change", "already_complete"]) {
    const denied = parseReviewedPlan([{ ...approved, reviewed_status: status, proposed_patch_sha256: null }])[0];
    assertEquals((await executeReviewedPreview(denied, row, response, apply)).status, "plan_drift");
  }
  for (const [changedRow, changedResponse, reason] of [
    [{ ...row, catalogue_version: 3 }, response, "base_revision"],
    [{ ...row, registration_identity_key: "AU:apvma:other" }, response, "registration_identity_key"],
    [row, { ...response, status: "evidence_conflict" }, "status:evidence_conflict"],
    [row, { ...response, master_chemical_id: "wrong" }, "master_id"],
    [row, { ...response, proposed_patch: { registered_uses: [{ crop: "OTHER" }] } }, "proposed_patch_sha256"],
  ] as const) assertEquals((await executeReviewedPreview(approved, changedRow as MasterRow,
    changedResponse as BackfillPreviewResponse, apply)).reason, reason);
  assertEquals(writes, 0);
  assertThrows(() => parseReviewedPlan([{ id, identity }]));
  assertThrows(() => parseReviewedPlan([approved, approved]));
});

Deno.test("runner prints safe manufacturer discovery reasons and retains conflict diagnostics", () => {
  const response = { status: "manufacturer_label_not_found", evidence: {} } as BackfillPreviewResponse;
  for (const reason of [
    "search_no_candidate", "search_timeout", "host_not_verified", "product_page_fetch_failed",
    "product_name_mismatch", "label_link_not_found", "label_fetch_failed", "label_unreadable",
  ]) {
    const diagnostic = safeDiagnosticReason({ ...response, evidence: { reason } });
    assertEquals(diagnostic, reason);
    assertEquals(`SIMANEX 900 WG HERBICIDE ${response.status}${diagnostic ? `: ${diagnostic}` : ""}`,
      `SIMANEX 900 WG HERBICIDE manufacturer_label_not_found: ${reason}`);
  }
  assertEquals(safeDiagnosticReason({ ...response, status: "evidence_conflict", evidence: { reason: "vineyard_use_or_rate" } }), "vineyard_use_or_rate");
  assertEquals(safeDiagnosticReason({ ...response, status: "identity_conflict", evidence: { conflicts: ["manufacturer_product_identity_mismatch"] } }), "manufacturer_product_identity_mismatch");
  for (const reason of ["Bearer secret", "https://example.com/label.pdf", "label fetch failed: token", "a".repeat(81), "LABEL_UNREADABLE"]) {
    assertEquals(safeDiagnosticReason({ ...response, evidence: { reason } }), null);
  }
  assertEquals(safeDiagnosticReason({ ...response, status: "evidence_conflict", evidence: { reason: "Bearer secret" } }), null);
  assertEquals(safeDiagnosticReason({ ...response, status: "already_complete", evidence: { reason: "search_timeout" } }), null);
});

Deno.test("runner prints only fixed indexed reasons for missing manufacturer labels", () => {
  const response = { status: "manufacturer_label_not_found", evidence: {} } as BackfillPreviewResponse;
  for (const code of [
    "candidate_not_approved", "index_request_failed", "index_request_timeout", "index_request_transient",
    "index_request_permanent", "index_request_refusal", "no_web_search_evidence",
    "exact_url_not_consulted", "malformed_index_result", "product_identity_mismatch",
    "registration_missing", "active_identity_mismatch", "rate_no_vineyard_rows", "rate_use_source_mismatch",
    "rate_source_mismatch", "rate_value_invalid", "rate_raw_text_missing", "rate_basis_unrecognised",
    "rate_unit_unrecognised", "rate_raw_text_mismatch", "rate_state_soil_missing", "simanex_completeness_failed",
  ]) {
    const reason = `label_index_unavailable: ${code}`;
    const diagnostic = safeDiagnosticReason({ ...response, evidence: { reason } });
    assertEquals(diagnostic, reason);
    assertEquals(`SIMANEX 900 WG HERBICIDE ${response.status}${diagnostic ? `: ${diagnostic}` : ""}`,
      `SIMANEX 900 WG HERBICIDE manufacturer_label_not_found: ${reason}`);
  }
});

Deno.test("runner suppresses unapproved indexed text, URLs and tokens without changing conflict diagnostics", () => {
  const response = { status: "manufacturer_label_not_found", evidence: {} } as BackfillPreviewResponse;
  for (const reason of [
    "label_index_unavailable: unknown_code", "label_index_unavailable: rate_condition_incomplete",
    "label_index_unavailable: rate_dose_unparseable", "label_index_unavailable: rate_raw_text_mismatch: secret",
    "label_index_unavailable: arbitrary free-form text",
    "label_index_unavailable: exact_url_not_consulted: extra", "label_index_unavailable: exact_url_not_consulted ",
    "label_index_unavailable: https://example.com/label.pdf", "label_index_unavailable: Bearer secret",
    "label_index_unavailable: token=secret", "label_index_unavailable: exact_url_not_consulted https://example.com",
    "label_index_unavailable: exact_url_not_consulted\n", "label_index_unavailable: ", "other_prefix: exact_url_not_consulted",
  ]) assertEquals(safeDiagnosticReason({ ...response, evidence: { reason } }), null);
  assertEquals(safeDiagnosticReason({ ...response, status: "evidence_conflict",
    evidence: { reason: "vineyard_use_or_rate" } }), "vineyard_use_or_rate");
  assertEquals(safeDiagnosticReason({ ...response, status: "identity_conflict",
    evidence: { conflicts: ["manufacturer_product_identity_mismatch"] } }), "manufacturer_product_identity_mismatch");
  for (const status of ["identity_conflict", "evidence_conflict"] as const) {
    assertEquals(safeDiagnosticReason({ ...response, status,
      evidence: { reason: "label_index_unavailable: exact_url_not_consulted" } }), null);
  }
});

Deno.test("resume skips successes and failures; retry-failed targets only failures", () => {
  const checkpoint = { ids: ["a", "b", "c", "d"], completed: { a: "updated" }, failed: { c: "lookup_unavailable" } };
  assertEquals(pendingIds(checkpoint, false), ["b", "d"]);
  assertEquals(pendingIds(checkpoint, true), ["c"]);
});
