// Task §41 — structured output validation tests.

import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";

import {
  CHEMICAL_RESEARCH_SCHEMA,
  CHEMICAL_RESEARCH_SCHEMA_NAME,
  parseChemicalResearchResult,
  ResearchSchemaError,
} from "./schema.ts";
import { projectResearch } from "./authority.ts";
import { cloneResearch, DITHANE_RESEARCH_PAYLOAD } from "./test_fixtures.ts";

Deno.test("the schema is strict-mode legal: every object seals and requires its keys", () => {
  const problems: string[] = [];
  const walk = (node: unknown, path: string) => {
    if (typeof node !== "object" || node === null) return;
    const n = node as Record<string, unknown>;
    if (n.type === "object") {
      if (n.additionalProperties !== false) problems.push(`${path}: additionalProperties`);
      const props = Object.keys((n.properties ?? {}) as Record<string, unknown>);
      const required = (n.required ?? []) as string[];
      for (const key of props) {
        if (!required.includes(key)) problems.push(`${path}.${key}: not required`);
      }
    }
    for (const [key, child] of Object.entries(n)) {
      if (key === "enum") continue;
      if (Array.isArray(child)) child.forEach((c, i) => walk(c, `${path}.${key}[${i}]`));
      else walk(child, `${path}.${key}`);
    }
  };
  walk(CHEMICAL_RESEARCH_SCHEMA, "$");
  assertEquals(problems, []);
  assertEquals(CHEMICAL_RESEARCH_SCHEMA_NAME, "chemical_research_result");
});

Deno.test("§41 a malformed response fails closed", () => {
  assertThrows(() => parseChemicalResearchResult(null), ResearchSchemaError);
  assertThrows(() => parseChemicalResearchResult("a string"), ResearchSchemaError);
  assertThrows(() => parseChemicalResearchResult([]), ResearchSchemaError);
  assertThrows(() => parseChemicalResearchResult({}), ResearchSchemaError);
  assertThrows(
    () => parseChemicalResearchResult({ product: { searched_name: "" } }),
    ResearchSchemaError,
  );
  assertThrows(
    () => parseChemicalResearchResult({ product: { searched_name: 42 } }),
    ResearchSchemaError,
  );
});

Deno.test("§41 missing optional fields are accepted", () => {
  const minimal = parseChemicalResearchResult({
    product: { searched_name: "Kelp Extract", country: "AU" },
  });
  assertEquals(minimal.product.searched_name, "Kelp Extract");
  assertEquals(minimal.product.canonical_name, null);
  assertEquals(minimal.registration_candidates, []);
  assertEquals(minimal.active_ingredients, []);
  assertEquals(minimal.registered_uses, []);
  assertEquals(minimal.documents.official_label_candidates, []);
  assertEquals(minimal.sources, []);
  assertEquals(minimal.unresolved, []);
});

Deno.test("§41 multiple actives survive", () => {
  const parsed = parseChemicalResearchResult({
    product: { searched_name: "Mix", country: "AU" },
    active_ingredients: [
      { name: "Cyprodinil", concentration: 375, concentration_unit: "g/kg" },
      { name: "Fludioxonil", concentration: 250, concentration_unit: "g/kg" },
    ],
  });
  assertEquals(parsed.active_ingredients.length, 2);
  assertEquals(parsed.active_ingredients[1].name, "Fludioxonil");
  assertEquals(parsed.active_ingredients[1].concentration, 250);
});

Deno.test("§41 multiple registered uses and multiple targets survive", () => {
  const parsed = parseChemicalResearchResult({
    product: { searched_name: "X", country: "AU" },
    registered_uses: [
      {
        crop: "Grapevines",
        targets: ["Powdery Mildew", "Downy Mildew", "Botrytis"],
        rates: [{ basis: "per_100_litres", value: 20, unit: "mL", raw_text: "20 mL/100 L" }],
      },
      {
        crop: "Apples",
        targets: ["Black Spot"],
        rates: [{ basis: "per_hectare", value: 1, unit: "L", raw_text: "1 L/ha" }],
      },
    ],
  });
  assertEquals(parsed.registered_uses.length, 2);
  assertEquals(parsed.registered_uses[0].targets.length, 3);
  assertEquals(parsed.registered_uses[1].crop, "Apples");
});

