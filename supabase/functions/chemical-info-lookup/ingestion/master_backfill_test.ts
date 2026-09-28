// deno-lint-ignore-file no-import-prefix
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { MasterRow } from "./contract.ts";
import { authoritativeBackfillDetail, buildMasterBackfillPatch, equalBackfillValue, isIncompleteMaster, lockedWebIdentity } from "./master_backfill.ts";
import { validateResolverPatch } from "./review_preview.ts";

const LABEL = "https://cropsure.com/wp-content/uploads/2023/03/cropsure-beast-200-herbicide-label-v2.pdf";
const active = { name: "Glufosinate-ammonium", concentration: 200, concentration_unit: "g/L",
  activity_group: { scheme: "hrac" as const, code: "10" }, group_source: "authoritative_classification" };
const rate = { label: "Printed range", rate_id: "rate_v1_example", basis: "range_per_hectare" as const, min_value: 1, max_value: 5, unit: "L/ha", raw_text: "1–5 L/ha" };
const master = (overrides: Partial<MasterRow> = {}): MasterRow => ({
  id: "10000000-0000-4000-8000-000000000143", registration_country: "AU", registration_scheme: "apvma",
  registration_number: "90143", registration_identity_key: "AU:apvma:90143", registered_product_name: "CropSure Beast 200 Herbicide",
  registrant: "CropSure", common_names: [], product_category: "herbicide", form_type: "liquid",
  active_ingredients: [{ name: active.name, concentration: 200, concentration_unit: "g/L" }], activity_groups: [],
  activity_group_scheme: null, resistance_classification_state: "unresolved", registered_uses: [], label_rate_bases: [],
  label_reference: "https://elabels.apvma.gov.au/90143.pdf", label_version: null, verification_status: "verified",
  verification_sources: [{ kind: "official_register", name: "APVMA", reference: "pubcris:90143" }],
  verification_conflicts: [], verification_unresolved_fields: [], verified_at: null,
  source_kind: "official_register", source_reference: "pubcris:90143", retrieved_at: null,
  review_status: "candidate", catalogue_version: 1, activity_group_table_version: 1,
  intelligence_schema_version: 1, ...overrides,
});
const detail = (overrides: Record<string, unknown> = {}) => ({
  registration: { registration_number: "90143", manufacturer_label_url: LABEL, registrant: "CropSure" },
  active_ingredients: [active], activity_groups: ["10"], activity_group_scheme: "hrac",
  resistance_classification_state: "classified",
  registered_uses: [{ crop: "Grapevines", target: "weeds", direction_id: "direction_v1_example", rates: [rate] }],
  ...overrides,
});

Deno.test("backfill JSON equality ignores object key order but preserves exact values and array order", () => {
  const original = { number: "90143", scheme: "apvma", source: "manufacturer_label", canonical: true };
  assertEquals(equalBackfillValue(original, { scheme: "apvma", number: "90143", source: "manufacturer_label", canonical: true }), true);
  assertEquals(equalBackfillValue({ sources: [{ metadata: { number: "90143", canonical: true } }] },
    { sources: [{ metadata: { canonical: true, number: "90143" } }] }), true);
  assertEquals(equalBackfillValue(original, { scheme: "apvma", number: "127764", source: "manufacturer_label", canonical: true }), false);
  assertEquals(equalBackfillValue(original, { ...original, canonical: false }), false);
  assertEquals(equalBackfillValue({ numbers: ["90143", "127764"] }, { numbers: ["127764", "90143"] }), false);
  assertEquals(equalBackfillValue({ number: "90143" }, { number: 90143 }), false);
  assertEquals(equalBackfillValue({ number: undefined }, {}), false);
});

