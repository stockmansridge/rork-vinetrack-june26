// Deterministic EVIDENCE fixture for THIOVIT JET (APVMA 53904).
//
// # Why this fixture is shaped as evidence, not as PDF text items
//
// `label_fixture_33182_apvma.ts` captures a `PdfTextItem[]` text layer because
// the 33182 eLabel PDF was retrievable and its GLYPHS were the defect under
// test. That is not the situation here.
//
// The authoritative 53904 label document HAS been fetched — by VineTrack, in
// production, on 2026-08-26 (see `THIOVIT_53904_LABEL_DOCUMENT_EVIDENCE`) —
// but the PDF bytes are not reachable from the test sandbox: `syngenta.com.au`
// answers 403 behind a bot-protection interstitial and `elabels.apvma.gov.au`
// PDF paths answer http=000 (the SAME failure the already-captured 33182
// eLabel URL now shows, so it is an environment block, not an absent
// document). Re-extracting a text layer here would therefore mean inventing
// one, and an invented text layer is not evidence.
//
// So this fixture freezes what IS authoritatively established: the identity,
// the document's own hash and size, the product measurement facts, and the
// EXPECTED direction structure — the last of these being the whole point,
// because the current implementation collapses it.
//
// # The defect this fixture exists to make un-"fixable"-by-accident
//
// The live master row projects the two printed grape Powdery Mildew
// directions into ONE `GRAPE` use carrying BOTH rates, both flagged
// `condition_ambiguous`, with the critical comments of both printed contexts
// concatenated into a single restrictions string. The label prints them as two
// materially different registered uses:
//
//   table grapes / fruit destined for drying   100-200 g/100 L
//   wine grapes only                           200-600 g/100 L
//
// Freezing the EXPECTED structure here means a later change cannot satisfy
// this suite by preserving the collapsed output.
//
// NOTHING in this file asserts that the implementation currently behaves this
// way. `THIOVIT_53904_EXPECTED_GRAPE_DIRECTIONS` is the label's truth;
// `THIOVIT_53904_ACTUAL_GRAPE_PROJECTION` is what production emits today. The
// accompanying test pins the difference as a known defect.

/** Registered identity. Stable; independent of current legal status. */
export const THIOVIT_53904_IDENTITY = {
  registration_identity_key: "AU:apvma:53904",
  registration_number: "53904",
  registration_scheme: "apvma",
  registration_country: "AU",
  registered_product_name: "THIOVIT JET MICROGRANULE FUNGICIDE/MITICIDE",
  registrant: "SYNGENTA AUSTRALIA PTY LTD",
} as const;

/**
 * The live VineTrack `master_chemicals` row, queried independently.
 *
 * Recorded verbatim. `product_category: null` is preserved as null — a
 * category is NOT invented to make the fixture look complete.
 */
export const THIOVIT_53904_MASTER_RECORD_EVIDENCE = {
  retrieved_at: "2026-08-26T02:46:51Z",
  form_type: "solid",
  product_category: null,
  activity_groups: ["M2"],
  active_ingredient: "Sulfur As Elemental Sulfur",
  concentration_text: "800 g/kg",
  label_version: "APVMA label approval 135412, approval date 17/06/2022",
  label_reference: "APVMA eLabels product 53904",
  verification_status: "partially_verified",
} as const;

/**
 * Provenance of the AUTHORITATIVE label document, as captured in production.
 *
 * This is what makes the label evidence deterministic despite the sandbox
 * being unable to re-fetch it: the document is identified by content hash.
 */
export const THIOVIT_53904_LABEL_DOCUMENT_EVIDENCE = {
  source: "APVMA eLabels",
  fetched_at: "2026-08-26T02:45:55Z",
  byte_size: 289840,
  sha256: "91baafb160706a46497ef517968f707153d7b8cea1b37c9fcce3f240381c7ce0",
} as const;

/**
 * CORROBORATING ONLY — a historical third-party mirror of the 53904 label,
 * retrieved and text-extracted during the Phase 2B audit.
 *
 * Filename implies a 2006 revision. It is NEVER the current label and must
 * never be presented as such; it is recorded because the direction STRUCTURE
 * frozen below was read verbatim from it and corroborated against the current
 * master row's rates.
 */
