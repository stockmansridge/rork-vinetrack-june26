// Gate D4A.3 — authoritative label LAYOUT fallback.
//
// # The production defect this exists to remove
//
// The authoritative APVMA eLabel for 33182 (VICOL WINTER OIL INSECTICIDE,
// sha256 b55905a2…) served this to the app:
//
//   registered_uses:      4 grapevine rows
//   label_rate_bases:     ["other"]
//   grapevine rate cell:  "2 L / 1OO L 3 L / 1OO L 3 L / 1OO L 2 L / 1OO L"
//   default_rate_options: { per_hectare: [], per_100_litres: [] }
//
// Two INDEPENDENT faults produced that, and repairing either one alone would
// have been worse than repairing neither:
//
//   1. The embedded font emits "1OO" (capital letter O) where the label prints
//      100. `SINGLE_100L_RE` looks for a literal "100", so every rate on the
//      label fell through to `basis: "other"`.
//
//   2. The table prints an explicit STATE column and `classifyHeader` in
//      `label_extract.ts` returns "ignored" for it. The state IS the condition
//      separating 2 L/100 L from 3 L/100 L, so four printed directions
//      collapsed into a single cell.
//
// Fixing only the glyph would have turned that one collapsed cell into a
// CALCULABLE multi-rate cell — 2 L and 3 L presented as one direction, with
// the Tasmania/mainland association destroyed rather than merely missing. D4A
// would then have looked functional while persisting wrong provenance, which
// is the single worst outcome available here. So this module routes the
// document to a parser that reads the state column, and the glyph repair
// arrives as part of that parser's existing behaviour.
//
// # Why this is not a third parser
//
// It is a ROUTER. `extractManufacturerLabelUses` already reads a state-aware
// DFU table by column anchors, already derives its own right-hand boundary
// (returning `Infinity` when a page has no second column — the full-width
// case), and already folds digit glyphs. Nothing about it is specific to a
// registrant's host; the module was simply born on a manufacturer document.
// Re-implementing its geometry here would create a third interpretation of
// "what a printed direction is" and the three would drift.
//
// # Authority is NOT what changes here
//
// This picks a PARSER, never a source. A document discovered from APVMA
// eLabels remains regulator-approved authoritative label evidence after being
// read by a parser whose code happens to live in `manufacturer_label.ts`.
// Parser type and evidence authority are orthogonal, and nothing in this file
// touches provenance, `field_provenance`, sources, or identity inputs.

import type { PdfTextItem, WireLabelRate } from "./contract.ts";
import {
  detectStateAwareDfu,
  extractManufacturerLabelUses,
  manufacturerUsesToRegisteredUses,
  type StateAwareDfuGeometry,
} from "./manufacturer_label.ts";
import { isGrapevineCrop } from "../grapevine_label.ts";
import {
  DIRECTION_SEED_KEY,
  mintDirectionId,
  type RateIdentityProduct,
} from "../rate_identity.ts";

/** Why the fallback did or did not replace the ordinary parse. */
export type PanelFallbackOutcome =
  /** The ordinary eLabel parse already stated usable grapevine rates. */
  | "not_needed"
  /** The document does not print a state-aware DFU table. */
  | "geometry_absent"
  /** Geometry matched but the parse produced no usable grapevine rate. */
  | "parse_unusable"
  /** The state-aware parse replaced a grapevine result that had no rates. */
  | "applied";

export interface PanelFallbackResult {
  outcome: PanelFallbackOutcome;
  /** Replacement use rows — populated ONLY when `outcome` is "applied". */
  uses: Record<string, unknown>[];
  geometry: StateAwareDfuGeometry;
  /** Plain-language audit line, surfaced in diagnostics. */
  reason: string;
}

/** Periods that may be carried across a re-read, each resolved independently. */
const CARRIED_PERIOD_FIELDS = [
  "withholding_period_days",
  "re_entry_period_hours",
] as const;

type CarriedPeriodField = typeof CARRIED_PERIOD_FIELDS[number];