Deno.test("locked Master identity prevents wrong registration and preserves identity/status/history surface", () => {
  const row = master();
  assertEquals(lockedWebIdentity(row)?.registrationNumber, "90143");
  assertEquals(lockedWebIdentity(master({ registration_identity_key: "AU:apvma:99999" })), null);
  const result = buildMasterBackfillPatch(row, detail());
  assertEquals(result.status, "preview_ready");
  assertEquals(result.patch?.resistance_classification_state, "classified");
  assertEquals(result.patch?.viticulture_rates, { per_hectare: [rate], per_100_litres: [] });
  assertEquals(result.patch?.label_reference, undefined);
  assertEquals(result.patch?.verification_sources, [row.verification_sources?.[0],
    { kind: "manufacturer_label", name: "Manufacturer commercial label", reference: LABEL }]);
  for (const key of ["id", "registration_number", "registration_identity_key", "review_status", "review_notes", "catalogue_version", "regulator_label_url"])
    assertEquals(result.patch?.[key], undefined);
  assertEquals(validateResolverPatch(result.patch), null);
  assertEquals(buildMasterBackfillPatch(master({ review_status: "approved" }), detail()).patch?.review_status, undefined);
});

Deno.test("printed identifiers are label evidence, never a Master rekey", () => {
  const row = master();
  const identifiers = { numbers: ["90143", "127764"], printed_values: ["90143/127764"] };
  const proposed = buildMasterBackfillPatch(row, detail({ registration: {
    registration_number: "90143", manufacturer_label_url: LABEL, manufacturer_label_identifiers: identifiers } }));
  assertEquals(proposed.status, "preview_ready");
  assertEquals(proposed.patch?.registration_number, undefined);
  assertEquals(proposed.patch?.registration_identity_key, undefined);
  const source = (proposed.patch?.verification_sources as NonNullable<MasterRow["verification_sources"]>)[1];
  assertEquals(source.registration_numbers, [
    { scheme: "apvma", number: "90143", source: "manufacturer_label", canonical: true },
    { scheme: "apvma", number: "127764", source: "manufacturer_label", canonical: false },
  ]);
  assertEquals(source.printed_registration_values, ["90143/127764"]);
  const stored = { ...row, ...proposed.patch, verification_sources: [row.verification_sources![0], {
    reference: LABEL, name: "Manufacturer commercial label", kind: "manufacturer_label" as const,
    printed_registration_values: ["90143/127764"], registration_numbers: [
      { number: "90143", scheme: "apvma", canonical: true, source: "manufacturer_label" },
      { canonical: false, source: "manufacturer_label", number: "127764", scheme: "apvma" },
    ],
  }] } as MasterRow;
  const second = buildMasterBackfillPatch(stored, detail({ registration: {
    registration_number: "90143", manufacturer_label_url: LABEL, manufacturer_label_identifiers: identifiers } }));
  assertEquals(second.status, "no_material_change");
  assertEquals(second.patch, null);
  const changed = buildMasterBackfillPatch({ ...stored, verification_sources: [row.verification_sources![0], {
    ...stored.verification_sources![1], printed_registration_values: ["127764"] }] }, detail({ registration: {
    registration_number: "90143", manufacturer_label_url: LABEL, manufacturer_label_identifiers: identifiers } }));
  assertEquals(changed.patch?.verification_sources !== undefined, true);
  assertEquals(buildMasterBackfillPatch({ ...row, ...proposed.patch } as MasterRow, detail({ registration: {
    registration_number: "90143", manufacturer_label_url: LABEL, manufacturer_label_identifiers: identifiers } })).patch, null);
  assertEquals(buildMasterBackfillPatch(master(), detail({ active_ingredients: [{ name: "Other" }] })).status, "evidence_conflict");
});

