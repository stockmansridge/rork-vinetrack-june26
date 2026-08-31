// CHATEAU 80647 — the WHOLE backend pipeline, from measured PDF glyphs to the
// structured response a client consumes.
//
// # Why this test exists separately from the parser tests
//
// `ingestion/label_80647_test.ts` proves the PARSER reads the label. It cannot
// prove a client ever sees what the parser read. Between the two sit four more
// stages, each of which rebuilds its rows as fresh objects — and every one of
// them is a place where an additive field is not corrupted but silently
// ABSENT. An absent safety field renders as "not stated on label", which is
// indistinguishable from a label that genuinely says nothing.
//
// That failure was real, three times over, all downstream of a correct parse:
//
//   1. `mergeLabelEvidenceIntoUses` carried `withholding_period_days` but not
//      `withholding_statement`, so the legal wording was dropped.
//   2. The handler's own normaliser dropped it AGAIN, one stage before any
//      client could see it. It lived inside the edge function's request module
//      (no exports, `Deno.serve` at load), so it could not be imported and
//      therefore had never been tested. It is now
//      `registered_use_normaliser.ts`.
//   3. The document extractor returned a re-entry reading ONLY when the label
//      stated hours, so CHATEAU's conditional rule produced nothing at all.
//
// So this walks the real chain:
//
//   PDF text layer → document extraction → label claims → authoritative merge
//     → registered-use normalisation → identity minting → vineyard projection
//
// and asserts the FINAL object, not any intermediate one.

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { applyLabelDocumentExtraction } from "./ingestion/label_extract.ts";
import { mergeLabelEvidenceIntoUses } from "./ingestion/label.ts";
import { CHATEAU_80647_ITEMS } from "./ingestion/label_fixture_80647.ts";
import { normaliseRegisteredUses } from "./registered_use_normaliser.ts";
import { applyRateIdentities, DIRECTION_ID_VERSION, RATE_ID_VERSION } from "./rate_identity.ts";
import { projectGrapevineUses } from "./grapevine_label.ts";
import type { LabelDocumentDiscovery, LabelEvidence, LabelUseClaim } from "./ingestion/contract.ts";

/** The locked registration identity this product resolves to. */
const REGISTRATION: {
  country_code: string;
  scheme: string;
  registration_number: string;
} = {
  country_code: "AU",
  scheme: "apvma",
  registration_number: "80647",
};

const DOC: LabelDocumentDiscovery = {
  url: "https://elabels.apvma.gov.au/80647ELBL.pdf",
  confirmation: "pubcris_view_label",
  retrieved_at: "2026-08-30T00:00:00.000Z",
  document: {
    sha256: "18afa5958435ef413f6165a66ee093a06004b9011cad2b71e32abadd78acbdec",
    byte_size: 244_005,
  },
};

const WHP_STATEMENT =
  "WINE AND TABLE GRAPES, POME FRUIT, STONE FRUIT, CITRUS FRUIT, NUT TREE CROPS " +
  "(EXCEPT MACADAMIA NUTS), OLIVES, AVOCADOS AND BERRIES: HARVEST: " +
  "DO NOT HARVEST FOR 14 WEEKS AFTER APPLICATION";

const REI_STATEMENT =
  "DO NOT enter treated areas until the spray has dried unless wearing cotton overalls";

interface Structured {
  registration: typeof REGISTRATION;
  registered_uses: any[];
  grapevine_uses: any[];
  other_crop_uses: any[];
}

/**
 * The production chain, with no stage skipped and no field hand-placed.
 *
 * `registration` is passed exactly as the resolver locks it, because identity
 * minting is product-bound: the ids below are a function of this trio.
 */
function runPipeline(
  claims: LabelUseClaim[],
  registration: typeof REGISTRATION = REGISTRATION,
): Structured {
  const unresolved = new Set<string>();
  for (const c of claims) {
    unresolved.add(`rates:${c.crop}`);
    unresolved.add(`withholding_period:${c.crop}`);
  }
  const evidence: LabelEvidence = {
    claims,
    statements: [],
    sources: [],
    unresolved: Array.from(unresolved).sort(),
  };

  // 1) PDF text layer → document extraction → label claims
  const extracted = applyLabelDocumentExtraction(evidence, CHATEAU_80647_ITEMS, DOC);
  // 2) authoritative merge (no AI uses: the label is the only authority here)
  const merged = mergeLabelEvidenceIntoUses([], extracted);
  // 3) registered-use normalisation — the handler's own stage
  const registered_uses = normaliseRegisteredUses(merged.uses);
  // 4) vineyard projection
  const projection = projectGrapevineUses(registered_uses);
  const structured: Structured = {
    registration,
    registered_uses,
    grapevine_uses: projection.grapevine_uses,
    other_crop_uses: projection.other_crop_uses,
  };
  // 5) identity minting against the LOCKED product
  applyRateIdentities(structured);
  return structured;
}