/**
 * The ONE value the original rows agree on for a crop's period, or null.
 *
 * # Why unanimity, and not "the first one found"
 *
 * Taking the first numeric value would make the result depend on array order
 * — a property of how rows happened to be assembled, not of what the label
 * says. On a label that scopes periods per direction, two grapevine rows can
 * legitimately carry DIFFERENT withholding periods, and picking whichever
 * sorted first would silently attach one direction's period to every other
 * direction. That is fabricated provenance, which is worse than an absent
 * period: an operator can see a blank and go read the label, but cannot see
 * that a number belongs to a different row.
 *
 * So: exactly one distinct value carries; zero carries nothing; more than one
 * carries nothing and the disagreement is left visible as a gap. Nulls and
 * non-numerics are ignored rather than counted as a competing value — "not
 * stated here" does not contradict "stated there".
 */
/**
 * Do two crop wordings name the same crop for the purpose of carrying a
 * period?
 *
 * Exact (normalised) wording, OR both being grapevine crops.
 *
 * # Why the second clause is required rather than lenient
 *
 * A re-read REPLACES the rows, and the two readings name the crop with
 * different words for the same vines: the register publishes the host as
 * "GRAPE", while the label itself prints "Grapes table grapes, fruit destined
 * for drying". Under exact matching those never correspond, so replacing the
 * rows would silently drop a withholding period the lookup already held —
 * precisely the loss `carryForwardStatedPeriods` exists to prevent, reopened
 * by the repair.
 *
 * `isGrapevineCrop` is the SAME predicate the routing gate and D4A use to
 * decide which rows are grapevine at all, so no new crop vocabulary is
 * introduced. The unanimity rule is untouched and still does the real safety
 * work: if two grapevine directions state DIFFERENT periods, the widened
 * match makes them disagree and therefore carries NOTHING, which is the
 * conservative answer. It can only ever fill a gap from a value every
 * grapevine row already agreed on.
 */
function cropsCorrespond(a: unknown, b: unknown): boolean {
  const norm = (value: unknown): string => String(value ?? "").trim().toLowerCase();
  if (norm(a) === norm(b)) return true;
  return isGrapevineCrop(String(a ?? "")) && isGrapevineCrop(String(b ?? ""));
}

function unanimousPeriod(
  original: readonly Record<string, unknown>[],
  crop: unknown,
  field: CarriedPeriodField,
): number | null {
  const distinct = new Set<number>();
  for (const use of original) {
    if (!cropsCorrespond(use?.crop, crop)) continue;
    const value = use?.[field];
    // Number.isFinite excludes NaN/Infinity, which are not periods.
    if (typeof value === "number" && Number.isFinite(value)) distinct.add(value);
  }
  return distinct.size === 1 ? [...distinct][0] : null;
}

/**
 * Carry the register's stated withholding / re-entry periods onto re-read
 * rows that do not state their own.
 *
 * The state-aware parse establishes RATES and their conditions; it says
 * nothing about withholding periods the register already published. Replacing
 * the rows wholesale without this would silently drop a WHP the operator had
 * a moment ago — trading one missing fact for another.
 *
 * Three guarantees:
 *
 *   * a period the re-read genuinely states is NEVER overwritten;
 *   * a null is filled only from a value the original rows UNANIMOUSLY agree
 *     on for that crop (see {@link unanimousPeriod});
 *   * the two fields are resolved INDEPENDENTLY — an unambiguous re-entry
 *     period still carries when the withholding periods disagree, because
 *     they are separate facts and one being contested says nothing about the
 *     other.
 *
 * Pure: neither input array nor any row object is mutated.
 */
export function carryForwardStatedPeriods(
  rows: readonly Record<string, unknown>[],
  original: readonly Record<string, unknown>[],
): Record<string, unknown>[] {
  return rows.map((row) => {
    const next = { ...row };
    for (const field of CARRIED_PERIOD_FIELDS) {
      // Only ever fills an absent value. A stated period stands as stated.
      if (next[field] !== null && next[field] !== undefined) continue;
      const carried = unanimousPeriod(original, next.crop, field);
      if (carried !== null) next[field] = carried;
    }
    return next;
  });
}