Deno.test("incomplete mixture cannot claim classified; explicit not-applicable only", () => {
  const unresolved = buildMasterBackfillPatch(master({ active_ingredients: [active, { name: "Unknown" }] }),
    detail({ active_ingredients: [active, { name: "Unknown" }], resistance_classification_state: "unresolved" }));
  assertEquals(unresolved.patch?.resistance_classification_state, undefined);
  const free = buildMasterBackfillPatch(master({ product_category: "adjuvant", active_ingredients: [] }),
    detail({ active_ingredients: [{ name: "Adjuvant", identity_source: "manufacturer_label", activity_group: { scheme: "not_applicable", code: "" } }],
      activity_group_scheme: "not_applicable", activity_groups: [], resistance_classification_state: "not_applicable" }));
  assertEquals(free.patch?.resistance_classification_state, "not_applicable");
  const empty = buildMasterBackfillPatch(master({ active_ingredients: [] }),
    detail({ active_ingredients: [], activity_group_scheme: "not_applicable", resistance_classification_state: "not_applicable" }));
  assertEquals(empty.patch?.resistance_classification_state, undefined);
});

Deno.test("second pass is non-destructive and complete rows are skipped", () => {
  const row = master({ active_ingredients: [active], activity_groups: ["10"], activity_group_scheme: "hrac",
    resistance_classification_state: "classified", viticulture_rates: { per_hectare: [rate], per_100_litres: [] },
    label_rate_bases: ["range_per_hectare"],
    registered_uses: detail().registered_uses, verification_sources: [master().verification_sources![0],
      { kind: "manufacturer_label", name: "Manufacturer commercial label", reference: LABEL }],
    verification_unresolved_fields: [] });
  assertEquals(isIncompleteMaster(row), false);
  assertEquals(buildMasterBackfillPatch(row, detail()).status, "no_material_change");
});

Deno.test("only relevant unresolved markers select a ready vineyard product", () => {
  const row = master({ active_ingredients: [active], activity_groups: ["10"], activity_group_scheme: "hrac",
    resistance_classification_state: "classified", registered_uses: detail().registered_uses,
    viticulture_rates: { per_hectare: [rate], per_100_litres: [] },
    verification_sources: [{ kind: "manufacturer_label", name: "Label", reference: LABEL }],
    verification_unresolved_fields: ["rates:POTATO"] });
  assertEquals(isIncompleteMaster(row), false);
  assertEquals(buildMasterBackfillPatch(row, detail()).patch?.verification_unresolved_fields, undefined);
});

Deno.test("authoritative classification works without PDF, including the second active", () => {
  const tebu = master({ active_ingredients: [{ name: "Tebuconazole", concentration: 250, concentration_unit: "g/L" }],
    activity_groups: [], verification_unresolved_fields: ["activity_group:Tebuconazole", "rates:POTATO"] });
  const proposed = buildMasterBackfillPatch(tebu, authoritativeBackfillDetail(tebu));
  assertEquals(proposed.patch?.activity_groups, ["3"]);
  assertEquals(proposed.patch?.activity_group_scheme, "frac");
  assertEquals(proposed.patch?.resistance_classification_state, "classified");
  assertEquals(proposed.patch?.verification_unresolved_fields, ["rates:POTATO"]);
  assertEquals(proposed.patch?.verification_sources, undefined);
  const withLabel = master({ ...tebu, verification_sources: [{ kind: "manufacturer_label", name: "Label", reference: LABEL }],
    verification_unresolved_fields: ["activity_group:Tebuconazole", "rates:POTATO"] });
  assertEquals(isIncompleteMaster({ ...withLabel, ...buildMasterBackfillPatch(withLabel, authoritativeBackfillDetail(withLabel)).patch } as MasterRow), false);
  const mixture = master({ product_category: "fungicide", active_ingredients: [
    { name: "Tebuconazole", activity_group: { scheme: "frac", code: "3" } }, { name: "Azoxystrobin" }],
    activity_groups: ["3"], activity_group_scheme: "frac" });
  const merged = buildMasterBackfillPatch(mixture, authoritativeBackfillDetail(mixture));
  assertEquals(merged.patch?.activity_groups, ["3", "11"]);
  assertEquals(merged.patch?.resistance_classification_state, "classified");
});

