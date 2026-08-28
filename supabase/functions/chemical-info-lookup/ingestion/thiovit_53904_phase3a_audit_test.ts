// P2C-B1 Phase 3A — root-cause AUDIT for THIOVIT JET (APVMA 53904).
//
// Audit only. No production module is modified by this work; every test here
// EXECUTES existing production code and records what it actually does.
//
// The Phase 2B report guessed at two of these answers and got them wrong. So
// nothing below is reasoned about from reading source: the register row is the
// live one, the mappers are the real ones reached through the real adapter,
// and the routing gate is the real predicate the merge calls.

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

import { apvmaAdapter, APVMA_RESOURCES, clearApvmaCache } from "./apvma.ts";
import { rateIsCalculable, statesCalculableGrapevineRate } from "./label_panel_fallback.ts";
import { isGrapevineCrop } from "../grapevine_label.ts";
import { mintDirectionId } from "../rate_identity.ts";
import {
  THIOVIT_53904_ACTUAL_REGISTERED_USE_ROWS,
  THIOVIT_53904_EXPECTED_GRAPE_DIRECTIONS,
  THIOVIT_53904_PRODUCT_MEASUREMENT,
  THIOVIT_53904_PUBCRIS_FIELD_AUDIT,
  THIOVIT_53904_PUBCRIS_PRODUCT_ROW,
} from "./seeds/thiovit_53904_evidence.ts";

// ---------------------------------------------------------------------------
// A register stub that serves the REAL row and nothing else
//
// Everything except the product row answers empty/404 so each fail-soft branch
// takes its honest path. The point is to reach the real mappers with the real
// value, not to simulate a full lookup.
// ---------------------------------------------------------------------------

function registerFetch(): typeof fetch {
  return ((input: string | URL | Request): Promise<Response> => {
    const href = typeof input === "string" ? input : input.toString();
    const json = (body: unknown): Promise<Response> =>
      Promise.resolve(
        new Response(JSON.stringify(body), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }),
      );

    if (href.startsWith("https://data.gov.au/data/api/3/action/datastore_search")) {
      const resource = new URL(href).searchParams.get("resource_id");
      if (resource === APVMA_RESOURCES.product) {
        return json({
          success: true,
          result: { records: [{ ...THIOVIT_53904_PUBCRIS_PRODUCT_ROW }] },
        });
      }
      return json({ success: true, result: { records: [] } });
    }
    // Label document discovery and anything else: fail soft.
    return Promise.resolve(new Response("", { status: 404 }));
  }) as unknown as typeof fetch;
}

/** Run the REAL adapter against the REAL row and return its resolved registration. */
async function resolve53904() {
  clearApvmaCache();
  const result = await apvmaAdapter.discover(
    "THIOVIT JET MICROGRANULE FUNGICIDE/MITICIDE",
    "53904",
    { fetchFn: registerFetch(), now: () => new Date("2026-08-28T00:00:00Z") },
  );
  clearApvmaCache();
  assertEquals(result.outcome, "resolved");
  const registration = result.outcome === "resolved" ? result.registration : undefined;
  assert(registration, "the register row must resolve for this audit to mean anything");
  return registration;
}

// ---------------------------------------------------------------------------
// §A — the corrected provenance, executed rather than asserted from reading
// ---------------------------------------------------------------------------

Deno.test("§3A-1 the live register row publishes fdesc, hlevel1, prodtype AND typedesc", () => {
  // All four exist. Phase 2B listed prodtype/typedesc as unverified; they are
  // present, and §3A-6 shows they carry no category meaning.
  const row = THIOVIT_53904_PUBCRIS_PRODUCT_ROW;
  assertEquals(row.fdesc, "MICROGRANULE");
  assertEquals(row.hlevel1, "MIXED FUNCTION PESTICIDE");
  assertEquals(row.prodtype, "A");
  assertEquals(row.typedesc, "A - Agricultural");
  assertEquals(row.regcode, "R");
  assertEquals(row.expdate, "30/06/2026 0:00");
});

Deno.test("§3A-2 form_type=solid is produced by the REAL adapter from the register alone", async () => {
  const registration = await resolve53904();

  // Executed, not inferred: mapFormType(fdesc="MICROGRANULE") -> "solid".
  assertEquals(registration.form_type, "solid");

  // No label document, no label evidence, no manufacturer page and no AI were
  // available to this stub at all — so `solid` cannot have come from any of
  // them. The register is sufficient on its own.
  assertEquals(registration.label_evidence, null);
  assertEquals(registration.label_document, null);
  assertEquals(registration.label_panel_uses, null);

  // And the register's own lifecycle facts survive verbatim beside it.
  assertEquals(registration.register_status, "R, expires 30/06/2026 0:00");
});