/** Does this rate state something an operator could actually spray by? */
export function rateIsCalculable(rate: unknown): boolean {
  const r = rate as Partial<WireLabelRate> | null;
  if (!r || typeof r !== "object") return false;
  if (!r.basis || r.basis === "other") return false;
  // A basis with no number behind it is not calculable either.
  return typeof r.value === "number" ||
    typeof r.min_value === "number" ||
    typeof r.max_value === "number";
}

/**
 * Do these rows state a calculable GRAPEVINE rate?
 *
 * Grapevine specifically, using the SAME predicate D4A uses to decide which
 * uses may become options (`isGrapevineCrop`). A product whose pome-fruit
 * rates parsed perfectly while its grapevine rates collapsed is exactly the
 * case this gate is about, so a whole-document test would have missed it.
 */
export function statesCalculableGrapevineRate(
  uses: readonly Record<string, unknown>[],
): boolean {
  return uses.some((u) => {
    if (!isGrapevineCrop(String(u?.crop ?? ""))) return false;
    const rates = Array.isArray(u?.rates) ? u.rates : [];
    return rates.some(rateIsCalculable);
  });
}

// ---------------------------------------------------------------------------
// Gate D4A.3.2 — direction-identity loss, and whether a candidate repairs it
//
// # Why "calculable" was never the whole question
//
// THIOVIT JET MICROGRANULAR SULFUR (APVMA 53904) exposed the second half of
// the problem D4A.3 only half-solved. Its eLabel prints two grapevine
// directions for Powdery Mildew — table/drying grapes at 100–200 g/100 L and
// wine grapes at 200–600 g/100 L — and the ordinary parse serves them as ONE
// use carrying two unexplained rates, each flagged `condition_ambiguous`.
//
// Both numbers are numerically perfect. `statesCalculableGrapevineRate` is
// therefore true, D4A.3's gate concludes the parse works, and the state-aware
// re-read never runs. The rates are right and their BINDING is destroyed:
//
//   CALCULABLE != CORRECTLY BOUND.
//
// # Why this cannot simply be "more than one rate on a basis"
//
// That was the tempting signal and it is wrong. VineTrack legitimately serves
// labels that print several rates on ONE basis for ONE direction — low and
// high disease pressure, early and late season, dilute and concentrate. Those
// labels are healthy, their rates are individually labelled, and routing them
// through a fallback because "several numbers exist" would break working
// products in order to fix a broken one. Complexity is not damage.
//
// So the only signal used is the parser's OWN admission that it could not
// prove which condition governs which number. That flag is set by
// `flagAmbiguousConditions` in `label_extract.ts` at the moment the binding
// is lost, from the document's own grammar — it is positive evidence already
// present in the served data, not an inference drawn from shape.
// ---------------------------------------------------------------------------

/** Every rate row belonging to a grapevine use, flattened. */
function grapevineRates(
  uses: readonly Record<string, unknown>[],
): Record<string, unknown>[] {
  const out: Record<string, unknown>[] = [];
  for (const use of uses) {
    if (!isGrapevineCrop(String(use?.crop ?? ""))) continue;
    const rates = Array.isArray(use?.rates) ? use.rates : [];
    for (const rate of rates) {
      if (rate && typeof rate === "object") out.push(rate as Record<string, unknown>);
    }
  }
  return out;
}

/** Grapevine use rows only — the scope every comparison below operates in. */
function grapevineUses(
  uses: readonly Record<string, unknown>[],
): Record<string, unknown>[] {
  return uses.filter((u) => isGrapevineCrop(String(u?.crop ?? "")));
}

