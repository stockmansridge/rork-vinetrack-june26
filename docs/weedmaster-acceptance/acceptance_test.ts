import { assert, assertEquals } from "jsr:@std/assert";
import { selectAndFetchManufacturerLead, WEEDMASTER_LABEL_LEAD, WEEDMASTER_PRODUCT_PAGE } from "../../supabase/functions/chemical-info-lookup/ingestion/documented_label_lead.ts";
import { attestVisualDeclaration, verifyReviewedVisualDeclaration } from "../../supabase/functions/chemical-info-lookup/ingestion/reviewed_visual_evidence.ts";
import { extractManufacturerDocumentText } from "../../supabase/functions/chemical-info-lookup/ingestion/manufacturer_document.ts";
import { bindVineyardReferencedTables } from "../../supabase/functions/chemical-info-lookup/ingestion/vineyard_table_binding.ts";
import { normaliseRegisteredUses } from "../../supabase/functions/chemical-info-lookup/registered_use_normaliser.ts";
import { finishBackfillPreview } from "../../supabase/functions/chemical-info-lookup/ingestion/master_backfill_preview.ts";
import { labelApprovalIdentifiers } from "../../supabase/functions/chemical-info-lookup/web_lookup.ts";
import { assembleTextLines } from "../../supabase/functions/chemical-info-lookup/ingestion/label_extract.ts";
import type { MasterRow } from "../../supabase/functions/chemical-info-lookup/ingestion/contract.ts";

const pdf = await Deno.readFile(new URL("./weedmaster_duo_documented.pdf", import.meta.url));
const sha = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", pdf))).map((n) => n.toString(16).padStart(2, "0")).join("");
assertEquals(sha, "69213c077e191e99682e515884d7667156367ea7ab927ecdac2882f4d0ec39b8");
const active = { name: "Glyphosate Present As The Isopropylamine And Mono-ammoni", concentration: 360, concentration_unit: "g/L" };
const product = { country: "AU", scheme: "apvma", registration_number: "53576" };
const row = { id: "03dfb9e8-6592-4746-a3bc-295890d32cd1", registration_country: "AU", registration_scheme: "apvma", registration_number: "53576", registration_identity_key: "AU:apvma:53576", registered_product_name: "Nufarm Weedmaster DUO Herbicide", registrant: "NUFARM AUSTRALIA LIMITED", common_names: [], product_category: "herbicide", form_type: "liquid", active_ingredients: [active], activity_groups: [], activity_group_scheme: null, resistance_classification_state: "unresolved", registered_uses: [], label_rate_bases: [], label_reference: null, label_version: null, verification_status: "partially_verified", verification_sources: [], verification_conflicts: [], verification_unresolved_fields: [], verified_at: null, source_kind: "official_register", source_reference: "pubcris:53576", retrieved_at: null, review_status: "approved", catalogue_version: 1, activity_group_table_version: 1, intelligence_schema_version: 1 } as MasterRow;
const candidate = { document_sha256: sha, source_url: WEEDMASTER_LABEL_LEAD, physical_page: 1,
  location: "orange band, upper left of physical PDF cover", verbatim: "ACTIVE CONSTITUENT: 360 g/L GLYPHOSATE present as the isopropylamine and mono-ammonium salts",
  active: { name: "GLYPHOSATE", salt_form: "isopropylamine and mono-ammonium salts", concentration: 360, unit: "g/L" },
  formulation: "SL soluble concentrate", method: "human_visual_transcription", document_version: "08-09-2022", confirm_review: true };
