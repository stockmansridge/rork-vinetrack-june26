// Stage B acceptance: exact manufacturer-label acquisition and grapevine rate
// population for APVMA 33182 (VICOL WINTER OIL INSECTICIDE).
//
// Every assertion runs against a fixture captured from the REAL registrant
// document at vicchem.com — real coordinates, real wording, real "1OO" glyphs
// — so the regression proves the pipeline reads an actual published label
// rather than a hand-written approximation of one. No network at test time.
//
// The URLs below appear ONLY as test data. Nothing in the production path
// knows this product, this registrant or these paths: discovery runs from the
// registered identity, the registrant name and generic document classification.

import {
  assert,
  assertEquals,
  assertFalse,
} from "https://deno.land/std@0.224.0/assert/mod.ts";

import { VICOL_33182_LABEL_ITEMS } from "./seeds/label_fixture_33182.ts";
import {
  extractManufacturerLabelUses,
  manufacturerUsesToRegisteredUses,
  normaliseDigitGlyphs,
  selectPracticalUses,
} from "./manufacturer_label.ts";
import { whpDaysFromStatement, reentryHoursFromStatement } from "./label.ts";
import { projectGrapevineUses, selectLabelReferences } from "../grapevine_label.ts";
import { classifyUrl } from "../research/classify.ts";
import { selectManufacturerLabel } from "../research/linked_documents.ts";
import {
  applyManufacturerEnrichment,
  type ManufacturerEnrichmentResult,
  manufacturerDocumentConfirmsIdentity,
  verifiedManufacturerLabelUrl,
} from "./manufacturer_enrichment.ts";

const REGISTERED_NAME = "VICOL WINTER OIL INSECTICIDE";
const PRODUCT_URL = "https://www.vicchem.com/product_detail?pn=19200";
const LABEL_URL = "https://www.vicchem.com/prods/label/VICOLWOLabel.pdf";
const SDS_URL = "https://www.vicchem.com/prods/msds/sds%20vicol%20winter%20oil.pdf";
const TDS_URL = "https://www.vicchem.com/prods/pdb/pdb-VICOLWO.pdf";
const REGULATOR_LABEL_URL = "https://portal.apvma.gov.au/elabels/33182.PDF";

/** The label's own withholding wording, verbatim from the fixture page. */
const WHP_STATEMENT =
  "DO NOT apply later than one day before harvest.";

function grapevineUses(): Record<string, unknown>[] {
  const parse = extractManufacturerLabelUses(VICOL_33182_LABEL_ITEMS);
  const rows = manufacturerUsesToRegisteredUses(parse.uses, {
    withholdingPeriodDays: whpDaysFromStatement(WHP_STATEMENT, "withholding"),
    reEntryPeriodHours: null,
  });
  return projectGrapevineUses(rows).grapevine_uses;
}

function ratesOf(use: Record<string, unknown>): { basis: string; value?: number; unit: string; label: string; raw_text: string }[] {
  return (use.rates ?? []) as never;
}

Deno.test("manufacturer PDF bytes must confirm the locked registration or full product identity", () => {
  assertEquals(manufacturerDocumentConfirmsIdentity({
    text: "CropSure Greenshield 750 WG Fungicide APVMA Approval No 90279",
    registrationNumber: "90279",
    registeredProductName: "CROPSURE GREENSHIELD 750 WG FUNGICIDE",
  }), true);
  assertEquals(manufacturerDocumentConfirmsIdentity({
    text: "CropSure Greenshield 750WG Fungicide Product Label",
    registrationNumber: "90279",
    registeredProductName: "CROPSURE GREENSHIELD 750 WG FUNGICIDE",
  }), true);
  assertEquals(manufacturerDocumentConfirmsIdentity({
    text: "Unrelated Fungicide Product Label APVMA 12345",
    registrationNumber: "90279",
    registeredProductName: "CROPSURE GREENSHIELD 750 WG FUNGICIDE",
  }), false);
});

// ---------------------------------------------------------------------------
// TEST A — exact identity remains locked
// ---------------------------------------------------------------------------

