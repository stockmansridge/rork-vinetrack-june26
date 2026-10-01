// deno-lint-ignore-file no-explicit-any require-await
// deno-lint-ignore no-import-prefix no-unversioned-import -- Reuse the repository's locked test assertion dependency.
import { assert, assertEquals } from "jsr:@std/assert";
import { APVMA_RESOURCES, clearApvmaCache } from "./apvma.ts";
import { buildCandidateRefreshPatch, buildRefreshPatch, refreshMasterRow } from "./refresh.ts";
import { buildMasterStructuredResponse, masterHasExactHydrationReadiness, resolveMasterLabelEvidence } from "./master_lookup.ts";
import { labelDocumentSource } from "./label_document.ts";
import { applyDefaultRateOptions } from "../default_rate_options.ts";

const fixture = JSON.parse(await Deno.readTextFile(new URL(
  "../../../../docs/weedmaster-acceptance/revision-2-shared/master-revision-2.sanitized-fixture.json", import.meta.url,
)));
const reviewedRow: any = fixture.row ?? fixture;
const NOW = "2026-10-01T18:00:00.000Z";
const manufacturer = reviewedRow.verification_sources[6];
const regulator = "https://elabels.apvma.gov.au/53576ELBL.pdf";

Deno.test("refresh evidence regression: real register refresh retains reviewed Nufarm evidence and operational identities", async () => {
  clearApvmaCache();
  const row = structuredClone(reviewedRow);
  const before = structuredClone(row);
  assert(masterHasExactHydrationReadiness(row));
  const requests: string[] = [];
  const fetchFn: typeof fetch = async (input) => {
    const url = new URL(String(input));
    requests.push(url.href);
    if (url.hostname !== "data.gov.au") return new Response("unavailable", { status: 503 });
    const resource = url.searchParams.get("resource_id");
    const records = resource === APVMA_RESOURCES.product ? [{ pcode: "53576",
      fpname: row.registered_product_name, sname: row.registrant, hlevel1: "HERBICIDE", fdesc: "SOLUBLE CONCENTRATE" }]
      : resource === APVMA_RESOURCES.labelRegistrations ? [{ pcode: "53576", regno: "999999", regdate: "1/10/2026" }]
      : [];
    return Response.json({ success: true, result: { records } });
  };
  const result = await refreshMasterRow(row, { fetchFn, now: () => new Date(NOW) });
  assertEquals(result.outcome, "material_change");
  assert(requests.some((url) => url.includes("data.gov.au")));
  assert(result.registration);
  // The register's independently confirmed eLabel is regulatory, never Nufarm evidence.
  result.registration.sources.push(labelDocumentSource("53576", { url: regulator,
    retrieved_at: NOW, confirmation: "document_fetch", document: { sha256: "a".repeat(64), byte_size: 100 } }));
  result.registration.label_document = { url: regulator, retrieved_at: NOW,
    confirmation: "document_fetch", document: { sha256: "a".repeat(64), byte_size: 100 } };
  // Register claim drift must not rebuild reviewed document directions or remove their IDs/rates.
  result.registration.label_evidence = { claims: row.registered_uses.map((use: any) =>
    ({ crop: use.crop, target_raw: use.target_raw, statements: [], rates: [] })), statements: [],
    sources: result.registration.sources, unresolved: ["rates:GRAPEVINE"],
    document: { url: regulator, sha256: "a".repeat(64), byte_size: 100, retrieved_at: NOW,
      extraction: "pdf_text_layer", parser_version: 1 } };
  result.changes.push({ field: "registered_uses", current: "Reviewed manufacturer directions", authoritative: "Register claim drift" });
  const patch = buildCandidateRefreshPatch(row, result, NOW);
  assert(patch);
  const after = { ...row, ...patch };
  assertEquals(after.verification_sources.find((source: any) => source.reference === manufacturer.reference), manufacturer);
  assertEquals(resolveMasterLabelEvidence(after).manufacturerSource, manufacturer);
  assert(after.verification_sources.some((source: any) => source.reference === regulator && source.kind === "regulator_label"));
  assert(after.verification_sources.some((source: any) => source.kind === "official_register" && source.retrieved_at === NOW));
  assertEquals(after.registered_uses, row.registered_uses);
  assertEquals(after.viticulture_rates, row.viticulture_rates);
  assert(masterHasExactHydrationReadiness(after));
  assertEquals(JSON.stringify(resolveMasterLabelEvidence(after).manufacturerSource?.reviewed_visual_declaration),
    JSON.stringify(manufacturer.reviewed_visual_declaration));
  assertEquals(after.label_version, "APVMA label approval 999999 (1/10/2026)");
  assertEquals(resolveMasterLabelEvidence(after).manufacturerSource?.reviewed_visual_declaration.document_version, "08-09-2022");
  assertEquals(after.source_kind, "official_register");
  assertEquals(after.source_reference, result.registration.sources[0].reference);
  assertEquals(after.label_reference, regulator);
  const served = buildMasterStructuredResponse(after);
  assertEquals(applyDefaultRateOptions(served), []);
  assertEquals([served.default_rate_options.per_hectare.length, served.default_rate_options.per_100_litres.length], [9, 8]);
  const phalaris = served.default_rate_options.per_100_litres.find((option: any) =>
    option.rate_ids.includes("rate_v1_4efec198ead373a3286939ced245fadf"));
  assertEquals([phalaris.min_value, phalaris.max_value, phalaris.unit, phalaris.basis], [500, 1000, "mL", "per_100_litres"]);
  assertEquals(phalaris.conditions, ["Handgun"]);
  assert(phalaris.targets.includes("Phalaris"));
  assert(phalaris.direction_ids.includes("direction_v1_1363f3205ca7b639cd5f970a03d91785"));
  assertEquals(row, before, "refresh and patch construction never mutate the input");
  for (const outcome of ["evidence_refreshed", "conflict"] as const) {
    const other = buildRefreshPatch(row, { ...result, outcome }, NOW);
    assertEquals(other?.verification_sources.find((source: any) => source.reference === manufacturer.reference), manufacturer);
  }
});