export const THIOVIT_53904_HISTORICAL_LABEL_EVIDENCE = {
  source_url: "https://www.herbiguide.com.au/Labels/SULP800_53904-0406.PDF",
  retrieved_at: "2026-08-28",
  byte_size: 47859,
  sha256: "12708ff37dd4b8bf0d3016be84c9d24f335d2e8a19532ebcb386392e0e6feaaa",
  pages: 4,
  printed_activity_group: "GROUP Y FUNGICIDE",
  approval_lines: [
    "APVMA Approval No: 53904/25/0603 Pack size: 25 kg",
    "APVMA Approval No: 53904/15/0406 Pack size: 15 kg",
  ],
  authority: "corroborating_only",
} as const;

/**
 * The five measurement concepts, held APART on purpose.
 *
 * A 500 g/100 L rate is not evidence of a liquid product. `rate_unit` and
 * `physical_form` are different questions with different sources, and this
 * shape exists so a future change cannot quietly derive one from the other.
 */
export const THIOVIT_53904_PRODUCT_MEASUREMENT = {
  /**
   * CANONICAL BACKEND PROVENANCE: `official_register`.
   *
   * Corrected in Phase 3A. The earlier `manufacturer_primary` attribution was
   * wrong about the BACKEND: the APVMA adapter deterministically maps the
   * register's own `fdesc` field (`mapFormType`, apvma.ts:150), and the live
   * PubCRIS row for 53904 publishes `fdesc = "MICROGRANULE"`, which that
   * mapper resolves to "solid" with no AI and no manufacturer input involved.
   *
   * The manufacturer label independently prints "MICROGRANULE" too, so the
   * two agree — but agreement is CORROBORATION, not the primary source.
   * Freezing the manufacturer as primary would have recorded false provenance
   * and implied the register was silent when it is not.
   *
   * NOT derived from rate units, under either provenance.
   */
  physical_form: "solid",
  physical_form_provenance: "official_register",
  /** The register field the canonical form is mapped from. */
  physical_form_register_field: "fdesc",
  physical_form_register_value: "MICROGRANULE",
  /** Independent agreement, not the primary source. */
  physical_form_corroboration: "manufacturer_label prints MICROGRANULE",
  /** Source wording preserved separately from the canonical form. */
  formulation_text: "microgranule / water-dispersible granule",
  active_ingredient: "Sulfur As Elemental Sulfur",
  active_concentration: 800,
  active_concentration_unit: "g/kg",
  /** Container/inventory unit, from the label's own pack-size statements. */
  inventory_unit: "kg",
  /** Application-rate unit as PRINTED in the directions table. */
  rate_unit: "g",
  /** Application-rate basis as PRINTED. */
  rate_basis: "per_100_litres",
} as const;

/**
 * Registration legal status — raw official facts kept SEPARATE from any
 * semantic conclusion.
 *
 * The expiry has passed as of the audit date, but "expired" is NOT derived
 * from a clock, and the published "R" is not overwritten either. Label content
 * and legal status are independent evidence dimensions, so this ambiguity does
 * NOT block the label fixture.
 */
export const THIOVIT_53904_REGISTRATION_STATUS = {
  registration_code_raw: "R",
  registration_expiry_raw: "30/06/2026",
  semantic_status: "UNRESOLVED_CURRENT_STATUS",
  resolution_requires: "fresh PubCRIS renewal-status source",
} as const;

/**
 * Withholding period.
 *
 * The LEGAL truth is the wording. `days: 0` is the existing conservative
 * projection of "not required", and the wording must survive alongside it —
 * reducing the legal meaning to the bare number loses the "when used as
 * directed" condition.
 */
export const THIOVIT_53904_WHP = {
  statement: "WITHHOLDING PERIODS: NOT REQUIRED WHEN USED AS DIRECTED",
  display_wording: "Not required when used as directed",
  projected_days: 0,
} as const;

/**
 * Re-entry interval.
 *
 * The label text carries no re-entry statement at all (zero occurrences of
 * "RE-ENTRY"/"REENTRY" in the extracted historical text), and the current
 * master row lists `re_entry_period_hours` among its unresolved fields. AWRI
 * publishes re-entry CODE "a" for this product, but no authoritative
 * code->hours mapping exists in this repository, so the code is recorded and
 * NOT resolved.
 *
 * Unresolved is the answer. It is not 0, not "no REI", not "safe immediately".
 */