// A TEST-ONLY hypothetical authenticated admin, NOT a real Weedmaster sign-off.
const attested = attestVisualDeclaration(candidate, "synthetic-test-admin", new Date("2026-09-29T00:00:00Z"));
assert(attested);
const deps = (bytes: Uint8Array) => ({ now: () => new Date(), fetchFn: ((url: string | URL | Request) => {
  if (String(url) !== WEEDMASTER_LABEL_LEAD) throw Error("unexpected network");
  return Promise.resolve(new Response(new Uint8Array(bytes).buffer, { status: 200, headers: { "content-type": "application/pdf" } }));
}) as typeof fetch });
const run = async (bytes: Uint8Array, declaration: typeof attested | null) => selectAndFetchManufacturerLead({
  deps: deps(bytes), country: "AU", registrant: row.registrant ?? "", registeredProductName: row.registered_product_name,
  registrationNumber: "53576", activeNames: [active.name], lockedActives: [active], lockedFormType: "liquid",
  reviewedVisualDeclaration: declaration, productPageUrl: WEEDMASTER_PRODUCT_PAGE,
  documentedProductPageUrl: WEEDMASTER_PRODUCT_PAGE, linkedLabel: null, directCandidate: null,
  storedLabelUrls: [], documentedLead: WEEDMASTER_LABEL_LEAD, regulatorUses: [],
});
Deno.test("actual PDF: unreviewed, changed bytes and conflicting chemistry never promote", async () => {
  assertEquals(attestVisualDeclaration({ ...candidate, confirm_review: false }, "synthetic-test-admin", new Date()), null);
  assertEquals(attestVisualDeclaration(candidate, "", new Date()), null);
  const missing = await run(pdf, null);
  assertEquals(missing.enrichment?.diagnostics.manufacturer_label_extract, "failure");
  const changed = await run(new Uint8Array([...pdf, 32]), attested);
  assertEquals(changed.enrichment?.diagnostics.manufacturer_label_fetch_reason, "visual_document_changed");
  const conflict = attestVisualDeclaration({ ...candidate, active: { ...candidate.active, salt_form: "sodium salts" } }, "synthetic-test-admin", new Date());
  const mismatch = await run(pdf, conflict);
  assertEquals(mismatch.enrichment?.diagnostics.manufacturer_label_fetch_reason, "visual_declaration_inconsistent");
  const verify = (evidence: typeof attested, formType: string) => verifyReviewedVisualDeclaration({
    evidence, fetchedSha256: sha, fetchedUrl: WEEDMASTER_LABEL_LEAD,
    lockedActives: [active], lockedFormType: formType, printedApprovalNumbers: ["53576"],
    lockedRegistrationNumber: "53576", printedDocumentVersion: "08-09-2022",
  });
  assertEquals(verify(attested, "solid").reason, "visual_formulation_conflict");
  assertEquals(verify({ ...attested, document_version: null }, "liquid").reason, "visual_document_version_conflict");
  assertEquals(verifyReviewedVisualDeclaration({ evidence: attested, fetchedSha256: sha, fetchedUrl: WEEDMASTER_LABEL_LEAD,
    lockedActives: [{ ...active, concentration: 450 }], lockedFormType: "liquid", printedApprovalNumbers: ["53576"], lockedRegistrationNumber: "53576", printedDocumentVersion: "08-09-2022" }).reason, "visual_chemistry_conflict");
});
Deno.test("actual PDF: hypothetical signed review travels through production lead, parser, normaliser, patch and dry report", async () => {
  const items = await extractManufacturerDocumentText({ now: () => new Date(), fetchFn: (() => { throw Error("network"); }) as typeof fetch }, pdf);
  assert(items);
  const identifiers = labelApprovalIdentifiers(assembleTextLines(items).map((line) => line.text).join("\n"), "AU");
  assertEquals(identifiers.printed_values, ["53576/136340"]);
  const binding = bindVineyardReferencedTables(items, product, "WITHHOLDING PERIOD: NOT REQUIRED WHEN USED AS DIRECTED");
  assert(binding.uses.length > 0, JSON.stringify(binding.unresolved));
  const result = await run(pdf, attested);
  assertEquals(result.enrichment?.diagnostics.manufacturer_label_extract, "success");
  assert(result.enrichment?.reviewedVisualDeclaration);
  const uses = normaliseRegisteredUses(result.enrichment?.uses);
  assert(uses.length > 0);
  assert(uses.some((use) => use.rates.some((rate: { basis: string }) => rate.basis.includes("hectare"))));
  assert(uses.some((use) => use.rates.some((rate: { basis: string }) => rate.basis.includes("100_litres"))));
  assert(uses.every((use) => use.withholding_statement === "WITHHOLDING PERIOD: NOT REQUIRED WHEN USED AS DIRECTED" &&
    use.withholding_period_days === null && use.re_entry_period_hours === null &&
    use.source_refs?.[0]?.includes("page 9") && !/Tea: Apply/.test(use.restrictions)));
  assert(uses.some((use) => use.rates.some((rate: { basis: string; raw_text: string; label: string }) =>
    rate.basis === "other" && /mL\/15L/.test(rate.raw_text) && rate.label === "Knapsack")));
  assert(uses.some((use) => use.rates.some((rate: { label: string }) => rate.label === "Boom")));
  assert(uses.some((use) => use.rates.some((rate: { label: string }) => rate.label === "Handgun")));
  assert(uses.every((use) => /fresh wounds, foliage or fruit/.test(use.restrictions)));
  const before = JSON.stringify(row);
  const report = await finishBackfillPreview(row, "synthetic-test-admin", { detail: {
    registration: { registration_number: "53576", manufacturer_label_url: WEEDMASTER_LABEL_LEAD,
      manufacturer_label_verified: true, manufacturer_label_identifiers: identifiers,
      reviewed_visual_declaration: result.enrichment!.reviewedVisualDeclaration }, registered_uses: uses,
    verification: { unresolved_fields: result.enrichment?.diagnostics.vineyard_binding_unresolved ?? [] } } }, true,
    { insertPreview: () => { throw Error("preview write forbidden"); } });
  assertEquals(report.status, "preview_ready", JSON.stringify(report.evidence));
  // Assert the FINAL serialised review payload, not merely parser fragments.
  const serialised = JSON.parse(JSON.stringify(report.proposed_patch)) as {
    registered_uses: Array<{ target_raw: string; restrictions: string; conditions: string; direction_id: string; source_refs: string[];
      withholding_statement: string; re_entry_period_hours: number | null;
      rates: Array<{ label: string; basis: string; value: number | null; min_value: number | null;
        max_value: number | null; unit: string; raw_text: string; rate_id: string; source_refs: string[] }> }>;
    verification_unresolved_fields: string[];
  };
  const expectedRestraints = [
    "DO NOT disturb treated weeds by cultivation, sowing or grazing for 1 day after treatment of annual weeds and 7 days for perennial weeds.",
    "DO NOT treat weeds under poor growing or dormant conditions such as occur in drought, water logging, disease, insect damage or following frost. Reduced control may also occur when treating weeds heavily covered with dust or silt.",
    "Rainfall occurring up to 6 hours after application may reduce effectiveness. Heavy rainfall within 2 hours of application may wash the chemical off the foliage and a repeat treatment may be required.",
  ];
  assert(serialised.registered_uses.length > 35);
  for (const use of serialised.registered_uses) {
    for (const statement of expectedRestraints) assert(use.restrictions.includes(statement), `${use.target_raw}: ${statement}`);
    assert(!/\buse prior to sowing tomatoes\b/i.test(use.restrictions));
    assert(!/\bTea: Apply|All other crops:|CONSERVATION TILLAGE USES|TANK MIXTURES/.test(use.restrictions));
    assert(use.direction_id?.startsWith("direction_v1_") && use.rates.every((r) => r.rate_id?.startsWith("rate_v1_")));
    assertEquals(use.re_entry_period_hours, null);
    assertEquals(use.withholding_statement, "WITHHOLDING PERIOD: NOT REQUIRED WHEN USED AS DIRECTED");
  }
  const lookup = (target: string) => serialised.registered_uses.find((use) => use.target_raw === target);
  assert(lookup("Bent grass")?.conditions.includes("Full disturbance with a tyned implement should follow, 10-21 days after spraying."));
  assert(lookup("Sedge, tall")?.conditions.includes("Use of CDA equipment is not recommended."));
  assert(lookup("Nutgrass")?.conditions.includes("NON-CULTIVATED SITUATIONS:"));
  assert(!lookup("Nutgrass")?.conditions.includes("ARABLE LAND:"));
  assertEquals(lookup("Paspalum"), undefined, "no invented continuation comments");
  assertEquals(lookup("Alligator weed"), undefined, "floating-only weed is not a Vineyard direction");
  assert(!lookup("Sorrel")?.conditions.includes("Conservation Tillage"));
  assert(!lookup("Soursob")?.conditions.includes("Conservation Tillage"));
  for (const target of ["Amaranth", "Bent grass", "Sedge, tall"]) {
    const rates = lookup(target)?.rates ?? [];
    assert(rates.some((r) => r.basis.includes("hectare") && r.label.startsWith("Boom")), `${target} boom`);
    assert(rates.some((r) => r.basis.includes("100_litres") && r.label.startsWith("Handgun")), `${target} handgun`);
  }
  const wiper = lookup("Amaranth")?.rates.find((r) => r.label === "Wiper");
  assertEquals(wiper?.basis, "other");
  assert(wiper?.raw_text.startsWith("RATE: Mix 1 L of this product with 2 L clean water to prepare 33% solution."));
  assert(wiper?.source_refs.some((ref) => ref.includes("page 13 APPLICATION")));
  assert(wiper?.raw_text.includes("DO NOT store mixed solution for more than a few days. Flush out equipment with water after use."));
  assert(wiper?.raw_text.includes("Operate wiper equipment a minimum of 10 cm above the crop or pasture."));
  assert(!wiper?.raw_text.includes("oilseed crops"), "do not inherit unrelated crop permissions");
  assert(!lookup("Kangaroo grass")?.rates.some((r) => r.label === "Wiper"));
  assert(!lookup("Kikuyu grass")?.rates.some((r) => r.label === "Wiper"));
  assert(!lookup("Kangaroo grass")?.conditions.includes("Johnson grass"));
  assert(lookup("Johnson grass")?.rates.some((r) => r.label === "Wiper"));
  assert(!serialised.registered_uses.some((use) => use.rates.some((r) => r.label === "Wiper" && r.basis !== "other")));
  assert(serialised.verification_unresolved_fields.some((field) => field.includes("re_entry_period:GRAPEVINE")));
  assert(serialised.verification_unresolved_fields.some((field) => field.includes("Paspalum")));
  assert(report.proposed_patch?.viticulture_rates);
  assertEquals(report.proposed_patch.label_version, "08-09-2022");
  if (report.proposed_patch.active_ingredients) {
    const after = (report.proposed_patch.active_ingredients as Array<Record<string, unknown>>)[0];
    assertEquals(after.name, active.name);
    assertEquals(after.concentration, active.concentration);
    assertEquals(after.concentration_unit, active.concentration_unit);
    assertEquals(after.identity_source, undefined, "no visual identity replaces the stored register provenance");
  }
  const rates = report.proposed_patch.viticulture_rates as { per_hectare: Array<Record<string, unknown>>; per_100_litres: Array<Record<string, unknown>> };
  assert(rates.per_hectare.length > 0 && rates.per_100_litres.length > 0);
  const phalaris = lookup("Phalaris");
  assert(phalaris);
  const handgun = phalaris.rates.filter((rate) => rate.label === "Handgun");
  assertEquals(handgun.length, 1);
  const flat = rates.per_100_litres.filter((rate) =>
    (rate.source_refs as string[])?.some((ref) => ref.endsWith(", Phalaris")));
  assertEquals(flat.length, 1);
  const expectedRate = { label: "Handgun", basis: "range_per_100_litres", value: null,
    min_value: 500, max_value: 1000, unit: "mL", raw_text: "500 mL-1 L/100L",
    rate_id: "rate_v1_4efec198ead373a3286939ced245fadf" };
  for (const rate of [handgun[0], flat[0]]) {
    for (const [key, value] of Object.entries(expectedRate))
      assertEquals((rate as Record<string, unknown>)[key], value, `Phalaris ${key}`);
    assertEquals(rate.source_refs, phalaris.source_refs);
  }
  assertEquals(phalaris.direction_id, "direction_v1_1363f3205ca7b639cd5f970a03d91785");
  assertEquals(rates.per_100_litres.filter((rate) =>
    (rate.source_refs as string[])?.some((ref) => ref.endsWith(", Phalaris"))).length, 1);
  assert(rates.per_hectare.concat(rates.per_100_litres).every((rate) =>
    ["per_hectare", "range_per_hectare", "per_100_litres", "range_per_100_litres"].includes(String(rate.basis))));
  assert(!rates.per_hectare.concat(rates.per_100_litres).some((rate) =>
    ["Knapsack", "Wiper"].includes(String(rate.label))));
  assert(uses.some((use) => use.crop === "Vineyards" && String(use.source_refs?.[0]).includes("Table 3")));
  assert(uses.every((use) => !String(use.restrictions).includes("Tea: Apply a maximum")));
  assertEquals((report.proposed_patch.verification_sources as Array<Record<string, unknown>>)[0].reviewed_visual_declaration, attested);
  assertEquals(report.preview_id, null);
  assertEquals(JSON.stringify(row), before);
  const exportPath = new URL("./synthetic_review_simulation.json", import.meta.url);
  const baselineCommand = new Deno.Command("git", { args: ["show", "8d1fd4ab256c8699126c0e4f9ca3252a68ada1a9:docs/weedmaster-acceptance/synthetic_review_simulation.json"] });
  const baselineOutput = await baselineCommand.output();
  assert(baselineOutput.success, "prior committed acceptance output unavailable");
  const baseline = JSON.parse(new TextDecoder().decode(baselineOutput.stdout)) as Record<string, unknown>;
  const refreshed: Record<string, unknown> = {
    WARNING: "Test-only synthetic reviewer. NOT an actual review, production preview, or approved Master patch.",
    master_row_source: "locally reconstructed locked row; not a fresh DB read",
    document_sha256: sha, unresolved: binding.unresolved, reconciliation: binding.reconciliation,
    report, proposed_patch: report.proposed_patch, preview_storage_disabled: true, master_unchanged: true,
  };
  type Difference = { path: string; before: unknown; after: unknown };
  const differences: Difference[] = [];
  function compare(oldValue: unknown, newValue: unknown, path: string): void {
    if (JSON.stringify(oldValue) === JSON.stringify(newValue)) return;
    if (oldValue !== null && newValue !== null && typeof oldValue === "object" && typeof newValue === "object") {
      const oldFields = oldValue as Record<string, unknown>;
      const newFields = newValue as Record<string, unknown>;
      for (const key of new Set([...Object.keys(oldFields), ...Object.keys(newFields)]))
        compare(oldFields[key], newFields[key], `${path}.${key}`);
      return;
    }
    differences.push({ path, before: oldValue ?? null, after: newValue ?? null });
  }
  compare(baseline, refreshed, "synthetic");
  const priorPatch = baseline.proposed_patch as { registered_uses: typeof serialised.registered_uses;
    viticulture_rates: { per_100_litres: Array<Record<string, unknown>> } };
  const priorPhalaris = priorPatch.registered_uses.find((use) => use.target_raw === "Phalaris");
  const priorHandgun = priorPhalaris?.rates.find((rate) => rate.label === "Handgun");
  assert(priorHandgun);
  assertEquals([priorHandgun.basis, priorHandgun.value, priorHandgun.min_value, priorHandgun.max_value, priorHandgun.unit, priorHandgun.rate_id],
    ["per_100_litres", 1, null, null, "L", "rate_v1_1404224e824789a20ca4dd4186bf1a0b"]);
  const allowedFields = new Set(["basis", "value", "min_value", "max_value", "unit", "rate_id"]);
  const allowedPaths = new Set<string>();
  for (const root of ["synthetic.report.proposed_patch", "synthetic.proposed_patch"]) {
    const useIndex = priorPatch.registered_uses.findIndex((use) => use.target_raw === "Phalaris");
    const rateIndex = priorPatch.registered_uses[useIndex].rates.findIndex((rate) => rate.label === "Handgun");
    const flatIndex = priorPatch.viticulture_rates.per_100_litres.findIndex((rate) =>
      (rate.source_refs as string[])?.some((ref) => ref.endsWith(", Phalaris")));
    assert(useIndex >= 0 && rateIndex >= 0 && flatIndex >= 0);
    for (const field of allowedFields) {
      allowedPaths.add(`${root}.registered_uses.${useIndex}.rates.${rateIndex}.${field}`);
      allowedPaths.add(`${root}.viticulture_rates.per_100_litres.${flatIndex}.${field}`);
    }
  }
  assertEquals(new Set(differences.map((difference) => difference.path)), allowedPaths,
    "only the two serialized Phalaris rate projections may differ from the prior acceptance output");
  assertEquals(baseline.unresolved, refreshed.unresolved);
  assertEquals(baseline.reconciliation, refreshed.reconciliation);
  assertEquals(report.preview_id, null);
  const comparison = {
    WARNING: "Synthetic non-writing comparison only; no real reviewer attestation or approved Master patch.",
    baseline_commit: "8d1fd4ab256c8699126c0e4f9ca3252a68ada1a9",
    document_sha256: sha, registration_identity_key: report.registration_identity_key,
    target: "Phalaris", method: "Handgun", direction_id: phalaris.direction_id,
    rate_id_before: priorHandgun.rate_id, rate_id_after: handgun[0].rate_id,
    expected_rate_and_identity_changes: differences,
    unrelated_changes: [], unresolved_exceptions_unchanged: true,
    reconciliation_unchanged: true, unsupported_methods_in_calculator: false,
    preview_storage_disabled: true, master_unchanged: true,
  };
  if (Deno.permissions.querySync({ name: "write", path: exportPath }).state === "granted") {
    await Deno.writeTextFile(exportPath, JSON.stringify(refreshed, null, 2) + "\n");
    await Deno.writeTextFile(new URL("./synthetic_rate_comparison.json", import.meta.url), JSON.stringify(comparison, null, 2) + "\n");
  }
});