Deno.test("A: reading the manufacturer label never changes the registration", () => {
  // The document names an APVMA approval of its own ("33182/145635"). Nothing
  // in the extractor reads it, and nothing may: identity was settled by the
  // register before a byte was fetched. The parser returns uses, never an
  // identity, so there is no channel through which a document could
  // substitute a product.
  const parse = extractManufacturerLabelUses(VICOL_33182_LABEL_ITEMS);
  const asRecord = parse as unknown as Record<string, unknown>;
  assertFalse("registration_number" in asRecord);
  assertFalse("product_name" in asRecord);
  assertFalse("registrant" in asRecord);
  for (const use of parse.uses) {
    assertFalse("registration_number" in (use as unknown as Record<string, unknown>));
  }
});

// ---------------------------------------------------------------------------
// TEST B — manufacturer product page discovered and classified
// ---------------------------------------------------------------------------

Deno.test("B: the registrant's product page is readable even on an unlisted host", () => {
  const c = classifyUrl(PRODUCT_URL, "AU");

  // This is the transition that was structurally impossible before Stage B.
  // vicchem.com is a real registrant that nobody had added to the host
  // allowlist, so the page was pre-filtered out of inspection and its label
  // was never reachable — no request was ever made.
  assert(
    c.isInspectableProductPage,
    `expected the page to be readable for evidence, got ${c.kind}/${c.trust}: ${c.reason}`,
  );

  // Reading is not trusting. Until the fetched page proves itself, it is NOT
  // servable as the product URL and it is certainly not a label.
  assertFalse(
    c.isProductPageCandidate,
    "an unlisted host must not be served as product_url before it proves itself",
  );
  assertFalse(
    c.isOfficialLabelCandidate,
    "a marketing product page must never qualify as a label",
  );
});

Deno.test("B2: hosts that are never evidence stay unreadable", () => {
  // The categories that must NOT benefit from the relaxation above.
  for (const url of [
    "https://www.google.com/search?q=vicol+winter+oil+label",
    "https://www.bing.com/search?q=vicol",
  ]) {
    const c = classifyUrl(url, "AU");
    assertFalse(c.isInspectableProductPage, `${url} must never be inspected: ${c.reason}`);
  }
});

// ---------------------------------------------------------------------------
// TEST C — same-domain label link followed and promoted
// ---------------------------------------------------------------------------

Deno.test("C: the label PDF linked from the product page becomes manufacturer_label", () => {
  // Exactly the links the real page carries, in page order.
  const documents = [
    { url: SDS_URL, linkText: "Safety Data Sheet" },
    { url: LABEL_URL, linkText: "Product Label" },
    { url: TDS_URL, linkText: "Technical Bulletin" },
  ];
  const selected = selectManufacturerLabel({
    page: { pageUrl: PRODUCT_URL, pageProductName: "VICOL WINTER OIL Insecticide" },
    pageIsTrustedProductPage: true,
    registeredProductName: REGISTERED_NAME,
    documents,
  });
  assertEquals(selected.label?.url, LABEL_URL);

  // And the two documents that are NOT labels were refused by NAME, not by
  // luck of ordering: the SDS is listed first on the real page.
  const sdsRejection = selected.rejected.find((r) => r.url === SDS_URL);
  assertEquals(sdsRejection?.outcome, "rejected_excluded_kind");

  // A manufacturer-hosted label is never mistaken for the regulator's.
  const refs = selectLabelReferences({
    manufacturerLabelUrl: LABEL_URL,
    regulatorLabelUrl: REGULATOR_LABEL_URL,
    productUrl: PRODUCT_URL,
    sdsUrl: SDS_URL,
  });
  assertEquals(refs.manufacturer_label_url, LABEL_URL);
  assertEquals(refs.regulator_label_url, REGULATOR_LABEL_URL);
  assertEquals(refs.manufacturer_product_url, PRODUCT_URL);
  assert(refs.manufacturer_label_url !== refs.regulator_label_url);
});