Deno.test("vineyard gaps prune only evidenced markers; second pass stays stable", () => {
  const before = master({ registered_uses: [{ crop: "Grapevines", target: "weeds", rates: [] }],
    verification_unresolved_fields: ["rates:GRAPEVINE", "rates:GRAPE", "rates:POTATO", "label_reference"] });
  const first = buildMasterBackfillPatch(before, detail());
  assertEquals(first.patch?.verification_unresolved_fields, ["rates:POTATO"]);
  const after = { ...before, ...first.patch } as MasterRow;
  assertEquals(isIncompleteMaster(after), false);
  assertEquals(buildMasterBackfillPatch(after, detail()).patch, null);
});

Deno.test("partial bases and targets merge by rate id, preserving old values", () => {
  const spray = { ...rate, rate_id: "rate_v1_spray", basis: "per_100_litres", min_value: 100, max_value: 100, unit: "mL/100 L" };
  const old = master({ registered_uses: [{ crop: "Grapevines", target: "weeds", rates: [rate] }],
    viticulture_rates: { per_hectare: [rate], per_100_litres: [] }, label_rate_bases: ["range_per_hectare"] });
  const incoming = detail({ registered_uses: [{ crop: "Grapevines", target: "weeds", rates: [rate, spray] },
    { crop: "Grapevines", target: "second", direction_id: "direction_v1_second", rates: [{ ...rate, rate_id: "rate_v1_second" }] }] });
  const proposed = buildMasterBackfillPatch(old, incoming);
  assertEquals(proposed.patch?.viticulture_rates && (proposed.patch.viticulture_rates as { per_hectare: unknown[]; per_100_litres: unknown[] }).per_hectare.length, 2);
  assertEquals((proposed.patch?.viticulture_rates as { per_100_litres: unknown[] }).per_100_litres, [spray]);
  assertEquals((proposed.patch?.registered_uses as Array<{ rates: unknown[] }>)[0].rates, [rate, spray]);
  const after = { ...old, ...proposed.patch } as MasterRow;
  assertEquals(buildMasterBackfillPatch(after, incoming).patch, null);
  const contradiction = detail({ registered_uses: [{ crop: "Grapevines", target: "weeds", rates: [{ ...rate, max_value: 7 }] }] });
  assertEquals(buildMasterBackfillPatch(old, contradiction).status, "evidence_conflict");
});

Deno.test("WHP REI restrictions fill null but positive disagreements fail closed", () => {
  const enriched = detail({ registered_uses: [{ crop: "Grapevines", target: "weeds", rates: [rate],
    withholding_period_days: 14, withholding_period_text: "14 days", re_entry_period_hours: 12,
    re_entry_period_text: "12 hours", restrictions: "No entry until dry", statements: ["Keep away from waterways"],
    conditions: "Apply only to established vines" }] });
  const old = master({ registered_uses: [{ crop: "Grapevines", target: "weeds", rates: [rate],
    withholding_period_days: null, withholding_period_text: null, re_entry_period_hours: null,
    re_entry_period_text: null, restrictions: null, statements: null, conditions: null }] });
  const patch = buildMasterBackfillPatch(old, enriched).patch;
  const use = (patch?.registered_uses as Array<Record<string, unknown>>)[0];
  assertEquals(use.withholding_period_days, 14);
  assertEquals(use.re_entry_period_hours, 12);
  assertEquals(use.withholding_period_text, "14 days");
  assertEquals(use.re_entry_period_text, "12 hours");
  assertEquals(use.restrictions, "No entry until dry");
  assertEquals(use.statements, ["Keep away from waterways"]);
  assertEquals(use.conditions, "Apply only to established vines");
  assertEquals(buildMasterBackfillPatch({ ...old, ...patch } as MasterRow, enriched).patch, null);
  assertEquals(buildMasterBackfillPatch(master({ registered_uses: [{ ...old.registered_uses[0], withholding_period_days: 7 }] }), enriched).status, "evidence_conflict");
  assertEquals(buildMasterBackfillPatch(master({ registered_uses: [{ ...old.registered_uses[0], re_entry_period_hours: 24 }] }), enriched).status, "evidence_conflict");
  assertEquals(buildMasterBackfillPatch(master({ registered_uses: [{ ...old.registered_uses[0], restrictions: "Keep out" }] }), enriched).status, "evidence_conflict");
});

