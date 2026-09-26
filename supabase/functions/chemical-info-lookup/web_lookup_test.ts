import { assertEquals } from "jsr:@std/assert";
import { agriculturalWebCandidates, labelApprovalNumber, labelHeaderFacts, readLabelWithResearchSchema, readableV2Label, supportedWebResearch } from "./web_lookup.ts";
import type { ManufacturerEnrichmentResult } from "./ingestion/manufacturer_enrichment.ts";
import { cloneResearch, fakeFetch, jsonResponse, responsesEnvelope } from "./research/test_fixtures.ts";
import { buildResearchPrompt } from "./research/research.ts";

const beastLabel = "https://cropsure.com/wp-content/uploads/2023/03/cropsure-beast-200-herbicide-label-v2.pdf";

Deno.test("V2 prompt starts with manufacturer labels and never requires APVMA", () => {
  const prompt = buildResearchPrompt("Beast", "AU", "Australia", "product_enrichment", [], [], null, true);
  assertEquals(prompt.instructions.includes("Search manufacturer product pages and their product label PDFs FIRST"), true);
  assertEquals(prompt.instructions.includes("Pesticide registration is OPTIONAL"), true);
  assertEquals(prompt.input.includes("establish the full registered identity"), false);
});

Deno.test("Beast prefers label-backed crop herbicide over veterinary registrations", () => {
  const research = cloneResearch();
  research.product = { ...research.product, searched_name: "Beast", canonical_name: "CropSure Beast 200 Herbicide",
    manufacturer: "CropSure Pty Ltd", category: "herbicide", form_type: "liquid", source_refs: [beastLabel] };
  research.documents.official_label_candidates = [{ url: beastLabel, title: "Beast label", domain: "cropsure.com", reason: "product label" }];
  research.registration_candidates = [{ scheme: "apvma", number: "12345", country: "AU", registered_product_name: "Beast Horse Drench",
    source_url: "https://portal.apvma.gov.au/pubcris?p_id=1", source_domain: "portal.apvma.gov.au", confidence: "high", reason: "Veterinary horse treatment" }];
  assertEquals(agriculturalWebCandidates("Beast", research, "AU").map((c) => c.name), ["CropSure Beast 200 Herbicide"]);
  assertEquals(labelHeaderFacts("ACTIVE CONSTITUENT: 200 g/L GLUFOSINATE-AMMONIUM GROUP 10 HERBICIDE"), {
    active: { name: "GLUFOSINATE-AMMONIUM", concentration: 200, concentration_unit: "g/L" },
    group: { scheme: "hrac", code: "10" }, form: "liquid",
  });
});

Deno.test("only an accepted Australian document can contribute its printed APVMA evidence", () => {
  const text = "CropSure Beast 200 Herbicide. APVMA Approval No. 90143/127764. GROUP 10 HERBICIDE";
  assertEquals(labelApprovalNumber(text, "AU"), "90143/127764");
  assertEquals(labelApprovalNumber(text, "NZ"), null);
  assertEquals(labelApprovalNumber("Beast herbicide; candidate 90143/127764", "AU"), null);
  assertEquals(labelApprovalNumber("APVMA Approval No. 90143/127764; APVMA Approval No. 88888", "AU"), null);
  const document = { fetchedUrl: beastLabel, labelText: text,
    diagnostics: { manufacturer_label_fetch_outcome: "fetched", manufacturer_label_extract: "failure" } } as ManufacturerEnrichmentResult;
  assertEquals(readableV2Label(document), beastLabel);
  assertEquals(readableV2Label({ ...document, fetchedUrl: null }), null);
  assertEquals(readableV2Label({ ...document, labelText: undefined }), null);
});

Deno.test("Dithane label facts and separate printed rate bases survive without registration", () => {
  const research = cloneResearch();
  const label = "https://elabels.apvma.gov.au/59688.pdf";
  const supported = supportedWebResearch(research, "AU", label, null);
  assertEquals(supported.registration_candidates.length, 0);
  assertEquals(supported.registered_uses[0].rates.map((r) => r.basis), ["per_100_litres", "per_hectare"]);
  assertEquals(labelHeaderFacts("ACTIVE CONSTITUENT: 750 g/kg MANCOZEB GROUP M3 FUNGICIDE").group?.code, "M3");
});

Deno.test("fertiliser and adjuvant need no APVMA number", () => {
  for (const category of ["biostimulant", "fertiliser", "adjuvant"]) {
    const research = cloneResearch();
    research.product = { ...research.product, searched_name: "Kelpak", canonical_name: "Kelpak Organic", category,
      source_refs: ["https://agrichem.com.au/products/kelpak-organic"] };
    research.documents.product_page_candidates = [{ url: "https://agrichem.com.au/products/kelpak-organic", title: "Kelpak",
      domain: "agrichem.com.au", reason: "Manufacturer product page" }];
    research.registration_candidates = [];
    assertEquals(agriculturalWebCandidates("Kelpak", research, "AU").length, 1);
  }
});

Deno.test("unrelated alternatives excluded; genuinely agricultural alternatives remain selectable", () => {
  const research = cloneResearch();
  research.product = { ...research.product, searched_name: "Beast", canonical_name: "CropSure Beast 200 Herbicide",
    category: "herbicide", source_refs: [beastLabel] };
  research.registration_candidates = [
    { scheme: null, number: null, country: "AU", registered_product_name: "Beast Vineyard Herbicide",
      source_url: "https://cropsure.com/products/beast-vineyard", source_domain: "cropsure.com", confidence: "medium", reason: "Crop herbicide", },
    { scheme: "apvma", number: "123", country: "AU", registered_product_name: "Beast Sheep Treatment",
      source_url: "https://portal.apvma.gov.au/pubcris?p_id=1", source_domain: "portal.apvma.gov.au", confidence: "high", reason: "Livestock veterinary drench", },
  ];
  assertEquals(agriculturalWebCandidates("Beast", research, "AU").map((c) => c.name),
    ["CropSure Beast 200 Herbicide", "Beast Vineyard Herbicide"]);
});

Deno.test("document-only AI fallback retains both printed bases and rejects absent amounts", async () => {
  const research = cloneResearch();
  research.registered_uses[0].rates.push({ ...research.registered_uses[0].rates[0], value: 999, raw_text: "999 g/100 L" });
  const { fn } = fakeFetch([jsonResponse(responsesEnvelope(research))]);
  const result = await readLabelWithResearchSchema({
    text: "Grapevines Downy mildew 200 g/100 L; Grapevines Black Spot 2 kg/ha",
    label: "https://elabels.apvma.gov.au/59688.pdf", name: "Dithane Rainshield", country: "AU",
    apiKey: "fixture", fetchFn: fn,
  });
  assertEquals(result?.registered_uses[0].rates.map((rate) => rate.basis), ["per_100_litres", "per_hectare"]);
});

Deno.test("unsupported research facts never populate review", () => {
  const research = cloneResearch();
  const supported = supportedWebResearch(research, "AU", null, null);
  assertEquals(supported.active_ingredients.length, 0);
  assertEquals(supported.registered_uses.length, 0);
  assertEquals(supported.registration_candidates.length, 0);
});