function grapevineUse(): any {
  const structured = runPipeline([
    { crop: "Grapevines", target_raw: "Annual ryegrass", statements: [] },
  ]);
  assertEquals(structured.grapevine_uses.length, 1, "one grapevine direction");
  return structured.grapevine_uses[0];
}

// ---------------------------------------------------------------------------
// §P1 — every additive field survives to the structured response
// ---------------------------------------------------------------------------

Deno.test("80647 pipeline §P1: every required field survives all five stages", () => {
  const use = grapevineUse();

  // --- the rate, still a range, still verbatim --------------------------
  assertEquals(use.rates.length, 1);
  const rate = use.rates[0];
  assertEquals(rate.basis, "range_per_hectare");
  assertEquals(rate.min_value, 560);
  assertEquals(rate.max_value, 700);
  assertEquals(rate.unit, "g");
  assertEquals(rate.raw_text, "560 – 700", "the printed wording reaches the client");

  // --- withholding: BOTH the number and the wording ----------------------
  assertEquals(use.withholding_period_days, 98);
  assertEquals(use.withholding_statement, WHP_STATEMENT);

  // --- re-entry: conditional rule, wording WITHOUT a number --------------
  // This is the distinction the whole `re_entry_statement` field exists for.
  // Null hours PLUS wording is "conditional re-entry"; null hours with NO
  // wording is "not stated". They must never render the same.
  assertEquals(use.re_entry_period_hours, null, "no hour count is invented");
  assertEquals(use.re_entry_statement, REI_STATEMENT);

  // --- restrictions, verbatim -------------------------------------------
  assert(typeof use.restrictions === "string" && use.restrictions.length > 0);
  assert(
    use.restrictions.includes("CHATEAU Herbicide needs at least 15 mm"),
    "the label's own critical comments survive",
  );

  // --- provenance: which source established these fields -----------------
  assert(use.provenance, "provenance survives normalisation");
  assertEquals(use.provenance.rates, "manufacturer_label");
  assertEquals(use.provenance.withholding_period, "manufacturer_label");
  assertEquals(use.provenance.re_entry, "manufacturer_label");
  assertEquals(use.provenance.restrictions, "manufacturer_label");

  // --- identities --------------------------------------------------------
  assert(typeof use.direction_id === "string" && use.direction_id.length > 0);
  assert(typeof rate.rate_id === "string" && rate.rate_id.length > 0);
});

Deno.test("80647 pipeline §P1b: the fields are present at EVERY stage, not just the last", () => {
  // Pinning the chain stage by stage, because a field can be dropped and then
  // coincidentally re-derived. Each of these was a real drop point.
  const claims: LabelUseClaim[] = [
    { crop: "Grapevines", target_raw: "Annual ryegrass", statements: [] },
  ];
  const evidence: LabelEvidence = {
    claims,
    statements: [],
    sources: [],
    unresolved: ["rates:Grapevines", "withholding_period:Grapevines"],
  };

  const extracted = applyLabelDocumentExtraction(evidence, CHATEAU_80647_ITEMS, DOC);
  assertEquals(extracted.claims[0].withholding_period_days, 98);
  assertEquals(extracted.claims[0].withholding_statement, WHP_STATEMENT);
  assertEquals(extracted.claims[0].re_entry_statement, REI_STATEMENT);

  const merged = mergeLabelEvidenceIntoUses([], extracted);
  assertEquals(merged.uses[0].withholding_statement, WHP_STATEMENT, "merge carries the wording");
  assertEquals(merged.uses[0].re_entry_statement, REI_STATEMENT);

  const normalised = normaliseRegisteredUses(merged.uses);
  assertEquals(
    normalised[0].withholding_statement,
    WHP_STATEMENT,
    "the handler normaliser carries the wording",
  );
  assertEquals(normalised[0].re_entry_statement, REI_STATEMENT);
  assert(normalised[0].provenance, "the handler normaliser carries provenance");
});

