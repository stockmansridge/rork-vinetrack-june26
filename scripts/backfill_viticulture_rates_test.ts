import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { DiscoveryResult, WireLabelRate } from "../supabase/functions/chemical-info-lookup/ingestion/contract.ts";
import {
  classifyResult,
  hasViticultureEvidence,
  isV2Eligible,
  ratesEqual,
  type CohortRow,
} from "./backfill_viticulture_rates.ts";

const AWRI_REFERENCE = "https://www.awri.com.au/wp-content/uploads/agrochemical_booklet.pdf";

function row(overrides: Partial<CohortRow> = {}): CohortRow {
  return {
    id: "00000000-0000-0000-0000-000000000001",
    registration_country: "AU",
    registration_scheme: "apvma",
    registration_number: "46516",
    registered_product_name: "SPRAY.SEED 250 HERBICIDE",
    review_status: "candidate",
    source_kind: "official_register",
    verification_status: "partially_verified",
    verification_sources: [
      { kind: "official_register" },
      { kind: "viticulture_reference", reference: AWRI_REFERENCE },
    ],
    registered_uses: [],
    ...overrides,
  };
}

function rate(
  basis: WireLabelRate["basis"],
  unit: string,
  min: number,
  max: number,
): WireLabelRate {
  return { label: "", basis, unit, min_value: min, max_value: max, raw_text: `${min}–${max}` };
}

function resolved46516(): DiscoveryResult {
  return {
    outcome: "resolved",
    adapter: "apvma",
    cache: "miss",
    registration: {
      country_code: "AU",
      scheme: "apvma",
      registration_number: "46516",
      registration_identity_key: "AU:apvma:46516",
      registered_product_name: "SPRAY.SEED 250 HERBICIDE",
      registrant: "Registrant",
      product_category: "herbicide",
      form_type: "liquid",
      label_version: "current",
      register_status: "R",
      active_ingredients: [],
      unresolved_fields: [],
      sources: [],
      match_mode: "register_number_verified",
      label_document: {
        url: "https://elabels.apvma.gov.au/46516ELBL.pdf",
        confirmation: "document_fetch",
        retrieved_at: "2026-09-18T00:00:00Z",
        document: { sha256: "fixture", byte_size: 1 },
      },
      label_text_extracted: true,
      label_evidence: {
        claims: [{
          crop: "ORCHARDS, PLANTATIONS AND VINEYARDS",
          target_raw: "Annual weeds",
          statements: [],
          rates: [
            rate("range_per_hectare", "L", 2.4, 3.2),
            rate("range_per_100_litres", "mL", 240, 320),
          ],
        }],
        statements: [],
        sources: [],
        unresolved: [],
      },
      label_panel_uses: null,
    },
  };
}

Deno.test("backfill eligibility mirrors the SQL 238 AU/APVMA cohort", () => {
  assertEquals(isV2Eligible(row()), true);
  assertEquals(isV2Eligible(row({ review_status: "approved", verification_sources: [] })), true);
  assertEquals(isV2Eligible(row({ registration_country: "NZ", review_status: "approved" })), false);
  assertEquals(isV2Eligible(row({ verification_sources: [{ kind: "official_register" }] })), false);
});

Deno.test("vineyard evidence is reported independently from parse outcomes", () => {
  assertEquals(hasViticultureEvidence(row()), true);
  assertEquals(hasViticultureEvidence(row({ verification_sources: [], registered_uses: [{ crop: "Grapes" }] })), true);
  assertEquals(hasViticultureEvidence(row({ verification_sources: [], registered_uses: [{ crop: "Grapefruit" }] })), false);
});

Deno.test("SPRAY.SEED 46516 uses the ordinary deterministic extraction contract", () => {
  const record = classifyResult(row(), resolved46516());
  assertEquals(record.classification, "success");
  assertEquals(record.rates.per_hectare.map((item) => [item.min_value, item.max_value, item.unit]), [[2.4, 3.2, "L"]]);
  assertEquals(record.rates.per_100_litres.map((item) => [item.min_value, item.max_value, item.unit]), [[240, 320, "mL"]]);
});

Deno.test("unchanged viticulture rates are idempotently skipped", () => {
  const first = classifyResult(row(), resolved46516());
  const second = classifyResult(row({ viticulture_rates: first.rates }), resolved46516());
  assertEquals(first.write, "planned");
  assertEquals(second.write, "unchanged");
  assertEquals(ratesEqual(first.rates, second.rates), true);
});

Deno.test("text extraction failure is not reported as no vineyard registration", () => {
  const result = resolved46516();
  if (result.registration) result.registration.label_text_extracted = false;
  assertEquals(classifyResult(row(), result).classification, "parser_failure");
});