/**
 * Does the ordinary projection carry POSITIVE evidence that it lost the
 * binding between a rate and the condition that governs it?
 *
 * True only when a grapevine rate is BOTH calculable and flagged
 * `condition_ambiguous`. Both halves matter: an uncalculable ambiguous rate is
 * already handled by the original D4A.3 gate (which asks whether any rate is
 * calculable at all), and a calculable unflagged rate is a working direction.
 * The pairing is precisely the Thiovit shape — real numbers whose ownership
 * the parser could not establish.
 *
 * Deliberately NOT evidence, because none of these prove damage:
 *
 *   * several rates on a use, or on one basis (legitimate pressure/season
 *     bands — see the module note above);
 *   * several targets (one direction routinely names several pests);
 *   * a range (a range is one direction's rate, not two collapsed ones);
 *   * a missing condition (plenty of labels state none).
 *
 * Pure, deterministic, no AI, no product-specific logic.
 */
export function ordinaryHasDirectionIdentityLoss(
  uses: readonly Record<string, unknown>[],
): boolean {
  return grapevineRates(uses).some(
    (rate) => rateIsCalculable(rate) && rate?.condition_ambiguous === true,
  );
}

/**
 * A rate's MEANING, for the preservation check.
 *
 * Built only from fields that carry regulatory sense — basis, unit and the
 * numbers — so two readings of the same printed rate compare equal even when
 * they arrive in a different order, from a different parser, with different
 * ids. Explicitly excludes array index, database UUID, `rate_id` and display
 * ordering: comparing on any of those would make "did we keep this rate?"
 * depend on how the rows happened to be assembled.
 *
 * `label` is excluded too — the state-aware parser fills it with the direction
 * condition precisely BECAUSE the ordinary parse could not, so requiring it to
 * match would make every successful repair look like a loss.
 */
function rateSemanticSignature(rate: Record<string, unknown>): string {
  const num = (v: unknown): string =>
    typeof v === "number" && Number.isFinite(v) ? String(v) : "-";
  const text = (v: unknown): string =>
    String(v ?? "").trim().toLowerCase().replace(/\s+/g, " ");
  return [
    text(rate.basis),
    text(rate.unit),
    num(rate.value),
    num(rate.min_value),
    num(rate.max_value),
  ].join("|");
}

/**
 * This row's direction identity, using the EXISTING identity system.
 *
 * Order of preference, all three reusing `mintDirectionId`'s algorithm:
 *
 *   1. a `direction_id` already stamped on the row — minted by the projection
 *      while the direction still held its complete target set, which is the
 *      authoritative moment and must never be re-derived after fan-out;
 *   2. the identity SEED a projection leaves when the product was not yet
 *      locked, minted now that a product is available;
 *   3. otherwise the row's own meaning, in the degenerate single-target form
 *      `RateIdentityDirection` already defines for projected rows.
 *
 * No new identity algorithm, and nothing here depends on array position, a
 * database UUID or client platform.
 */
function rowDirectionIdentity(
  row: Record<string, unknown>,
  product: RateIdentityProduct | null,
): string {
  const stamped = row?.direction_id;
  if (typeof stamped === "string" && stamped.trim().length > 0) return stamped;

  const seed = row?.[DIRECTION_SEED_KEY] as
    | { crop?: unknown; targets?: unknown; condition?: unknown }
    | undefined;
  if (seed && typeof seed === "object") {
    return mintDirectionId(product, {
      crop: seed.crop == null ? null : String(seed.crop),
      targets: Array.isArray(seed.targets) ? seed.targets.map((t) => String(t)) : null,
      condition: seed.condition == null ? null : String(seed.condition),
    });
  }

  return mintDirectionId(product, {
    crop: row?.crop == null ? null : String(row.crop),
    // The degenerate single-target form the identity contract already defines
    // for already-projected rows — not a new identity input.
    target_raw: row?.target == null ? null : String(row.target),
    condition: row?.condition == null ? null : String(row.condition),
  });
}

/** Distinct direction identities across a set of grapevine rows. */
function distinctDirectionIds(
  uses: readonly Record<string, unknown>[],
  product: RateIdentityProduct | null,
): Set<string> {
  return new Set(grapevineUses(uses).map((row) => rowDirectionIdentity(row, product)));
}

