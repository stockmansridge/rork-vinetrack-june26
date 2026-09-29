// Offline, non-writing replay. Run: deno run --allow-read --allow-write=.rork-tmp/weedmaster_replay_result.json --allow-run=python .rork-tmp/weedmaster_probe.ts
// Requires: python -m pip install --user pymupdf. Only the retained, hash-locked PDF is read.
import { selectAndFetchManufacturerLead, WEEDMASTER_LABEL_LEAD, WEEDMASTER_PRODUCT_PAGE } from "../supabase/functions/chemical-info-lookup/ingestion/documented_label_lead.ts";
import { labelApprovalIdentifiers } from "../supabase/functions/chemical-info-lookup/web_lookup.ts";
import { extractManufacturerDocumentText } from "../supabase/functions/chemical-info-lookup/ingestion/manufacturer_document.ts";
import { assembleTextLines, parseRateCell } from "../supabase/functions/chemical-info-lookup/ingestion/label_extract.ts";
import { extractManufacturerLabelUses } from "../supabase/functions/chemical-info-lookup/ingestion/manufacturer_label.ts";
import { lockedWebIdentity } from "../supabase/functions/chemical-info-lookup/ingestion/master_backfill.ts";
import { finishBackfillPreview, withIndexedDiagnostic } from "../supabase/functions/chemical-info-lookup/ingestion/master_backfill_preview.ts";
import { productPagesToInspect, resolveInitialManufacturerLeads } from "../supabase/functions/chemical-info-lookup/web_identity.ts";
import { inspectCandidateProductPages, privatePageFetchDiagnostic } from "../supabase/functions/chemical-info-lookup/research/page_inspector.ts";
import type { MasterRow } from "../supabase/functions/chemical-info-lookup/ingestion/contract.ts";

const bytes = await Deno.readFile(new URL("./weedmaster_duo_documented.pdf", import.meta.url));
const digest = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))).map((b) => b.toString(16).padStart(2, "0")).join("");
const expected = "69213c077e191e99682e515884d7667156367ea7ab927ecdac2882f4d0ec39b8";
if (digest !== expected) throw Error("retained PDF changed");
const items = await extractManufacturerDocumentText({ now: () => new Date(), fetchFn: (() => { throw Error("network forbidden"); }) as typeof fetch }, bytes);
if (!items?.length) throw Error("real document extraction failed");
const lines = assembleTextLines(items);
const text = lines.map((line) => line.text).join("\n");
const identifiers = labelApprovalIdentifiers(text, "AU");
if (JSON.stringify(identifiers.printed_values) !== JSON.stringify(["53576/136340"])) throw Error("printed approval not recovered");

// Independent physical-table reading from the SAME bytes. This is quarantined evidence,
// not a substitute for production parser output or a licence to bypass its identity gate.
const process = new Deno.Command("python", { args: [new URL("./weedmaster_tables.py", import.meta.url).pathname], stdout: "piped", stderr: "piped" });
const physical = await process.output();
if (!physical.success) throw Error(`physical-table extraction failed: ${new TextDecoder().decode(physical.stderr)}`);
type Table = { page: number; kind: "annual" | "perennial"; heading: unknown; rows: Array<Array<string | null>> };
const tables = JSON.parse(new TextDecoder().decode(physical.stdout)) as {
  sha256: string; physical_pages: number; page_1_text: string;
  vineyard: { physical_page: number; crop_cell: string; reference_cell: string; rate_cell: string | null; comments_cell: string };
  tables: Table[];
};
if (tables.sha256 !== digest || tables.page_1_text || tables.vineyard.rate_cell !== null) throw Error("PDF/table invariants changed");
const annual = tables.tables.find((table) => table.kind === "annual");
const perennial = tables.tables.filter((table) => table.kind === "perennial");
if (!annual || perennial.length !== 3) throw Error("referenced weed tables not uniquely located");
const annualRate = annual.rows.find((r) => r[3])?.[3] ?? "";
const annualComments = annual.rows.find((r) => r[4])?.[4] ?? "";
const weedTableCandidates = tables.tables.flatMap((table) => table.rows.map((row, index) => {
  const rawDose = table.kind === "annual" ? annualRate : row.slice(1, 4).filter(Boolean).join(" | ");
  const methods = table.kind === "annual"
    ? { boom: annualRate.match(/BOOM:\s*([\s\S]*?)HANDGUN:/i)?.[1]?.trim() ?? null,
        handgun: annualRate.match(/HANDGUN:\s*([\s\S]*?)KNAPSACK:/i)?.[1]?.trim() ?? null,
        knapsack: annualRate.match(/KNAPSACK:\s*([\s\S]*?)WIPER EQUIPMENT/i)?.[1]?.trim() ?? null,
        wiper: annualRate.match(/WIPER EQUIPMENT[\s\S]*/i)?.[0]?.trim() ?? null }
    : { boom: row[1], handgun: row[2], knapsack: row[3] };
  return { physical_page: table.page, row: index + (table.kind === "annual" ? 2 : 3), table: table.kind,
    target_weed: table.kind === "annual" ? row[1] : row[0], scientific_name: table.kind === "annual" ? row[2] : null,
    method_cells: methods, rate_cell: rawDose, parsed_rate_candidates: Object.entries(methods).map(([method, dose]) => ({
      method, verbatim: dose, parsed: dose ? parseRateCell(dose) : [],
    })), comments: table.kind === "annual" ? annualComments : row[4],
    binding_state: "quarantined: scope, continuation, method and crop binding unverified" };
})).filter((row) => row.target_weed);

