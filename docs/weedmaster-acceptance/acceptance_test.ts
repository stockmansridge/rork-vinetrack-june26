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
  assert(uses.some((use) => use.crop === "Vineyards" && String(use.source_refs?.[0]).includes("Table 3")));
  assert(uses.every((use) => !String(use.restrictions).includes("Tea: Apply a maximum")));
  assertEquals((report.proposed_patch.verification_sources as Array<Record<string, unknown>>)[0].reviewed_visual_declaration, attested);
  assertEquals(report.preview_id, null);
  assertEquals(JSON.stringify(row), before);
  const exportPath = new URL("./synthetic_review_simulation.json", import.meta.url);
  if (Deno.permissions.querySync({ name: "write", path: exportPath }).state === "granted")
    await Deno.writeTextFile(exportPath, JSON.stringify({
      WARNING: "Test-only synthetic reviewer. NOT an actual review, production preview, or approved Master patch.",
      master_row_source: "locally reconstructed locked row; not a fresh DB read",
      document_sha256: sha, unresolved: binding.unresolved,
      report, proposed_patch: report.proposed_patch, preview_storage_disabled: true, master_unchanged: true,
    }, null, 2));
});