Deno.test("C2: an APVMA URL offered as the manufacturer label is reclassified", () => {
  const refs = selectLabelReferences({
    manufacturerLabelUrl: REGULATOR_LABEL_URL,
    regulatorLabelUrl: null,
    productUrl: PRODUCT_URL,
  });
  assertEquals(refs.manufacturer_label_url, null);
  assertEquals(refs.regulator_label_url, REGULATOR_LABEL_URL);
});

// ---------------------------------------------------------------------------
// TEST D — source priority
// ---------------------------------------------------------------------------

Deno.test("D: practical grapevine data comes from the manufacturer label first", () => {
  const manufacturerUses = grapevineUses();
  // A regulator reading of the same product that resolved NO grapevine rate —
  // which is exactly the state production is in today.
  const regulatorUses = [{
    crop: "Grapes",
    target: "Grapevine Scale",
    rates: [],
    withholding_period_days: null,
    re_entry_period_hours: null,
    restrictions: null,
  }];

  const chosen = selectPracticalUses({ manufacturerUses, regulatorUses });
  assertEquals(chosen.source, "manufacturer_label");
  assert(chosen.uses.length > regulatorUses.length);

  // The regulator label is not destroyed by losing: it stays available as the
  // registration reference.
  const refs = selectLabelReferences({
    manufacturerLabelUrl: LABEL_URL,
    regulatorLabelUrl: REGULATOR_LABEL_URL,
  });
  assertEquals(refs.regulator_label_url, REGULATOR_LABEL_URL);
});

Deno.test("D2: a manufacturer label with no parsable rate does not displace the regulator", () => {
  const chosen = selectPracticalUses({
    manufacturerUses: [{ crop: "Grapes", target: "Scale", rates: [], restrictions: null }],
    regulatorUses: [{
      crop: "Grapes",
      target: "Scale",
      rates: [{ basis: "per_100_litres", value: 3, unit: "L", label: "", raw_text: "3 L/100 L" }],
      restrictions: null,
    }],
  });
  assertEquals(chosen.source, "regulator_label");
});

Deno.test("CropSure live shape: a verified manufacturer URL survives regulator rate-source selection", () => {
  const cropSureLabel =
    "https://cropsure.com/wp-content/uploads/2023/10/cropsure-greenshield-750wg-fungicide-label.pdf";
  const regulatorUses = [{
    crop: "Grapes",
    target: "Downy mildew",
    rates: [{ basis: "per_100_litres", value: 200, unit: "g", raw_text: "200 g/100 L" }],
    withholding_period_days: 30,
  }];
  const result: ManufacturerEnrichmentResult = {
    uses: regulatorUses,
    source: "regulator_label",
    fetchedUrl: cropSureLabel,
    withholdingPeriodDays: null,
    diagnostics: {
      manufacturer_label_fetch: "success",
      manufacturer_label_fetch_outcome: "fetched",
      manufacturer_label_fetch_reason: "PDF identity confirmed",
      manufacturer_label_extract: "success",
      manufacturer_label_bytes: 277033,
      manufacturer_label_sha256: "confirmed-pdf-fingerprint",
      label_rows_found: 1,
      grapevine_rows_found: 1,
      grapevine_rates_found: 1,
      withholding_period_days: null,
      practical_source: "regulator_label",
      practical_source_reason: "regulator rows are more complete",
    },
  };
  const structured: {
    registration: {
      registration_number: string;
      label_reference: string;
      regulator_label_url: string;
      manufacturer_label_url?: string | null;
      manufacturer_product_url?: string | null;
    };
    registered_uses: typeof regulatorUses;
    label_urls?: {
      regulator_label_url: string | null;
      manufacturer_label_url: string | null;
      product_url: string | null;
    };
    product_url?: string | null;
  } = {
    registration: {
      registration_number: "90279",
      label_reference: "https://elabels.apvma.gov.au/90279ELBL.pdf",
      regulator_label_url: "https://elabels.apvma.gov.au/90279ELBL.pdf",
    },
    registered_uses: regulatorUses,
  };

  assertEquals(verifiedManufacturerLabelUrl(result), cropSureLabel);
  applyManufacturerEnrichment(structured, result, {
    manufacturerLabelUrl: cropSureLabel,
    manufacturerProductUrl: "https://cropsure.com/products/greenshield-750wg",
  });

  assertEquals(structured.registration.manufacturer_label_url, cropSureLabel);
  assertEquals(structured.label_urls?.manufacturer_label_url, cropSureLabel);
  assertEquals(
    structured.registration.regulator_label_url,
    "https://elabels.apvma.gov.au/90279ELBL.pdf",
  );
  assertEquals(structured.registered_uses, regulatorUses);
  assertEquals(structured.registered_uses[0].withholding_period_days, 30);
});