Deno.test("referenced perennial rows reconcile against independent PDF tables; damaged source cannot pass binding", async () => {
  const items = await extractManufacturerDocumentText({ now: () => new Date(),
    fetchFn: (() => { throw Error("network forbidden"); }) as typeof fetch }, pdf);
  assert(items);
  const binding = bindVineyardReferencedTables(items, product, "WITHHOLDING PERIOD: NOT REQUIRED WHEN USED AS DIRECTED");
  const physical = await new Deno.Command("python", { args: [new URL("./tables.py", import.meta.url).pathname] }).output();
  assert(physical.success, new TextDecoder().decode(physical.stderr));
  const evidence = JSON.parse(new TextDecoder().decode(physical.stdout)) as {
    sha256: string; tables: Array<{ kind: string; page: number; rows: Array<Array<string | null>> }>;
  };
  assertEquals(evidence.sha256, sha);
  for (const table of evidence.tables.filter((entry) => entry.kind === "perennial")) {
    for (const cells of table.rows) {
      const firstName = String(cells[0] ?? "").split("\n")[0].replace(/\^$/, "").replace(/\s*\(.*/, "").trim();
      assert(binding.reconciliation.some((entry) => entry.page === table.page && (entry.target === firstName || entry.target.startsWith(`${firstName} (`))),
        `No mapped, excluded or specifically unresolved decision for page ${table.page}: ${firstName}`);
    }
  }
  assert(binding.reconciliation.some((entry) => entry.target === "Paspalum" && entry.state === "unresolved" && entry.reason.includes("6 L/ha") && entry.reason.includes("preceding Paragrass")));
  const repeated = bindVineyardReferencedTables(items, product, "WITHHOLDING PERIOD: NOT REQUIRED WHEN USED AS DIRECTED");
  assertEquals(binding.uses.map((use) => [use.direction_id, (use.rates as Array<{ rate_id: string }>).map((rate) => rate.rate_id)]),
    repeated.uses.map((use) => [use.direction_id, (use.rates as Array<{ rate_id: string }>).map((rate) => rate.rate_id)]));
  assert(binding.reconciliation.some((entry) => entry.target === "Cumbungi^" && entry.state === "unresolved"));
  assert(binding.reconciliation.some((entry) => entry.target === "Phragmites, Common reed" && entry.state === "unresolved"));
  assert(binding.reconciliation.some((entry) => entry.target === "Alligator weed" && entry.state === "excluded"));
  for (const y of [375.2, 368, 353.6]) {
    const damaged = items.filter((item) => !(item.page === 2 && item.x < 9 && Math.abs(item.y - y) < 0.5 && item.str === "DO NOT"));
    const rejected = bindVineyardReferencedTables(damaged, product, null);
    assertEquals(rejected.uses.length, 0, `missing DO NOT at y=${y} must not promote corrupted directions`);
    assert(rejected.unresolved.includes("general_restraint_complete_lines_unconfirmed"));
  }
  const missingWiperRate = items.filter((item) => !(item.page === 13 && item.str.startsWith("RATE: Mix 1 L of this product with 2 L")));
  assertEquals(bindVineyardReferencedTables(missingWiperRate, product, null).uses.length, 0);
});