// This row reproduces the locked fields observed previously, but is NOT asserted to be a
// complete database read. Never fill a missing field with invented production values.
const row = { id: "03dfb9e8-6592-4746-a3bc-295890d32cd1", registration_country: "AU", registration_scheme: "apvma", registration_number: "53576", registration_identity_key: "AU:apvma:53576", registered_product_name: "Nufarm Weedmaster DUO Herbicide", registrant: "NUFARM AUSTRALIA LIMITED", common_names: [], product_category: "herbicide", form_type: "liquid", active_ingredients: [{ name: "Glyphosate Present As The Isopropylamine And Mono-ammoni", concentration: 360, concentration_unit: "g/L" }], activity_groups: [], activity_group_scheme: null, resistance_classification_state: "unresolved", registered_uses: [], label_rate_bases: [], label_reference: null, label_version: null, verification_status: "partially_verified", verification_sources: [], verification_conflicts: [], verification_unresolved_fields: [], verified_at: null, source_kind: "official_register", source_reference: "pubcris:53576", retrieved_at: null, review_status: "approved", catalogue_version: 1, activity_group_table_version: 1, intelligence_schema_version: 1 } as MasterRow;
const before = JSON.stringify(row);
const identity = lockedWebIdentity(row);
if (!identity) throw Error("invalid locked identity");
const initial = await resolveInitialManufacturerLeads({ identity, country: row.registration_country, registrationIdentityKey: row.registration_identity_key, discover: () => { throw Error("paid discovery forbidden"); } });
const inspected = await inspectCandidateProductPages({ fetchFn: (() => { throw Error("product page request forbidden"); }) as typeof fetch }, productPagesToInspect(identity, initial.leads, initial.documentedLead), "AU");
const calls: string[] = [];
const result = await selectAndFetchManufacturerLead({
  deps: { now: () => new Date(), fetchFn: ((url: string | URL | Request) => {
    calls.push(String(url));
    if (String(url) !== WEEDMASTER_LABEL_LEAD) throw Error("unexpected network request");
    return Promise.resolve(new Response(bytes, { status: 200, headers: { "content-type": "application/pdf" } }));
  }) as typeof fetch },
  country: "AU", registrant: "NUFARM AUSTRALIA LIMITED", registeredProductName: "Nufarm Weedmaster DUO Herbicide",
  registrationNumber: "53576", activeNames: row.active_ingredients.map((active) => active.name),
  productPageUrl: initial.leads?.productUrl ?? null, documentedProductPageUrl: WEEDMASTER_PRODUCT_PAGE,
  linkedLabel: null, directCandidate: initial.leads?.labelUrl ?? null, storedLabelUrls: identity.labelUrls, documentedLead: initial.documentedLead, regulatorUses: [],
});
const e = result.enrichment;
if (calls.length !== 1 || e?.diagnostics.manufacturer_label_extract !== "failure") throw Error("gate unexpectedly changed");
const reason = e?.diagnostics.manufacturer_label_fetch_reason.includes("omits the active-constituent panel")
  ? "label_chemistry_text_unavailable" as const : "label_unreadable" as const;