// ---------------------------------------------------------------------------
// TEST E — grapevine extraction
// ---------------------------------------------------------------------------

Deno.test("E: the four grapevine directions are extracted with their conditions", () => {
  const parse = extractManufacturerLabelUses(VICOL_33182_LABEL_ITEMS);
  assert(parse.found, "DIRECTIONS FOR USE table was not located");

  const grapes = parse.uses.filter((u) => /^grapes$/i.test(u.crop));
  assertEquals(grapes.length, 4, "expected exactly four grapevine directions");

  const shape = grapes.map((u) => ({
    targets: u.targets,
    condition: u.condition,
    value: u.rates[0]?.value,
    basis: u.rates[0]?.basis,
    unit: u.rates[0]?.unit,
  }));

  assertEquals(shape, [
    {
      targets: ["Grapeleaf Blister Mites", "European Red Mites", "Two Spotted Mites"],
      condition: "Tas",
      value: 2,
      basis: "per_100_litres",
      unit: "L",
    },
    {
      targets: ["European Red Mites"],
      condition: "NSW, Vic, SA",
      value: 3,
      basis: "per_100_litres",
      unit: "L",
    },
    {
      targets: ["Grapevine Scale"],
      condition: "NSW, Vic, Qld, SA, WA",
      value: 3,
      basis: "per_100_litres",
      unit: "L",
    },
    {
      targets: ["Grapevine Scale"],
      condition: "Tas",
      value: 2,
      basis: "per_100_litres",
      unit: "L",
    },
  ]);
});

Deno.test("E2: the label's letter-O rate glyphs are read as digits", () => {
  // "2 L / 1OO L" is what the document's text layer actually contains. Every
  // rate on this label was unparseable because of it.
  assertEquals(normaliseDigitGlyphs("2 L / 1OO L"), "2 L / 100 L");
  // Words are never touched, whatever letters they contain.
  assertEquals(normaliseDigitGlyphs("Oystershell Scale, Qld, SA, WA"), "Oystershell Scale, Qld, SA, WA");
  assertEquals(normaliseDigitGlyphs("CO2"), "CO2");
});

// ---------------------------------------------------------------------------
// TEST F — separate conditional rates
// ---------------------------------------------------------------------------

Deno.test("F: 2 L/100 L and 3 L/100 L stay separate conditional rates", () => {
  const uses = grapevineUses();
  const readings = uses.flatMap((u) =>
    ratesOf(u).map((r) => ({ value: r.value, label: r.label, raw: r.raw_text }))
  );

  const values = [...new Set(readings.map((r) => r.value))].sort();
  assertEquals(values, [2, 3]);

  for (const r of readings) {
    // No synthesised range.
    assertFalse(/2\s*[-–]\s*3/.test(r.raw), `range synthesised: ${r.raw}`);
    // No concatenated cell.
    assertEquals(
      (r.raw.match(/\d+\s*L\s*\/\s*100\s*L/gi) ?? []).length,
      1,
      `more than one rate glued into one cell: ${r.raw}`,
    );
    // Every rate names the condition that governs it.
    assert(r.label.length > 0, "a rate was served without its condition");
  }

  // And no rate is flagged ambiguous: each is bound to its own printed state.
  for (const u of uses) {
    for (const r of ratesOf(u) as unknown as { condition_ambiguous?: boolean }[]) {
      assertFalse(r.condition_ambiguous === true);
    }
  }
});

// ---------------------------------------------------------------------------
// TEST G — no invented hectare rate
// ---------------------------------------------------------------------------