Deno.test("§41 every rate basis survives, including ranges and reference-only", () => {
  const parsed = parseChemicalResearchResult({
    product: { searched_name: "X", country: "AU" },
    registered_uses: [{
      crop: "Grapevines",
      targets: ["Downy Mildew"],
      rates: [
        { basis: "per_hectare", value: 2, unit: "kg" },
        { basis: "range_per_hectare", min_value: 1.5, max_value: 2.5, unit: "kg" },
        { basis: "per_100_litres", value: 200, unit: "g" },
        { basis: "range_per_100_litres", min_value: 150, max_value: 250, unit: "g" },
        { basis: "per_100_metres", value: 50, unit: "mL" },
        { basis: "other", raw_text: "See resistance management section" },
      ],
    }],
  });
  const bases = parsed.registered_uses[0].rates.map((r) => r.basis);
  assertEquals(bases, [
    "per_hectare",
    "range_per_hectare",
    "per_100_litres",
    "range_per_100_litres",
    "per_100_metres",
    "other",
  ]);
});

Deno.test("§41 a rate carrying neither numbers nor label text is dropped", () => {
  const parsed = parseChemicalResearchResult({
    product: { searched_name: "X", country: "AU" },
    registered_uses: [{
      crop: "Grapevines",
      targets: ["Downy Mildew"],
      rates: [
        { basis: "per_hectare", value: null, min_value: null, max_value: null, raw_text: null },
        { basis: "per_hectare", value: 2, unit: "kg" },
      ],
    }],
  });
  assertEquals(parsed.registered_uses[0].rates.length, 1);
});

Deno.test("§41 an invented rate basis is rejected rather than coerced", () => {
  const parsed = parseChemicalResearchResult({
    product: { searched_name: "X", country: "AU" },
    registered_uses: [{
      crop: "Grapevines",
      targets: ["Downy Mildew"],
      rates: [{ basis: "per_acre_per_fortnight", value: 3, unit: "kg" }],
    }],
  });
  assertEquals(parsed.registered_uses[0].rates.length, 0);
});

Deno.test("§41 the source list and fact→source mapping survive", () => {
  const parsed = parseChemicalResearchResult(DITHANE_RESEARCH_PAYLOAD);
  assertEquals(parsed.sources.length, 2);
  assertEquals(parsed.sources[0].source_type, "official_register");
  assertEquals(parsed.sources[0].supports_fields, ["registration.number"]);
  assertEquals(parsed.active_ingredients[0].source_refs.length, 1);
  assertEquals(
    parsed.registered_uses[0].rates[0].source_refs[0],
    "https://elabels.apvma.gov.au/59688.pdf",
  );
});

Deno.test("§41 an unrecognised source_type degrades to 'other' instead of being trusted", () => {
  const parsed = parseChemicalResearchResult({
    product: { searched_name: "X", country: "AU" },
    sources: [{
      url: "https://example.com/a",
      domain: "example.com",
      source_type: "definitely_authoritative",
      supports_fields: [],
    }],
  });
  assertEquals(parsed.sources[0].source_type, "other");
});

Deno.test("§41 non-http URLs are dropped from sources and documents", () => {
  const parsed = parseChemicalResearchResult({
    product: { searched_name: "X", country: "AU" },
    sources: [
      { url: "javascript:alert(1)", domain: "x", source_type: "other", supports_fields: [] },
      { url: "https://apvma.gov.au/ok", domain: "apvma.gov.au", source_type: "official_register", supports_fields: [] },
    ],
    documents: {
      official_label_candidates: [{ url: "file:///etc/passwd", domain: "local", reason: "" }],
      product_page_candidates: [],
      sds_candidates: [],
    },
  });
  assertEquals(parsed.sources.length, 1);
  assertEquals(parsed.documents.official_label_candidates.length, 0);
});