Deno.test("§3A-3 the fixture now records official_register as the canonical provenance", () => {
  assertEquals(THIOVIT_53904_PRODUCT_MEASUREMENT.physical_form, "solid");
  assertEquals(THIOVIT_53904_PRODUCT_MEASUREMENT.physical_form_provenance, "official_register");
  assertEquals(THIOVIT_53904_PRODUCT_MEASUREMENT.physical_form_register_field, "fdesc");
  assertEquals(THIOVIT_53904_PRODUCT_MEASUREMENT.physical_form_register_value, "MICROGRANULE");
  // Manufacturer agreement survives as corroboration, not as the source.
  assert(/manufacturer_label/.test(THIOVIT_53904_PRODUCT_MEASUREMENT.physical_form_corroboration));
});

Deno.test("§3A-4 the withdrawn Phase 2B claim is gone: fdesc and hlevel1 are CONSUMED", () => {
  assertEquals(THIOVIT_53904_PUBCRIS_FIELD_AUDIT.fdesc.status, "already_consumed");
  assertEquals(THIOVIT_53904_PUBCRIS_FIELD_AUDIT.fdesc.consumed_by, "apvma.ts mapFormType()");
  assertEquals(
    THIOVIT_53904_PUBCRIS_FIELD_AUDIT.hlevel1.consumed_by,
    "apvma.ts mapCategory()",
  );
});

// ---------------------------------------------------------------------------
// §C — why product_category is null
// ---------------------------------------------------------------------------

Deno.test("§3A-5 product_category=null is the REAL mapCategory declining an unmapped vocabulary", async () => {
  const registration = await resolve53904();

  // The field is read. The value is simply outside the mapper's vocabulary.
  assertEquals(registration.product_category, null);

  const hlevel1 = THIOVIT_53904_PUBCRIS_PRODUCT_ROW.hlevel1.toUpperCase();
  for (
    const token of [
      "FUNGICIDE",
      "HERBICIDE",
      "INSECTICIDE",
      "MITICIDE",
      "ACARICIDE",
      "GROWTH REGULATOR",
      "ADJUVANT",
      "SURFACTANT",
    ]
  ) {
    assert(!hlevel1.includes(token), `mapCategory has no branch matching ${token}`);
  }
  // So null here is the mapper behaving CORRECTLY — declining rather than
  // guessing. The defect is a vocabulary gap, not a consumption gap.
  assertEquals(hlevel1, "MIXED FUNCTION PESTICIDE");
});

Deno.test("§3A-6 prodtype/typedesc are the agricultural axis and cannot supply a category", () => {
  assertEquals(THIOVIT_53904_PUBCRIS_FIELD_AUDIT.prodtype.exists_in_dataset, true);
  assertEquals(THIOVIT_53904_PUBCRIS_FIELD_AUDIT.typedesc.exists_in_dataset, true);
  assertEquals(THIOVIT_53904_PUBCRIS_FIELD_AUDIT.prodtype.provides_category, false);
  assertEquals(THIOVIT_53904_PUBCRIS_FIELD_AUDIT.typedesc.provides_category, false);
  // "A - Agricultural" answers "agricultural or veterinary", never "which
  // pesticide function". No category can be derived from it without inventing.
  assert(/Agricultural/.test(THIOVIT_53904_PUBCRIS_PRODUCT_ROW.typedesc));
});

Deno.test("§3A-7 the register itself calls this product MIXED FUNCTION — single-string loses that", () => {
  // The registered NAME states both functions, and the register's own
  // classification is explicitly a combined one. A single-string
  // `product_category` can hold "fungicide" OR "miticide" but not the
  // regulator's actual combined classification.
  assert(/FUNGICIDE\/MITICIDE/.test(THIOVIT_53904_PUBCRIS_PRODUCT_ROW.fpname));
  assertEquals(THIOVIT_53904_PUBCRIS_PRODUCT_ROW.hlevel1, "MIXED FUNCTION PESTICIDE");
  // Recorded, not resolved: choosing either one would be information loss and
  // is exactly what "do not invent a category" forbids.
  assertEquals(
    THIOVIT_53904_PUBCRIS_FIELD_AUDIT.hlevel1.status,
    "already_consumed_but_unmapped_vocabulary",
  );
});

// ---------------------------------------------------------------------------
// §D — why the state-aware parser never repairs Thiovit
// ---------------------------------------------------------------------------