const report = await finishBackfillPreview(row, "offline-replay", { discovery_reason: reason }, true, { insertPreview: () => { throw Error("preview write forbidden"); } });
const diagnostic = privatePageFetchDiagnostic(inspected.attempts, result.directLabel, true, result.candidateRejection, "not_attempted", { lead: result.documented.lead, identityMatched: initial.identityMatched, pairSupplied: !!initial.documentedLead, eligible: result.documented.eligible, rejection: result.documented.rejection, selected: result.documented.selected, fetchOutcome: e?.diagnostics.manufacturer_label_fetch_outcome ?? null, fetchHttpStatus: e?.diagnostics.manufacturer_label_http_status ?? null, extractOutcome: e?.diagnostics.manufacturer_label_extract ?? null, verified: false, identityMismatch: e?.diagnostics.identity_mismatch === true }, initial.discoveryOutcome);
if (JSON.stringify(row) !== before || report.proposed_patch !== null || report.preview_id !== null) throw Error("blocked preview unexpectedly mutated state");
const finalReport = withIndexedDiagnostic(report, true, null, diagnostic);
const evidence = { document_sha256: digest, item_count: items.length, physical_page_1: { extractable_text: tables.page_1_text,
  visual_review_only: "ACTIVE CONSTITUENT: 360 g/L GLYPHOSATE; present as the isopropylamine and mono-ammonium salts",
  image: ".rork-tmp/weedmaster_page_1.png", note: "Manual inspection of PDF page 1, orange band, left; NOT extracted by parser or automatically promoted." },
  product_page_chemistry: "Separate source; not requested or fetched in this replay and never attributed to PDF text layer.",
  approval: { physical_page: 15, ...identifiers },
  vineyard: tables.vineyard, general_restraints: lines.filter((line) => line.page === 2 && line.y > 350 && line.y < 385).map((line) => line.text),
  withholding: text.match(/WITHHOLDING PERIOD:\s*NOT REQUIRED WHEN USED AS DIRECTED/i)?.[0] ?? null,
  re_entry_period: null, re_entry_status: "not stated in extracted text; unresolved",
  production_parser: { ...(() => { const parsed = extractManufacturerLabelUses(items); return { found: parsed.found, rows: parsed.uses.length, vineyard_rows: parsed.uses.filter((use) => /grape|vineyard/i.test(use.crop)).length }; })() },
  quarantined_weed_table_candidates: weedTableCandidates,
  unresolved: ["page 1 chemistry is image-only; production text-layer gate cannot verify it", "production parser has no vineyard direction from referenced tables", "physical weed-table row spans and exceptions must be verified before crop/target/method/rate binding", "no stated re-entry period"] };
const output = { source: { product_page: WEEDMASTER_PRODUCT_PAGE, pdf: WEEDMASTER_LABEL_LEAD, sha256: digest, master_row_source: "locally reconstructed locked row; not a fresh DB read" }, initial, actual_enrichment_diagnostics: e?.diagnostics, evidence, report: finalReport, proposed_patch: finalReport.proposed_patch, preview_storage_disabled: true, master_unchanged: true };
await Deno.writeTextFile(new URL("./weedmaster_replay_result.json", import.meta.url), JSON.stringify(output, null, 2));
console.log(JSON.stringify({ result_file: ".rork-tmp/weedmaster_replay_result.json", report_status: finalReport.status, proposed_patch: finalReport.proposed_patch, approval: identifiers, weed_table_rows: weedTableCandidates.length, annual_targets: weedTableCandidates.filter((r) => r.table === "annual").length, perennial_targets: weedTableCandidates.filter((r) => r.table === "perennial").length, production_parser: evidence.production_parser, withholding: evidence.withholding, reason: e?.diagnostics.manufacturer_label_fetch_reason, writes: "no production/database/cache/preview writes" }, null, 2));