/** The outcome of comparing a candidate against the ordinary projection. */
export interface DirectionIdentityComparison {
  /** Whether the candidate proved itself STRICTLY better on every check. */
  improves: boolean;
  /** Which check settled it, for diagnostics and tests. */
  check:
    | "panel_not_calculable"
    | "no_identity_loss"
    | "panel_identity_unusable"
    | "not_more_directions"
    | "rate_evidence_lost"
    | "panel_still_ambiguous"
    | "strictly_better";
  ordinaryDirectionCount: number;
  panelDirectionCount: number;
  /** Rate signatures the ordinary parse stated and the candidate dropped. */
  lostRateSignatures: string[];
  reason: string;
}

/**
 * May this candidate replace a CALCULABLE ordinary result?
 *
 * The bar is deliberately higher than "the candidate is also readable". A
 * working parse is the thing being displaced, so the candidate must prove it
 * is strictly better on SIX independent counts, every one of them
 * deterministic and computed from data already present:
 *
 *   A. the candidate states calculable grapevine rates;
 *   B. the ordinary result shows positive direction-identity loss;
 *   C. every candidate grapevine row carries a usable direction identity;
 *   D. the candidate holds MORE distinct direction identities than the
 *      ordinary projection — the actual repair being claimed;
 *   E. the candidate loses NO calculable rate the ordinary parse stated;
 *   F. the candidate's own rates are not themselves condition-ambiguous.
 *
 * E is what stops a "cleaner" parse from quietly costing the operator a rate:
 * a result with better structure and fewer numbers is not better. F is what
 * stops one unproven association being swapped for another — if the candidate
 * cannot bind its own conditions either, nothing has been repaired and the
 * original evidence stands.
 *
 * Any failure leaves the ordinary result in place. Pure; no AI; no
 * product-specific logic.
 */
export function panelStrictlyImprovesDirectionIdentity(input: {
  ordinaryUses: readonly Record<string, unknown>[];
  panelUses: readonly Record<string, unknown>[];
  /** The LOCKED registered product, for minting comparable identities. */
  product?: RateIdentityProduct | null;
}): DirectionIdentityComparison {
  const product = input.product ?? null;
  const ordinaryIds = distinctDirectionIds(input.ordinaryUses, product);
  const panelIds = distinctDirectionIds(input.panelUses, product);
  const base = {
    ordinaryDirectionCount: ordinaryIds.size,
    panelDirectionCount: panelIds.size,
    lostRateSignatures: [] as string[],
  };

  // (A) A candidate that cannot state a usable rate repairs nothing.
  if (!statesCalculableGrapevineRate(input.panelUses)) {
    return {
      ...base,
      improves: false,
      check: "panel_not_calculable",
      reason:
        "the candidate re-read states no calculable grapevine rate, so it " +
        "cannot displace a parse that does",
    };
  }

  // (B) Without positive evidence of loss there is nothing to repair, and a
  // merely different reading must never win.
  if (!ordinaryHasDirectionIdentityLoss(input.ordinaryUses)) {
    return {
      ...base,
      improves: false,
      check: "no_identity_loss",
      reason:
        "the ordinary parse shows no direction-identity loss; a working parse " +
        "is never displaced by an alternative reading of the same document",
    };
  }

  // (C) Identities must exist to be compared at all.
  const panelRows = grapevineUses(input.panelUses);
  const panelIdentitiesUsable = panelRows.length > 0 &&
    panelRows.every((row) => {
      const id = rowDirectionIdentity(row, product);
      return typeof id === "string" && id.trim().length > 0;
    });
  if (!panelIdentitiesUsable) {
    return {
      ...base,
      improves: false,
      check: "panel_identity_unusable",
      reason: "the candidate rows carry no usable direction identity",
    };
  }

  // (D) The repair claim itself: more distinct printed directions survive.
  if (panelIds.size <= ordinaryIds.size) {
    return {
      ...base,
      improves: false,
      check: "not_more_directions",
      reason:
        `the candidate distinguishes ${panelIds.size} grapevine direction(s) ` +
        `against the ordinary parse's ${ordinaryIds.size}; without strictly ` +
        "more it is a different reading, not a repair",
    };
  }

  // (E) Structure may improve; evidence may not shrink.
  const panelSignatures = new Set(
    grapevineRates(input.panelUses).map(rateSemanticSignature),
  );
  const lost = [
    ...new Set(
      grapevineRates(input.ordinaryUses)
        .filter(rateIsCalculable)
        .map(rateSemanticSignature)
        .filter((sig) => !panelSignatures.has(sig)),
    ),
  ];
  if (lost.length > 0) {
    return {
      ...base,
      improves: false,
      lostRateSignatures: lost,
      check: "rate_evidence_lost",
      reason:
        "the candidate does not represent every calculable grapevine rate the " +
        "ordinary parse stated; a better-structured result with fewer rates is " +
        "not a better result",
    };
  }

  // (F) Never trade one unproven association for another.
  if (grapevineRates(input.panelUses).some((r) => r?.condition_ambiguous === true)) {
    return {
      ...base,
      improves: false,
      check: "panel_still_ambiguous",
      reason:
        "the candidate's own rate/condition associations remain unproven, so " +
        "replacing would exchange one ambiguity for another",
    };
  }

  return {
    ...base,
    improves: true,
    check: "strictly_better",
    reason:
      `the candidate preserves every calculable grapevine rate and resolves ` +
      `${panelIds.size} distinct printed directions where the ordinary parse ` +
      `bound only ${ordinaryIds.size}, with no remaining condition ambiguity`,
  };
}