export const THIOVIT_53904_REI = {
  hours: null,
  statement: null,
  awri_re_entry_code: "a",
  resolution: "unresolved_not_stated",
} as const;

/** One printed label direction, with every identity dimension it states. */
export interface ExpectedLabelDirection {
  /** The crop/use CONTEXT cell, verbatim. Part of identity. */
  crop_context: string;
  /** Every target the one printed direction names. */
  targets: string[];
  /**
   * The State column, verbatim.
   *
   * The wire contract has NO field for this today — that absence is the
   * defect. It is held here because a direction's jurisdiction is part of what
   * the regulator approved.
   */
  state_applicability: string;
  basis: "range_per_100_litres" | "per_100_litres";
  min_value?: number;
  max_value?: number;
  value?: number;
  unit: "g";
  /** Critical Comments for THIS direction only — never the union of two. */
  critical_comments: string;
}

/**
 * The AUTHORITATIVE grape direction structure.
 *
 * Four directions across TWO distinct crop contexts. Read verbatim from the
 * historical label's Directions for Use table and corroborated by the current
 * master row's rate values (500, 100-200, 200-600 g/100 L).
 *
 * The two Powdery Mildew entries are NOT duplicates: different crop context,
 * different rate range, different spray interval, different conditions.
 */
export const THIOVIT_53904_EXPECTED_GRAPE_DIRECTIONS: ExpectedLabelDirection[] = [
  {
    crop_context: "Grapes table grapes, fruit destined for drying",
    targets: ["Vine Mite", "Grapeleaf Blister Mite"],
    state_applicability: "NSW, Vic, Tas, SA, WA only",
    basis: "per_100_litres",
    value: 500,
    unit: "g",
    critical_comments: "Apply before sprouting. Ensure thorough coverage.",
  },
  {
    crop_context: "Grapes table grapes, fruit destined for drying",
    targets: ["Powdery Mildew (Oidium spp)", "Mites"],
    state_applicability: "NSW, Vic, Tas, SA, WA only",
    basis: "range_per_100_litres",
    min_value: 100,
    max_value: 200,
    unit: "g",
    critical_comments:
      "Apply immediately after budburst, then every 2 to 3 weeks or as required. Ensure thorough coverage.",
  },
  {
    crop_context: "Grapes Vines wine grapes only",
    targets: ["Vine Mite", "Grapeleaf Blister Mite"],
    state_applicability: "NSW, Vic, Tas, SA, WA only",
    basis: "per_100_litres",
    value: 500,
    unit: "g",
    critical_comments: "Apply before sprouting. Ensure thorough coverage.",
  },
  {
    crop_context: "Grapes Vines wine grapes only",
    targets: ["Powdery Mildew (Oidium spp)", "Mites"],
    state_applicability: "NSW, Vic, Tas, SA, WA only",
    basis: "range_per_100_litres",
    min_value: 200,
    max_value: 600,
    unit: "g",
    critical_comments:
      "Use rates to the upper end of the rate range when disease pressure is high and/or a higher degree of control is required. Apply immediately after bud burst, then every 14 to 21 days or as required.",
  },
];

/**
 * What production ACTUALLY projects today, from the live master row.
 *
 * Recorded so the divergence is testable. This is the DEFECT, not the target.
 */
export const THIOVIT_53904_ACTUAL_GRAPE_PROJECTION = {
  crop: "GRAPE",
  uses: [
    { target_raw: "Grapeleaf Blister Mite", rates: [{ basis: "per_100_litres", value: 500, unit: "g" }] },
    { target_raw: "Vine Mite", rates: [{ basis: "per_100_litres", value: 500, unit: "g" }] },
    {
      target_raw: "Powdery Mildew",
      rates: [
        { basis: "range_per_100_litres", min_value: 100, max_value: 200, unit: "g", condition_ambiguous: true },
        { basis: "range_per_100_litres", min_value: 200, max_value: 600, unit: "g", condition_ambiguous: true },
      ],
      /** Comments from BOTH printed contexts, concatenated. */
      restrictions_are_concatenated_from_both_contexts: true,
    },
  ],
  /** No state applicability survives anywhere in the projection. */
  state_applicability_present: false,
} as const;

