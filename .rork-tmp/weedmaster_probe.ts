import { selectAndFetchManufacturerLead, WEEDMASTER_LABEL_LEAD, WEEDMASTER_PRODUCT_PAGE } from "../supabase/functions/chemical-info-lookup/ingestion/documented_label_lead.ts";
import { labelApprovalIdentifiers, labelHeaderFacts } from "../supabase/functions/chemical-info-lookup/web_lookup.ts";
import { extractManufacturerDocumentText } from "../supabase/functions/chemical-info-lookup/ingestion/manufacturer_document.ts";
import { assembleTextLines } from "../supabase/functions/chemical-info-lookup/ingestion/label_extract.ts";
import { lockedWebIdentity } from "../supabase/functions/chemical-info-lookup/ingestion/master_backfill.ts";
import { finishBackfillPreview, withIndexedDiagnostic } from "../supabase/functions/chemical-info-lookup/ingestion/master_backfill_preview.ts";
import { productPagesToInspect, resolveInitialManufacturerLeads } from "../supabase/functions/chemical-info-lookup/web_identity.ts";
import { inspectCandidateProductPages, privatePageFetchDiagnostic } from "../supabase/functions/chemical-info-lookup/research/page_inspector.ts";
import type { MasterRow } from "../supabase/functions/chemical-info-lookup/ingestion/contract.ts";
import { extractManufacturerLabelUses, manufacturerUsesToRegisteredUses } from "../supabase/functions/chemical-info-lookup/ingestion/manufacturer_label.ts";
const bytes = await Deno.readFile(new URL("./weedmaster_duo_documented.pdf", import.meta.url));
const items = await extractManufacturerDocumentText({ now: () => new Date(), fetchFn: (() => { throw Error("no network"); }) as typeof fetch }, bytes);
const text = assembleTextLines(items ?? []).map((line) => line.text).join("\n");
console.log(JSON.stringify({ items: items?.length, textLength: text.length, chemistry: { exactStoredName: text.toLowerCase().includes("glyphosate present as the isopropylamine and mono-ammoni"), isopropylamine: text.toLowerCase().includes("isopropylamine"), monoammonium: /mono[- ]?ammoni/i.test(text), activeConstituent: /active\s+constituent/i.test(text), concentration360: /\b360\s*g\s*\/\s*l\b/i.test(text) }, passages: ["Vineyards", "WITHHOLDING PERIOD:", "RE-ENTRY", "53576", "NUFARM AUSTRALIA LIMITED"].map((term) => { const i = text.toUpperCase().indexOf(term.toUpperCase()); return { term, index: i, excerpt: i < 0 ? null : text.slice(Math.max(0, i - 500), i + 1200) }; }), facts: labelHeaderFacts(text), identifiers: labelApprovalIdentifiers(text, "AU") }, null, 2));
const parsed = extractManufacturerLabelUses(items ?? []);
const projected = manufacturerUsesToRegisteredUses(parsed.uses, { withholdingPeriodDays: null, reEntryPeriodHours: null, product: { country: "AU", scheme: "apvma", registration_number: "53576" } });
console.log(JSON.stringify({ parser: { found: parsed.found, rows: parsed.uses.length, vineRows: projected.filter((use) => /grape|vineyard|vine/i.test(String(use.crop ?? ""))) }, vineyardContext: text.slice(30800, 33200), registrationRaw: text.slice(-110), localChemistrySearched: true }, null, 2));
const row = { id: "03dfb9e8-6592-4746-a3bc-295890d32cd1", registration_country: "AU", registration_scheme: "apvma", registration_number: "53576", registration_identity_key: "AU:apvma:53576", registered_product_name: "Nufarm Weedmaster DUO Herbicide", registrant: "NUFARM AUSTRALIA LIMITED", common_names: [], product_category: "herbicide", form_type: "liquid", active_ingredients: [{ name: "Glyphosate Present As The Isopropylamine And Mono-ammoni", concentration: 360, concentration_unit: "g/L" }], activity_groups: [], activity_group_scheme: null, resistance_classification_state: "unresolved", registered_uses: [], label_rate_bases: [], label_reference: null, label_version: null, verification_status: "partially_verified", verification_sources: [], verification_conflicts: [], verification_unresolved_fields: [], verified_at: null, source_kind: "official_register", source_reference: "pubcris:53576", retrieved_at: null, review_status: "approved", catalogue_version: 1, activity_group_table_version: 1, intelligence_schema_version: 1 } as MasterRow;
const before = JSON.stringify(row);
const identity = lockedWebIdentity(row);
if (!identity) throw Error("invalid locked identity");
const initial = await resolveInitialManufacturerLeads({ identity, country: row.registration_country, registrationIdentityKey: row.registration_identity_key, discover: () => { throw Error("unexpected paid discovery"); } });
const inspected = await inspectCandidateProductPages({ fetchFn: (() => { throw Error("unexpected page request"); }) as typeof fetch }, productPagesToInspect(identity, initial.leads, initial.documentedLead), "AU");
const calls: string[] = [];
const result = await selectAndFetchManufacturerLead({
  deps: { now: () => new Date(), fetchFn: ((url: string | URL | Request) => {
    calls.push(String(url));
    if (String(url) !== WEEDMASTER_LABEL_LEAD) throw Error("unexpected network request");
    return Promise.resolve(new Response(bytes, { status: 200, headers: { "content-type": "application/pdf" } }));
  }) as typeof fetch },
  country: "AU", registrant: "NUFARM AUSTRALIA LIMITED", registeredProductName: "Nufarm Weedmaster DUO Herbicide",
  registrationNumber: "53576", activeNames: ["Glyphosate Present As The Isopropylamine And Mono-ammoni"],
  productPageUrl: initial.leads?.productUrl ?? null, documentedProductPageUrl: WEEDMASTER_PRODUCT_PAGE,
  linkedLabel: null, directCandidate: initial.leads?.labelUrl ?? null, storedLabelUrls: identity.labelUrls, documentedLead: initial.documentedLead, regulatorUses: [],
});
const e = result.enrichment;
const reason = e?.diagnostics.manufacturer_label_fetch_reason.includes("identity") ? "product_name_mismatch" : "label_unreadable";
const report = await finishBackfillPreview(row, "offline-replay", { discovery_reason: reason }, true, { insertPreview: () => { throw Error("unexpected preview write"); } });
const diagnostic = privatePageFetchDiagnostic(inspected.attempts, result.directLabel, true, result.candidateRejection, "not_attempted", { lead: result.documented.lead, identityMatched: initial.identityMatched, pairSupplied: !!initial.documentedLead, eligible: result.documented.eligible, rejection: result.documented.rejection, selected: result.documented.selected, fetchOutcome: e?.diagnostics.manufacturer_label_fetch_outcome ?? null, fetchHttpStatus: e?.diagnostics.manufacturer_label_http_status ?? null, extractOutcome: e?.diagnostics.manufacturer_label_extract ?? null, verified: false, identityMismatch: e?.diagnostics.identity_mismatch === true }, initial.discoveryOutcome);
if (JSON.stringify(row) !== before) throw Error("Master row mutated");
console.log(JSON.stringify({ initial, pageAttempts: inspected.attempts, calls, diagnostic, report: withIndexedDiagnostic(report, true, null, diagnostic), previewStorageDisabled: true, masterUnchanged: true }, null, 2));
