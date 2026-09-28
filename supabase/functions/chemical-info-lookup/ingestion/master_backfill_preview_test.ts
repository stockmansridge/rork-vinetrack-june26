import { assertEquals } from "jsr:@std/assert";
import type { MasterRow } from "./contract.ts";
import { buildMasterBackfillPatch } from "./master_backfill.ts";
import { alreadyCompleteBackfill, backfillCountry, finishBackfillPreview, parseBackfillRequest } from "./master_backfill_preview.ts";
import type { PreviewInsertPayload } from "./review_preview.ts";

const id = "10000000-0000-4000-8000-000000000143";
const label = "https://cropsure.com/wp-content/uploads/2023/03/cropsure-beast-200-herbicide-label-v2.pdf";
const row = (): MasterRow => ({ id, registration_country: "AU", registration_scheme: "apvma",
  registration_number: "90143", registration_identity_key: "AU:apvma:90143",
  registered_product_name: "CropSure Beast 200 Herbicide", registrant: "CropSure", common_names: [],
  product_category: "herbicide", form_type: "liquid", active_ingredients: [{ name: "Glufosinate-ammonium", concentration: 200, concentration_unit: "g/L" }],
  activity_groups: [], activity_group_scheme: null, resistance_classification_state: "unresolved",
  registered_uses: [], label_rate_bases: [], label_reference: null, label_version: null,
  verification_status: "partially_verified", verification_sources: [], verification_conflicts: [],
  verification_unresolved_fields: [], verified_at: null, source_kind: "official_register",
  source_reference: "pubcris:90143", retrieved_at: null, review_status: "approved", catalogue_version: 7,
  activity_group_table_version: 1, intelligence_schema_version: 1 });
const detail = { registration: { registration_number: "90143", manufacturer_label_url: label } };

Deno.test("canonical snake-case Master ID needs no country; legacy country cannot redirect jurisdiction", () => {
  assertEquals(parseBackfillRequest({ action: "master_backfill_preview_v2", master_chemical_id: id }), { masterId: id, dryRun: false });
  assertEquals(parseBackfillRequest({ action: "master_backfill_preview_v2", master_chemical_id: id, country: "NZ" }), { masterId: id, dryRun: false });
  assertEquals(backfillCountry(row()), "AU");
  assertEquals(parseBackfillRequest({ masterChemicalId: id }), { masterId: id, dryRun: false });
  assertEquals(parseBackfillRequest({ master_chemical_id: id, masterChemicalId: "10000000-0000-4000-8000-000000000144" }), { error: "Conflicting Master ids" });
  for (const extra of ["query", "selectedName", "patch", "proposed_patch", "proposedPatch", "apply", "registration_number", "registered_product_name"])
    assertEquals("error" in parseBackfillRequest({ master_chemical_id: id, [extra]: "redirect" }), true);
});

Deno.test("complete, no change, missing label, and conflicting identity have explicit non-writable envelopes", async () => {
  let inserts = 0;
  const store = { insertPreview: (_: PreviewInsertPayload) => { inserts++; return Promise.resolve({ id: "preview" }); } };
  const complete = alreadyCompleteBackfill(row());
  assertEquals(complete.status, "already_complete");
  assertEquals(complete.preview_id, null);
  assertEquals(complete.base_revision, 7);
  const missing = await finishBackfillPreview(row(), "admin", null, false, store);
  assertEquals(missing.status, "manufacturer_label_not_found");
  assertEquals(missing.preview_id, null);
  assertEquals(missing.findings.classified, true);
  const invalidLabel = await finishBackfillPreview(row(), "admin", { detail: { registration: {
    registration_number: "90143", manufacturer_label_url: "https://example.com/untrusted.pdf" } } }, false, store);
  assertEquals(invalidLabel.status, "manufacturer_label_not_found");
  assertEquals(invalidLabel.preview_id, null);
  const conflict = await finishBackfillPreview(row(), "admin", { identity_conflict: { printed: "99999", manufacturer_label_url: label } }, false, store);
  assertEquals(conflict.status, "identity_conflict");
  assertEquals(conflict.evidence.reported_registration_number, "99999");
  assertEquals(conflict.preview_id, null);
  const mismatch = await finishBackfillPreview(row(), "admin", { detail: { registration: { ...detail.registration, registration_number: "99999" } } }, false, store);
  assertEquals(mismatch.status, "identity_conflict");
  assertEquals(mismatch.preview_id, null);
  const evidenceConflict = await finishBackfillPreview(row(), "admin", { detail: { ...detail, verification: { conflicts: [{ field: "rate" }] } } }, false, store);
  assertEquals(evidenceConflict.status, "evidence_conflict");
  assertEquals(evidenceConflict.preview_id, null);
  const completeRow = { ...row(), ...buildMasterBackfillPatch(row(), detail).patch } as MasterRow;
  const unchanged = await finishBackfillPreview(completeRow, "admin", { detail }, false, store);
  assertEquals(unchanged.status, "no_material_change");
  assertEquals(unchanged.preview_id, null);
  assertEquals(inserts, 0);
});

Deno.test("normal review stores only a server-owned admin-bound preview; dry run and classification-only do not mutate Master", async () => {
  const master = row();
  const before = JSON.stringify(master);
  const writes: PreviewInsertPayload[] = [];
  const store = { insertPreview: (payload: PreviewInsertPayload) => {
    writes.push(payload);
    return Promise.resolve({ id: "opaque-preview", expires_at: "2026-09-28T12:30:00Z" });
  } };
  const dry = await finishBackfillPreview(master, "admin-user", { detail }, true, store);
  assertEquals(dry.status, "preview_ready");
  assertEquals(dry.preview_id, null);
  assertEquals(dry.dry_run, true);
  assertEquals(writes.length, 0);
  const result = await finishBackfillPreview(master, "admin-user", { detail }, false, store);
  assertEquals(result.status, "preview_ready");
  for (const key of ["status", "master_chemical_id", "registration_identity_key", "base_revision", "review_status", "current", "proposed_patch", "preview_id", "expires_at", "evidence", "findings"])
    assertEquals(Object.hasOwn(result, key), true, key);
  assertEquals(result.preview_id, "opaque-preview");
  assertEquals(result.expires_at, "2026-09-28T12:30:00Z");
  assertEquals(result.evidence.locked_identity, "AU:apvma:90143");
  assertEquals(result.evidence.manufacturer_label_url, label);
  assertEquals(result.findings.classified, true);
  assertEquals(writes.length, 1);
  assertEquals(writes[0].master_chemical_id, master.id);
  assertEquals(writes[0].base_revision, 7);
  assertEquals(writes[0].requested_by, "admin-user");
  assertEquals(writes[0].proposed_patch, result.proposed_patch);
  assertEquals(JSON.stringify(master), before);
  assertEquals(result.proposed_patch?.review_status, undefined);
  assertEquals(result.proposed_patch?.registration_number, undefined);
  const classOnly = await finishBackfillPreview(master, "admin-user", { detail: {} }, false, store, true);
  assertEquals(classOnly.status, "preview_ready");
  assertEquals(writes.length, 2);
});