Deno.test("§41 unknown top-level fields do not survive into the extraction", () => {
  const parsed = parseChemicalResearchResult({
    product: { searched_name: "X", country: "AU", secret: "value" },
    is_master: true,
    review_status: "approved",
    saved_chemical_id: "00000000-0000-0000-0000-000000000000",
  });
  const asRecord = parsed as unknown as Record<string, unknown>;
  assert(!("is_master" in asRecord));
  assert(!("review_status" in asRecord));
  assert(!("saved_chemical_id" in asRecord));
  assert(!("secret" in (parsed.product as unknown as Record<string, unknown>)));
});

Deno.test("§41/§20 FRAC, HRAC and IRAC stay separate schemes", () => {
  const parsed = parseChemicalResearchResult({
    product: { searched_name: "Mixed shed", country: "AU" },
    active_ingredients: [
      { name: "Mancozeb", suggested_scheme: "frac", suggested_group: "M3" },
      { name: "Glyphosate", suggested_scheme: "hrac", suggested_group: "9" },
      { name: "Spirotetramat", suggested_scheme: "irac", suggested_group: "23" },
    ],
  });
  assertEquals(parsed.active_ingredients.map((a) => a.suggested_scheme), [
    "frac",
    "hrac",
    "irac",
  ]);
  const projection = projectResearch(parsed, "AU", "apvma");
  const actives = projection.extraction.active_ingredients as Record<string, unknown>[];
  assertEquals(actives.map((a) => a.activity_group_scheme), ["frac", "hrac", "irac"]);
  assertEquals(
    new Set(actives.map((a) => a.activity_group_scheme)).size,
    3,
    "the three schemes must never collapse into one generic group system",
  );
});

Deno.test("§10 the operator's typo is preserved separately from the canonical name", () => {
  const parsed = parseChemicalResearchResult({
    product: {
      searched_name: "Dithaine rainsheild",
      canonical_name: "Dithane Rainshield Neo Tec Fungicide",
      country: "AU",
    },
  });
  assertEquals(parsed.product.searched_name, "Dithaine rainsheild");
  const projection = projectResearch(parsed, "AU", "apvma");
  assertEquals(
    projection.extraction.product_name,
    "Dithane Rainshield Neo Tec Fungicide",
    "once identified, the canonical identity is what downstream processing uses",
  );
});

Deno.test("§36 a biostimulant with no registration concept still produces a usable draft", () => {
  const parsed = parseChemicalResearchResult({
    product: {
      searched_name: "Switch AG amino acid",
      canonical_name: "Switch AG Amino 16",
      manufacturer: "Switch AG",
      category: "biostimulant",
      form_type: "liquid",
      country: "AU",
    },
    active_ingredients: [{ name: "Free L-amino acids", concentration: 160, concentration_unit: "g/L" }],
    unresolved: ["no registration scheme applies to a biostimulant in AU"],
  });
  const projection = projectResearch(parsed, "AU", "apvma");
  assertEquals(projection.extraction.product_name, "Switch AG Amino 16");
  assertEquals(projection.extraction.product_category, "biostimulant");
  assertEquals(projection.extraction.registration_number, null);
  assert((projection.extraction.unresolved as string[]).some((u) => u.includes("biostimulant")));
});

Deno.test("a research result with no label candidate says so in unresolved", () => {
  const research = cloneResearch();
  research.documents.official_label_candidates = [];
  research.sources = research.sources.filter((s) => !s.url.endsWith(".pdf"));
  const projection = projectResearch(research, "AU", "apvma");
  assertEquals(projection.extraction.label_reference, null);
  assert((projection.extraction.unresolved as string[]).includes("label_reference"));
});