/** Which reading of the authoritative document the merge should serve. */
export type DirectionSourceOutcome =
  /** No candidate re-read exists; the ordinary result stands. */
  | "no_candidate"
  /** Original D4A.3 behaviour: ordinary stated no calculable rate. */
  | "ordinary_not_calculable"
  /** Gate D4A.3.2: ordinary was calculable but had lost direction identity. */
  | "identity_repair"
  /** The ordinary result was kept. */
  | "ordinary_retained";

export interface DirectionSourceSelection {
  /** Whether the caller should serve the candidate rows. */
  replace: boolean;
  outcome: DirectionSourceOutcome;
  reason: string;
  /** Present whenever the strict comparison was actually run. */
  comparison?: DirectionIdentityComparison;
}

/**
 * THE routing rule (Gate D4A.3.2).
 *
 *   no candidate                    -> keep the ordinary result
 *   ordinary states no calculable   -> D4A.3, unchanged: use the candidate
 *     grapevine rate                   only if IT states calculable rates
 *   ordinary IS calculable          -> use the candidate ONLY when the
 *                                      ordinary result shows identity loss
 *                                      AND the candidate strictly improves it
 *   otherwise                       -> keep the ordinary result
 *
 * The second branch is preserved byte-for-byte in behaviour because it is the
 * repair VICOL 33182 depends on. The third is new, and is the narrowest
 * addition that can reach Thiovit: it can only ever fire on a result that has
 * already admitted, in its own served data, that it lost a binding.
 */
export function selectDirectionSource(input: {
  ordinaryUses: readonly Record<string, unknown>[];
  panelUses: readonly Record<string, unknown>[] | null;
  product?: RateIdentityProduct | null;
}): DirectionSourceSelection {
  const panelUses = input.panelUses ?? null;
  if (!panelUses || panelUses.length === 0) {
    return {
      replace: false,
      outcome: "no_candidate",
      reason: "no state-aware candidate re-read was prepared for this document",
    };
  }

  // Branch 2 — the original D4A.3 rule, unchanged.
  if (!statesCalculableGrapevineRate(input.ordinaryUses)) {
    if (statesCalculableGrapevineRate(panelUses)) {
      return {
        replace: true,
        outcome: "ordinary_not_calculable",
        reason:
          "the ordinary parse left grapevine rates non-calculable and the " +
          "state-aware re-read of the same authoritative document states them",
      };
    }
    return {
      replace: false,
      outcome: "ordinary_retained",
      reason:
        "neither reading states a calculable grapevine rate, so the original " +
        "evidence stands with its rates honestly unresolved",
    };
  }

  // Branch 3 — calculable, but is it correctly bound?
  const comparison = panelStrictlyImprovesDirectionIdentity({
    ordinaryUses: input.ordinaryUses,
    panelUses,
    product: input.product ?? null,
  });
  return comparison.improves
    ? {
      replace: true,
      outcome: "identity_repair",
      reason: comparison.reason,
      comparison,
    }
    : {
      replace: false,
      outcome: "ordinary_retained",
      reason: comparison.reason,
      comparison,
    };
}