Deno.test("G: no per-hectare rate is invented from a per-100-L label", () => {
  const uses = grapevineUses();
  for (const u of uses) {
    for (const r of ratesOf(u)) {
      assertEquals(r.basis, "per_100_litres");
      assertFalse(/\/\s*ha\b|hectare/i.test(r.raw_text));
    }
  }
  // The reference-range projection stays empty: the product IS registered on
  // grapevines, so there is nothing to show "for reference only".
  const parse = extractManufacturerLabelUses(VICOL_33182_LABEL_ITEMS);
  const rows = manufacturerUsesToRegisteredUses(parse.uses);
  const projection = projectGrapevineUses(rows);
  assert(projection.registered_for_grapevine);
  assertEquals(projection.label_reference_rate_ranges, []);
});

// ---------------------------------------------------------------------------
// TEST H — restrictions bound to grapevine
// ---------------------------------------------------------------------------

Deno.test("H: post-pruning / dormant wording stays attached to grapevines", () => {
  const uses = grapevineUses();
  assert(uses.length > 0);
  for (const u of uses) {
    const restrictions = String(u.restrictions ?? "");
    assert(/post pruning/i.test(restrictions), `missing post-pruning wording: ${restrictions}`);
    assert(/fully dormant/i.test(restrictions), `missing dormancy wording: ${restrictions}`);
    // Stone-fruit critical comments must never migrate onto grapevines.
    assertFalse(
      /bud swell|sunny days/i.test(restrictions),
      `stone-fruit comments contaminated a grapevine use: ${restrictions}`,
    );
  }
});

// ---------------------------------------------------------------------------
// TEST I — WHP / REI
// ---------------------------------------------------------------------------

Deno.test("I: WHP resolves to 1 day and REI stays null when not stated", () => {
  assertEquals(whpDaysFromStatement(WHP_STATEMENT, "withholding"), 1);
  // Not zero. "Not stated" and "no withholding period" are different claims.
  assertEquals(reentryHoursFromStatement("Avoid inhalation of spray mists."), null);

  const uses = grapevineUses();
  for (const u of uses) {
    assertEquals(u.withholding_period_days, 1);
    assertEquals(u.re_entry_period_hours, null);
  }
});

// ---------------------------------------------------------------------------
// TEST J — other crops do not contaminate the grapevine projection
// ---------------------------------------------------------------------------

Deno.test("J: grapevine_uses contains grapes only; other crops are retained", () => {
  const parse = extractManufacturerLabelUses(VICOL_33182_LABEL_ITEMS);
  const rows = manufacturerUsesToRegisteredUses(parse.uses);
  const projection = projectGrapevineUses(rows);

  // The label covers pome fruit, stone fruit, almonds and grapes.
  const otherCrops = new Set(
    projection.other_crop_uses.map((u: { crop: string }) => u.crop.toLowerCase()),
  );
  assert(otherCrops.size > 0, "other crops were dropped rather than retained");
  assert(
    [...otherCrops].some((c) => /almond|pome|stone/.test(c)),
    `expected the label's other crops to survive, got ${[...otherCrops].join(", ")}`,
  );

  for (const u of projection.grapevine_uses) {
    assertEquals(String((u as { crop: string }).crop).toLowerCase(), "grapes");
  }
  assertFalse(
    projection.grapevine_uses.some((u: { crop: string }) => /grapefruit/i.test(u.crop)),
  );
});

Deno.test("J2: the other page column is excluded from the table by position", () => {
  // The right-hand newsletter column (COMPATIBILITY, STORAGE AND DISPOSAL,
  // SAFETY DIRECTIONS) shares y positions with the table rows. Without a
  // derived boundary it lands in critical comments.
  const parse = extractManufacturerLabelUses(VICOL_33182_LABEL_ITEMS);
  assert(parse.rightBoundary !== null, "no page-column boundary was derived");
  for (const u of parse.uses) {
    const r = String(u.restrictions ?? "");
    assertFalse(/triple-rinse|poisons information|storage and disposal/i.test(r), r);
  }
});