Deno.test("one pass closes classification, vineyard rates and label evidence; unrelated gaps do not repeat research", () => {
  const before = master({ registered_uses: [{ crop: "Grapevines", target: "weeds", rates: [] }],
    verification_unresolved_fields: ["activity_group:Glufosinate-ammonium", "rates:GRAPEVINE", "rates:POTATO"] });
  const first = buildMasterBackfillPatch(before, detail());
  assertEquals(first.status, "preview_ready");
  assertEquals(first.patch?.resistance_classification_state, "classified");
  assertEquals(first.patch?.activity_groups, ["10"]);
  assertEquals(first.patch?.viticulture_rates, { per_hectare: [rate], per_100_litres: [] });
  assertEquals(first.patch?.verification_unresolved_fields, ["rates:POTATO"]);
  assertEquals((first.patch?.verification_sources as Array<{ kind: string }>).at(-1)?.kind, "manufacturer_label");
  const after = { ...before, ...first.patch } as MasterRow;
  assertEquals(isIncompleteMaster(after), false);
  assertEquals(buildMasterBackfillPatch(after, detail()).status, "no_material_change");
  assertEquals(buildMasterBackfillPatch(after, detail()).patch, null);
});

Deno.test("unresolved vineyard markers need matching positive label evidence for each target", () => {
  const old = master({ active_ingredients: [active], activity_groups: ["10"], activity_group_scheme: "hrac",
    resistance_classification_state: "classified", registered_uses: [
      { crop: "Grapevines", target: "weeds", rates: [rate], withholding_period_days: 14 },
      { crop: "Grapevines", target: "mites", rates: [] }],
    viticulture_rates: { per_hectare: [rate], per_100_litres: [] },
    verification_unresolved_fields: ["rates:GRAPEVINE", "withholding_period:GRAPEVINE", "rates:POTATO"] });
  const partial = buildMasterBackfillPatch(old, detail({ registered_uses: [
    { crop: "Grapevines", target: "weeds", rates: [rate] }] }));
  assertEquals(partial.patch?.verification_unresolved_fields, undefined);
  const empty = buildMasterBackfillPatch(old, detail({ registered_uses: [] }));
  assertEquals(empty.patch?.verification_unresolved_fields, undefined);
  assertEquals(isIncompleteMaster(old), true);
  const noPositivePeriod = buildMasterBackfillPatch(old, detail({ registered_uses: [
    { crop: "Grapevines", target: "weeds", rates: [rate], withholding_period_days: 0,
      restrictions: [], statements: [] }] }));
  assertEquals(noPositivePeriod.patch?.verification_unresolved_fields, undefined);
  assertEquals((noPositivePeriod.patch?.registered_uses as Array<Record<string, unknown>> | undefined)?.[0].withholding_period_days, undefined);
});

Deno.test("manufacturer label cannot silently replace a stored active concentration unit", () => {
  const row = master({ active_ingredients: [{ name: active.name, concentration: 200, concentration_unit: "g/L" }] });
  const conflicting = detail({ active_ingredients: [{ ...active, concentration_unit: "mg/L", identity_source: "manufacturer_label" }] });
  assertEquals(buildMasterBackfillPatch(row, conflicting).status, "evidence_conflict");
});

Deno.test("store boundary rejects client identity and invalid structured fields", () => {
  assert(validateResolverPatch({ registration_number: "99999" }) !== null);
  assert(validateResolverPatch({ resistance_classification_state: "fabricated" }) !== null);
  assert(validateResolverPatch({ viticulture_rates: [] }) !== null);
  assert(validateResolverPatch({ activity_groups: [10] }) !== null);
});