/**
 * Re-read an authoritative label document with the state-aware parser when,
 * and only when, the ordinary parse left grapevine rates non-calculable.
 *
 * # The fail-soft rule (narrow by construction)
 *
 * Three independent conditions must ALL hold before anything is replaced:
 *
 *   1. the ordinary parse states no calculable grapevine rate;
 *   2. the document POSITIVELY prints a state-aware DFU table;
 *   3. the state-aware parse itself yields a calculable grapevine rate.
 *
 * Any one failing leaves `uses` untouched and the caller serves the original
 * evidence with its rates honestly unresolved. A successful ordinary parse is
 * never displaced merely because the fallback also recognises a table, and a
 * guessed parse is never preferred over an honest unresolved result.
 *
 * Pure: `items` and `regulatorUses` are read, never mutated.
 */
export function applyPanelLayoutFallback(input: {
  items: readonly PdfTextItem[] | null;
  /** Rows the ordinary eLabel path produced. */
  regulatorUses: readonly Record<string, unknown>[];
  /** The LOCKED registered product, for identity minting. */
  product?: RateIdentityProduct | null;
  withholdingPeriodDays?: number | null;
  reEntryPeriodHours?: number | null;
}): PanelFallbackResult {
  const absent: StateAwareDfuGeometry = { present: false, page: null, columns: [] };

  // (1) Never displace a working parse.
  if (statesCalculableGrapevineRate(input.regulatorUses)) {
    return {
      outcome: "not_needed",
      uses: [],
      geometry: absent,
      reason:
        "the ordinary eLabel parse already states calculable grapevine rates; " +
        "a fallback must not displace a working parse",
    };
  }

  const items = input.items ?? null;
  if (!items || items.length === 0) {
    return {
      outcome: "geometry_absent",
      uses: [],
      geometry: absent,
      reason: "no positioned text was available to re-read",
    };
  }

  // (2) The document must positively present the column this parser reads.
  const geometry = detectStateAwareDfu(items as PdfTextItem[]);
  if (!geometry.present) {
    return {
      outcome: "geometry_absent",
      uses: [],
      geometry,
      reason:
        "the document prints no state-aware Directions-for-Use table, so the " +
        "state-aware parser has no geometry to read and the original " +
        "evidence stands with its rates unresolved",
    };
  }

  const parse = extractManufacturerLabelUses(items as PdfTextItem[]);
  if (!parse.found || parse.uses.length === 0) {
    return {
      outcome: "parse_unusable",
      uses: [],
      geometry,
      reason:
        "the state-aware parser could not establish directions deterministically",
    };
  }

  // Identity is minted INSIDE the projection, while each printed direction
  // still holds its complete target set and before the one-target-per-row
  // fan-out (Gate D1.2). Never re-derived from the fanned rows.
  const rows = manufacturerUsesToRegisteredUses(parse.uses, {
    withholdingPeriodDays: input.withholdingPeriodDays ?? null,
    reEntryPeriodHours: input.reEntryPeriodHours ?? null,
    product: input.product ?? null,
  });

  // (3) The re-read must actually be better, not merely different.
  if (!statesCalculableGrapevineRate(rows)) {
    return {
      outcome: "parse_unusable",
      uses: [],
      geometry,
      reason:
        "the state-aware parse produced no calculable grapevine rate either, " +
        "so an honest unresolved result is served rather than a guess",
    };
  }

  return {
    outcome: "applied",
    uses: rows,
    geometry,
    reason:
      "the authoritative label prints a state-aware Directions-for-Use table " +
      "whose grapevine rates the single-column parser could not read; the " +
      "same authoritative document was re-read with the state-aware parser",
  };
}