/**
 * The LIVE PubCRIS product row for pcode 53904, recorded verbatim.
 *
 * Retrieved during the Phase 3A audit directly from the APVMA-published
 * dataset on data.gov.au (resource `b4bb5394-b60b-4602-8bde-2e206ffc498f`,
 * the same resource id the adapter itself queries), HTTP 200, one record.
 *
 * This is the raw material for the whole form/category audit, so it is frozen
 * verbatim rather than summarised — including the fields the adapter does not
 * currently read.
 */
export const THIOVIT_53904_PUBCRIS_PRODUCT_ROW = {
  retrieved_at: "2026-08-28",
  pcode: "53904",
  prodtype: "A",
  psched: "0",
  regdate: "1/07/2025 0:00",
  fdesc: "MICROGRANULE",
  typedesc: "A - Agricultural",
  hlevel1: "MIXED FUNCTION PESTICIDE",
  fpname: "THIOVIT JET MICROGRANULE FUNGICIDE/MITICIDE",
  sname: "SYNGENTA AUSTRALIA PTY LTD",
  regcode: "R",
  expdate: "30/06/2026 0:00",
  scode1: "SYNG1",
} as const;

/**
 * CORRECTED in Phase 3A. The Phase 2B claim that PubCRIS formulation/category
 * fields are "not consumed" was WRONG and is withdrawn.
 *
 * `fdesc` and `hlevel1` are both already consumed deterministically by the
 * APVMA adapter. The real category defect is narrower and quite different: the
 * field IS read, and its value is simply outside the mapper's vocabulary.
 */
export const THIOVIT_53904_PUBCRIS_FIELD_AUDIT = {
  fdesc: {
    raw_value: "MICROGRANULE",
    consumed_by: "apvma.ts mapFormType()",
    result: "solid",
    status: "already_consumed",
  },
  hlevel1: {
    raw_value: "MIXED FUNCTION PESTICIDE",
    consumed_by: "apvma.ts mapCategory()",
    result: null,
    status: "already_consumed_but_unmapped_vocabulary",
    note:
      "mapCategory recognises FUNGICIDE/HERBICIDE/INSECTICIDE/MITICIDE/" +
      "ACARICIDE/GROWTH REGULATOR/ADJUVANT/SURFACTANT. The register's own " +
      "combined classification 'MIXED FUNCTION PESTICIDE' contains none of " +
      "them, so the mapper correctly declines rather than guessing.",
  },
  prodtype: {
    raw_value: "A",
    exists_in_dataset: true,
    consumed_by: null,
    provides_category: false,
    note:
      "The agricultural/veterinary axis, not a pesticide FUNCTION. Its " +
      "expansion is typedesc. Useless as a category source.",
  },
  typedesc: {
    raw_value: "A - Agricultural",
    exists_in_dataset: true,
    consumed_by: null,
    provides_category: false,
    note:
      "The human-readable expansion of prodtype. Distinguishes agricultural " +
      "from veterinary products; says nothing about fungicide vs miticide. " +
      "Auditing these two fields answers the Phase 2B question NEGATIVELY: " +
      "they are NOT a better deterministic category source.",
  },
} as const;

/**
 * The ACTUAL projected rows in served wire shape, for gate execution.
 *
 * Deliberately the shape `statesCalculableGrapevineRate()` and the ingest
 * merge actually receive, so the routing gate can be executed against them
 * rather than reasoned about.
 */
export const THIOVIT_53904_ACTUAL_REGISTERED_USE_ROWS: Record<string, unknown>[] = [
  {
    crop: "GRAPE",
    target: "Powdery Mildew",
    rates: [
      {
        label: "",
        basis: "range_per_100_litres",
        min_value: 100,
        max_value: 200,
        unit: "g",
        raw_text: "100-200 g/100 L",
        condition_ambiguous: true,
      },
      {
        label: "",
        basis: "range_per_100_litres",
        min_value: 200,
        max_value: 600,
        unit: "g",
        raw_text: "200-600 g/100 L",
        condition_ambiguous: true,
      },
    ],
    withholding_period_days: 0,
    re_entry_period_hours: null,
    restrictions: null,
  },
];
