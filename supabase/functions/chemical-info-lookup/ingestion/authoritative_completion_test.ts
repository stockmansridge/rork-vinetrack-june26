import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { ResolvedRegistration } from "./contract.ts";
import { hasOfficialGrapevineRate } from "./authoritative_completion.ts";

const official59688 = {
  registration_number: "59688",
  label_text_extracted: true,
  label_document: { document: { sha256: "a".repeat(64), byte_size: 234237 } },
  label_evidence: { claims: [
    { crop: "BANANA", rates: [{ basis: "per_hectare", value: 1, unit: "kg" }] },
    { crop: "GRAPEVINE", target_raw: "Phomopsis Cane and Leaf spot", rates: [
      { basis: "range_per_100_litres", min_value: 150, max_value: 200, unit: "g", raw_text: "150 to 200 g" },
    ] },
  ] },
} as ResolvedRegistration;

Deno.test("59688 official PDF and bound grapevine rate bypass optional product research", () => {
  assertEquals(hasOfficialGrapevineRate(official59688), true);
});

Deno.test("unfetched, unparsed and grapevine-rate-free labels still request enrichment", () => {
  assertEquals(hasOfficialGrapevineRate({ ...official59688, label_text_extracted: false }), false);
  assertEquals(hasOfficialGrapevineRate({ ...official59688, label_document: null }), false);
  assertEquals(hasOfficialGrapevineRate({ ...official59688, label_evidence: {
    ...official59688.label_evidence!, claims: official59688.label_evidence!.claims.slice(0, 1),
  } }), false);
  assertEquals(hasOfficialGrapevineRate({ ...official59688, label_evidence: {
    ...official59688.label_evidence!, claims: [{ crop: "GRAPEVINE", target_raw: "Phomopsis", statements: [],
      rates: [{ label: "", basis: "range_per_100_litres", min_value: 150, max_value: 200,
        unit: "g", raw_text: "150 to 200 g", condition_ambiguous: true }] }],
  } }), false);
});