Deno.test("§3A-8 GRAPE is a grapevine crop, so the gate does examine these rows", () => {
  // If this were false the gate would be vacuous and the diagnosis wrong.
  assertEquals(isGrapevineCrop("GRAPE"), true);
});

Deno.test("§3A-9 both collapsed Thiovit rates are individually CALCULABLE", () => {
  const rates = THIOVIT_53904_ACTUAL_REGISTERED_USE_ROWS[0].rates as unknown[];
  assertEquals(rates.length, 2);
  for (const r of rates) assertEquals(rateIsCalculable(r), true);
  // Note what this means: `condition_ambiguous: true` is present on BOTH and
  // `rateIsCalculable` does not look at it. Numeric usability is the only
  // question the predicate asks.
});

Deno.test("§3A-10 ROOT CAUSE: the routing gate reports Thiovit as a working parse", () => {
  // This is the exact predicate `ingest.ts:309` evaluates.
  const statesCalculable = statesCalculableGrapevineRate(
    THIOVIT_53904_ACTUAL_REGISTERED_USE_ROWS,
  );
  assertEquals(statesCalculable, true);

  // Reproducing ingest.ts:309 verbatim:
  //   if (panelUses?.length && !statesCalculableGrapevineRate(uses))
  // Even with a perfect state-aware candidate available, the second clause is
  // false, so the fallback is skipped and the collapsed rows are served.
  const panelUsesAvailable = true;
  const fallbackWouldApply = panelUsesAvailable && !statesCalculable;
  assertEquals(
    fallbackWouldApply,
    false,
    "the state-aware re-read is gated out for Thiovit",
  );
});

Deno.test("§3A-11 the gate is numeric-only: it cannot see collapsed direction identity", () => {
  // Every signal that the projection is semantically broken is present in the
  // rows the gate inspects, and the gate consults none of them.
  const row = THIOVIT_53904_ACTUAL_REGISTERED_USE_ROWS[0];
  const rates = row.rates as { condition_ambiguous?: boolean }[];

  assertEquals(rates.every((r) => r.condition_ambiguous === true), true);
  assertEquals(rates.length > 1, true); // same target, several rates, one use
  assertEquals(row.restrictions, null); // no per-direction comment binding

  // And yet:
  assertEquals(statesCalculableGrapevineRate([row]), true);
});

Deno.test("§3A-12 the proposed gate signals would each, alone, catch Thiovit", () => {
  const row = THIOVIT_53904_ACTUAL_REGISTERED_USE_ROWS[0];
  const rates = row.rates as { condition_ambiguous?: boolean; basis?: string }[];

  // Signal 1 — any served rate declares its condition unproven.
  const anyAmbiguous = rates.some((r) => r.condition_ambiguous === true);
  assertEquals(anyAmbiguous, true);

  // Signal 2 — one use carries several rates on the SAME basis, which is the
  // shape a collapse produces (two printed directions folded into one row).
  const perBasis = new Map<string, number>();
  for (const r of rates) {
    perBasis.set(String(r.basis), (perBasis.get(String(r.basis)) ?? 0) + 1);
  }
  const collapsedBasis = [...perBasis.values()].some((n) => n > 1);
  assertEquals(collapsedBasis, true);

  // Either signal is positive EVIDENCE of lost direction binding — as opposed
  // to "another parser also exists", which must never be sufficient.
  assertEquals(anyAmbiguous || collapsedBasis, true);
});

// ---------------------------------------------------------------------------
// §G — the existing identity system is already sufficient
// ---------------------------------------------------------------------------

Deno.test("§3A-13 crop + targets + condition ALREADY distinguishes the two PM directions", () => {
  const product = { country: "AU", scheme: "apvma", registration_number: "53904" };
  const pm = THIOVIT_53904_EXPECTED_GRAPE_DIRECTIONS.filter((d) =>
    d.targets.some((t) => /powdery mildew/i.test(t))
  );
  assertEquals(pm.length, 2);

  const ids = pm.map((d) =>
    mintDirectionId(product, {
      crop: d.crop_context,
      targets: d.targets,
      condition: d.state_applicability,
    })
  );
  assertEquals(new Set(ids).size, 2);

  // Stable under re-minting and independent of array order — so no new
  // identity system is needed, only the preservation of its inputs.
  const reversed = [...pm].reverse().map((d) =>
    mintDirectionId(product, {
      crop: d.crop_context,
      targets: [...d.targets].reverse(),
      condition: d.state_applicability,
    })
  );
  assertEquals(new Set(reversed), new Set(ids));
});