Deno.test("80647 pipeline §P1c: a conditionally-qualified rate keeps its ambiguity flag", () => {
  // CHATEAU's own rate is unqualified, so this is asserted directly against
  // the normaliser: a flag that is dropped presents a QUALIFIED rate as an
  // unqualified one, which is the dangerous direction.
  const normalised = normaliseRegisteredUses([
    {
      crop: "Grapevines",
      target_raw: "Botrytis",
      rates: [
        { basis: "per_hectare", value: 2, unit: "L", raw_text: "2 L/ha", condition_ambiguous: true },
        { basis: "per_hectare", value: 3, unit: "L", raw_text: "3 L/ha" },
      ],
    },
  ]);
  assertEquals(normalised[0].rates[0].condition_ambiguous, true, "the flag survives");
  assertEquals(
    normalised[0].rates[1].condition_ambiguous,
    undefined,
    "an unqualified rate is not flagged",
  );
});

// ---------------------------------------------------------------------------
// §P2 — server-minted identities, against the locked registration
// ---------------------------------------------------------------------------

Deno.test("80647 pipeline §P2: direction_id and rate_id are minted server-side against AU/apvma/80647", () => {
  const use = grapevineUse();

  // Versioned, server-minted, and shaped by the minter — not carried in from
  // the label, and not a client's invention.
  assert(
    use.direction_id.startsWith(`${DIRECTION_ID_VERSION}_`),
    `direction_id should be a ${DIRECTION_ID_VERSION} identity, got ${use.direction_id}`,
  );
  assert(
    use.rates[0].rate_id.startsWith(`${RATE_ID_VERSION}_`),
    `rate_id should be a ${RATE_ID_VERSION} identity, got ${use.rates[0].rate_id}`,
  );
});

Deno.test("80647 pipeline §P2b: identity is deterministic — the same label yields the same ids", () => {
  // Determinism is what makes a saved default rate still resolve after a
  // re-verification. If these ids moved, every stored `default_rates` entry
  // would dangle and the customer's confirmed rate would silently vanish.
  const first = grapevineUse();
  const second = grapevineUse();
  assertEquals(first.direction_id, second.direction_id);
  assertEquals(first.rates[0].rate_id, second.rates[0].rate_id);
});

Deno.test("80647 pipeline §P2c: identity is PRODUCT-BOUND — a different registration mints different ids", () => {
  // The same printed direction under a different registration is a different
  // operational thing. If ids ignored the product, one product's confirmed
  // rate could resolve against another's.
  const claims: LabelUseClaim[] = [
    { crop: "Grapevines", target_raw: "Annual ryegrass", statements: [] },
  ];
  const mine = runPipeline(claims);
  const other = runPipeline(claims, { ...REGISTRATION, registration_number: "99999" });

  assert(
    mine.grapevine_uses[0].direction_id !== other.grapevine_uses[0].direction_id,
    "direction identity is bound to the registration",
  );
  assert(
    mine.grapevine_uses[0].rates[0].rate_id !== other.grapevine_uses[0].rates[0].rate_id,
    "rate identity is bound to the registration",
  );
});

// ---------------------------------------------------------------------------
// §P3 — the vineyard projection shows grapevines only, and stays safe
// ---------------------------------------------------------------------------

Deno.test("80647 pipeline §P3: the projection is grapevine-only and carries no other crop's period", () => {
  const structured = runPipeline([
    { crop: "Grapevines", target_raw: "Annual ryegrass", statements: [] },
    { crop: "Macadamia nuts", target_raw: "Annual ryegrass", statements: [] },
  ]);

  assertEquals(structured.grapevine_uses.length, 1);
  assertEquals(structured.grapevine_uses[0].crop, "Grapevines");
  assertEquals(structured.grapevine_uses[0].withholding_period_days, 98);

  // Macadamia is retained on the record but is NOT part of the vineyard view,
  // and above all does not contribute its 63 days to the grapevine use.
  assert(
    structured.other_crop_uses.some((u: any) => /macadamia/i.test(u.crop)),
    "the other crop is retained, not deleted",
  );
  for (const use of structured.grapevine_uses) {
    assert(
      use.withholding_period_days !== 63,
      "macadamia's period never reaches the vineyard projection",
    );
  }
});
