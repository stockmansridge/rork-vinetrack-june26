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
import type { RateIdentityProduct } from "../rate_identity.ts";

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
function unanimousPeriod(
  original: readonly Record<string, unknown>[],
  crop: unknown,
  field: CarriedPeriodField,
): number | null {
  const norm = (value: unknown): string => String(value ?? "").trim().toLowerCase();
  const distinct = new Set<number>();
  for (const use of original) {
    if (norm(use?.crop) !== norm(crop)) continue;
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
function rateIsCalculable(rate: unknown): boolean {
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
