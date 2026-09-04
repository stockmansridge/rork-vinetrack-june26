// deno-lint-ignore-file no-explicit-any no-import-prefix

import { assert, assertEquals } from "jsr:@std/assert@1";
import { applyDefaultRateOptions } from "./default_rate_options.ts";
import { projectGrapevineUses } from "./grapevine_label.ts";
import type { LabelDocumentDiscovery, LabelEvidence, LabelUseClaim } from "./ingestion/contract.ts";
import { GREENSHIELD_90279_ITEMS } from "./ingestion/label_fixture_90279.ts";
import { applyLabelDocumentExtraction } from "./ingestion/label_extract.ts";
import { mergeLabelEvidenceIntoUses } from "./ingestion/label.ts";
import { applyRateIdentities } from "./rate_identity.ts";
import { normaliseRegisteredUses } from "./registered_use_normaliser.ts";

const CLAIMS: LabelUseClaim[] = [
  { crop: "GRAPEVINE", target_raw: "BLACK SPOT", statements: [] },
  { crop: "GRAPEVINE", target_raw: "DOWNY MILDEW", statements: [] },
  { crop: "GRAPEVINE", target_raw: "PHOMOPSIS CANE AND LEAF SPOT", statements: [] },
];

const DOCUMENT: LabelDocumentDiscovery = {
  url: "https://elabels.apvma.gov.au/90279ELBL.pdf",
  confirmation: "pubcris_view_label",
  retrieved_at: "2026-09-04T00:00:00.000Z",
  document: { sha256: "7a94e4240000000000000000000000000000000000000000000000000000451e", byte_size: 1 },
};

function pipeline(): any {
  const evidence: LabelEvidence = {
    claims: CLAIMS,
    statements: [],
    sources: [],
    unresolved: ["rates:GRAPEVINE", "withholding_period:GRAPEVINE"],
  };
  const extracted = applyLabelDocumentExtraction(evidence, GREENSHIELD_90279_ITEMS, DOCUMENT);
  const registeredUses = normaliseRegisteredUses(mergeLabelEvidenceIntoUses([], extracted).uses);
  const projection = projectGrapevineUses(registeredUses);
  const structured: any = {
    registration: { country_code: "AU", scheme: "apvma", registration_number: "90279" },
    registered_uses: registeredUses,
    grapevine_uses: projection.grapevine_uses,
    other_crop_uses: projection.other_crop_uses,
    registered_for_grapevine: projection.registered_for_grapevine,
    label_reference_rate_ranges: projection.label_reference_rate_ranges,
    label_rate_bases: Array.from(new Set(registeredUses.flatMap((use: any) => use.rates.map((rate: any) => rate.basis)))),
  };
  applyRateIdentities(structured);
  applyDefaultRateOptions(structured);
  return structured;
}

Deno.test("Greenshield 90279 authoritative pipeline binds grapevine rates, WHP and stable identities", () => {
  const structured = pipeline();
  assertEquals(structured.registered_uses.length, 3);
  assertEquals(structured.grapevine_uses, structured.registered_uses);
  assertEquals(structured.other_crop_uses, []);
  assertEquals(structured.registered_for_grapevine, true);
  assertEquals(structured.label_reference_rate_ranges, []);
  assertEquals(structured.label_rate_bases, ["per_100_litres", "range_per_100_litres"]);

  const byTarget = (target: string): any =>
    structured.registered_uses.find((use: any) => use.target_raw.toLowerCase() === target.toLowerCase());
  for (const target of ["Black spot", "Downy mildew"]) {
    const use = byTarget(target);
    assert(use);
    assertEquals(use.rates[0].basis, "per_100_litres");
    assertEquals(use.rates[0].value, 200);
    assertEquals(use.rates[0].unit, "g");
    assertEquals(use.withholding_period_days, 30);
    assertEquals(use.provenance.rates, "manufacturer_label");
    assert(use.direction_id.startsWith("direction_v1_"));
    assert(use.rates[0].rate_id.startsWith("rate_v1_"));
  }

  const phomopsis = byTarget("Phomopsis Cane and Leaf spot");
  assert(phomopsis);
  assertEquals(phomopsis.rates[0].basis, "range_per_100_litres");
  assertEquals(phomopsis.rates[0].min_value, 150);
  assertEquals(phomopsis.rates[0].max_value, 200);
  assertEquals(phomopsis.rates[0].unit, "g");
  assertEquals(phomopsis.withholding_period_days, 30);
  assertEquals(phomopsis.provenance.rates, "manufacturer_label");

  const again = pipeline();
  assertEquals(
    again.registered_uses.map((use: any) => [use.direction_id, use.rates[0].rate_id]),
    structured.registered_uses.map((use: any) => [use.direction_id, use.rates[0].rate_id]),
  );
});

Deno.test("Greenshield 90279 defaults combine equal 200 g directions and retain the Phomopsis range", () => {
  const options = pipeline().default_rate_options.per_100_litres;
  assertEquals(options.length, 2);
  const amount = options.find((option: any) => option.value === 200);
  assertEquals(amount.targets, ["Black spot", "Downy mildew"]);
  assertEquals(amount.direction_ids.length, 2);
  assertEquals(amount.rate_ids.length, 2);
  const range = options.find((option: any) => option.min_value === 150);
  assertEquals(range.max_value, 200);
  assertEquals(range.targets, ["Phomopsis Cane and Leaf spot"]);
});
