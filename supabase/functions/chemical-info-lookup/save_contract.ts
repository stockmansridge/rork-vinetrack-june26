// The shared mandatory-save contract for a vineyard chemical (task §11).
//
// # Why this lives on the server
//
// "Save is disabled" was previously an iOS button rule. The Portal had its own
// idea, Android had a third, and a record refused by one client could be
// written by another — so the Chemical Store could contain products that no
// spray calculation, compliance check or resistance warning could actually
// use. A validation rule that only one client enforces is not a contract.
//
// This module is the single definition. iOS mirrors it for immediate form
// feedback (`ChemicalSaveContract.swift`, kept decision-for-decision
// identical), and the Portal consumes it through the documented handoff.
//
// # What it protects, and what it refuses to protect
//
// The contract exists to stop VineTrack storing a chemical it cannot USE. It
// does NOT exist to make the record look complete:
//
//   * WHP and REI stay null when the label does not state them. Forcing an
//     operator to type a number the label never printed would manufacture
//     regulatory information — the opposite of the job.
//   * A manufacturer URL is supplementary and always optional.
//   * A resistance group may legitimately be `not_applicable`, and may
//     honestly be `unresolved`. What is NOT allowed is silence: the state
//     must be stated, because the Resistance Planner reads it.
//
// # The rate rule
//
// A rate does not count merely because `raw_text` is non-empty. Verbatim
// wording ("Apply as directed by an agronomist") is evidence, not a rate: no
// calculation can run on it. A usable rate needs a numeric value or a valid
// range, a unit, and a recognised basis.

// deno-lint-ignore-file no-explicit-any

/** Every way a chemical can fail the save contract. */
export type SaveViolationCode =
  | "product_name_missing"
  | "product_category_missing"
  | "active_ingredient_name_missing"
  | "grapevine_use_missing"
  | "usable_rate_missing"
  | "rate_unit_missing"
  | "rate_basis_unrecognised"
  | "rate_value_invalid"
  | "rate_range_inverted"
  | "resistance_state_missing"
  | "registration_identity_missing"
  | "official_label_missing";

export interface SaveViolation {
  code: SaveViolationCode;
  /** Operator-facing sentence. Says what to do, not what is wrong. */
  message: string;
  /** Which section of the form the operator must go to. */
  field: string;
}

/** How complete a record has to be. */
export type SaveIntent =
  /** Going into the Chemical Store for use in spray work. */
  | "spray_ready"
  /** Additionally claiming registered identity. */
  | "verified";

export interface RateInput {
  basis?: string | null;
  value?: number | null;
  min_value?: number | null;
  max_value?: number | null;
  unit?: string | null;
  raw_text?: string | null;
  condition_ambiguous?: boolean | null;
}

export interface RegisteredUseInput {
  crop?: string | null;
  target_raw?: string | null;
  rates?: RateInput[] | null;
  /** Deliberately unread by this contract — see the WHP/REI note above. */
  withholding_period_days?: number | null;
  re_entry_period_hours?: number | null;
}

export interface ActiveIngredientInput {
  name?: string | null;
  activity_group?: { scheme?: string | null; code?: string | null } | null;
  classification_state?: string | null;
}

export interface ChemicalSaveInput {
  product_name?: string | null;
  product_category?: string | null;
  active_ingredients?: ActiveIngredientInput[] | null;
  registered_uses?: RegisteredUseInput[] | null;
  registration?: {
    registration_number?: string | null;
    country_code?: string | null;
    label_reference?: string | null;
  } | null;
  /** "classified" | "not_applicable" | "unresolved" (sql/210). */
  resistance_classification_state?: string | null;
}

/** The rate bases a calculation can actually run on. */
const CALCULABLE_BASES = new Set([
  "per_100_litres",
  "per_hectare",
  "range_per_100_litres",
  "range_per_hectare",
]);

const RANGE_BASES = new Set(["range_per_100_litres", "range_per_hectare"]);

export const RESISTANCE_STATES = new Set([
  "classified",
  "not_applicable",
  "unresolved",
]);

const text = (v: unknown): string => String(v ?? "").trim();

/** Whether a use concerns grapevines. */
export function isViticultural(use: RegisteredUseInput): boolean {
  const crop = text(use.crop).toLowerCase();
  return crop.includes("grape") || crop.includes("vine");
}

/**
 * Whether a rate can drive a calculation.
 *
 * Verbatim wording is deliberately excluded. `basis: "other"` with a
 * `raw_text` is a faithful record of what the label says and is worth
 * keeping — but "Apply as directed by an agronomist" cannot produce a dose,
 * and treating it as a rate is what let unusable chemicals reach the store.
 */
export function isUsableRate(rate: RateInput): boolean {
  const basis = text(rate.basis);
  if (!CALCULABLE_BASES.has(basis)) return false;
  if (!text(rate.unit)) return false;

  if (RANGE_BASES.has(basis)) {
    const lo = rate.min_value;
    const hi = rate.max_value;
    return typeof lo === "number" && Number.isFinite(lo) && lo > 0 &&
      typeof hi === "number" && Number.isFinite(hi) && hi > 0 && hi >= lo;
  }
  const value = rate.value;
  return typeof value === "number" && Number.isFinite(value) && value > 0;
}

/**
 * A rate that a calculation may use WITHOUT asking the operator first.
 *
 * An ambiguous rate is usable but not automatic: the label states several
 * rates on one basis and nothing proved which condition governs which number
 * (task §5). Preserving them is right; silently applying the first one is
 * not.
 */
export function isAutoApplicableRate(rate: RateInput): boolean {
  return isUsableRate(rate) && rate.condition_ambiguous !== true;
}

/** Per-rate structural faults, reported so the operator can fix the value. */
function rateViolations(rates: RateInput[]): SaveViolation[] {
  const out: SaveViolation[] = [];
  for (const rate of rates) {
    const basis = text(rate.basis);
    // A verbatim entry is a legitimate record, not a malformed rate.
    if (basis === "other") continue;
    if (!basis || !CALCULABLE_BASES.has(basis)) {
      out.push({
        code: "rate_basis_unrecognised",
        field: "rates",
        message: "Choose whether this rate is per 100 L or per hectare.",
      });
      continue;
    }
    if (!text(rate.unit)) {
      out.push({
        code: "rate_unit_missing",
        field: "rates",
        message: "Enter the unit for this rate (L, mL, kg or g).",
      });
    }
    if (RANGE_BASES.has(basis)) {
      const lo = rate.min_value;
      const hi = rate.max_value;
      if (typeof lo !== "number" || typeof hi !== "number" ||
        !Number.isFinite(lo) || !Number.isFinite(hi) || lo <= 0 || hi <= 0) {
        out.push({
          code: "rate_value_invalid",
          field: "rates",
          message: "Enter both ends of this rate range from the label.",
        });
      } else if (hi < lo) {
        out.push({
          code: "rate_range_inverted",
          field: "rates",
          message: "This rate range is back to front — the low value must come first.",
        });
      }
    } else if (
      typeof rate.value !== "number" || !Number.isFinite(rate.value) ||
      rate.value <= 0
    ) {
      out.push({
        code: "rate_value_invalid",
        field: "rates",
        message: "Enter the rate from the label.",
      });
    }
  }
  return out;
}

export interface SaveEvaluation {
  ok: boolean;
  violations: SaveViolation[];
  /** True when at least one grapevine use carries a calculable rate. */
  hasUsableViticulturalRate: boolean;
  /** True when a grapevine rate exists but its condition is unproven. */
  requiresRateConditionChoice: boolean;
}

/**
 * Evaluate a chemical against the mandatory contract.
 *
 * Returns EVERY violation rather than the first, so the form can show the
 * whole remaining task instead of revealing it one field at a time.
 */
export function evaluateChemicalSave(
  input: ChemicalSaveInput,
  intent: SaveIntent = "spray_ready",
): SaveEvaluation {
  const violations: SaveViolation[] = [];

  if (!text(input.product_name)) {
    violations.push({
      code: "product_name_missing",
      field: "product_name",
      message: "Enter the product name.",
    });
  }

  // The calculation model picks litres vs kilograms from the category/form,
  // so a product without one cannot be dosed.
  if (!text(input.product_category)) {
    violations.push({
      code: "product_category_missing",
      field: "product_category",
      message: "Choose the product category so VineTrack knows how to measure it.",
    });
  }

  // "At least one active ingredient WHERE the product has one." A record with
  // no actives at all is a legitimate adjuvant/wetter, so absence is not a
  // fault — but a half-typed active row with no name is.
  const actives = input.active_ingredients ?? [];
  if (actives.length > 0 && actives.every((a) => !text(a.name))) {
    violations.push({
      code: "active_ingredient_name_missing",
      field: "active_ingredients",
      message: "Enter the active ingredient name, or remove the empty row.",
    });
  }

  const uses = input.registered_uses ?? [];
  const viticultural = uses.filter(isViticultural);
  if (viticultural.length === 0) {
    violations.push({
      code: "grapevine_use_missing",
      field: "registered_uses",
      message: "Add the grapevine use this product is registered for.",
    });
  }

  const viticulturalRates = viticultural.flatMap((u) => u.rates ?? []);
  const usable = viticulturalRates.filter(isUsableRate);
  const hasUsableViticulturalRate = usable.length > 0;

  if (viticultural.length > 0 && !hasUsableViticulturalRate) {
    // The §11 case named in the task: research identified the product and the
    // grapevine use but produced no rate. The record must not save as though
    // it is ready.
    violations.push({
      code: "usable_rate_missing",
      field: "rates",
      message: "Rate not found — enter the rate from the label before saving.",
    });
  }

  violations.push(...rateViolations(viticulturalRates));

  // Resistance state must be STATED. `unresolved` and `not_applicable` are
  // both acceptable answers; a blank is not, because the Planner cannot tell
  // a blank from "no concern".
  const state = text(input.resistance_classification_state);
  if (!RESISTANCE_STATES.has(state)) {
    violations.push({
      code: "resistance_state_missing",
      field: "resistance",
      message: "Set the resistance group, or mark it as not applicable.",
    });
  }

  if (intent === "verified") {
    const registration = input.registration ?? {};
    if (!text(registration.registration_number) || !text(registration.country_code)) {
      violations.push({
        code: "registration_identity_missing",
        field: "registration",
        message: "A verified product needs its registration number and country.",
      });
    }
    if (!text(registration.label_reference)) {
      violations.push({
        code: "official_label_missing",
        field: "label_reference",
        message: "A verified product needs a link to the official regulator label.",
      });
    }
  }

  // Deduplicate: several malformed rates produce one actionable message.
  const seen = new Set<string>();
  const deduped = violations.filter((v) => {
    const key = `${v.code}|${v.field}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });

  return {
    ok: deduped.length === 0,
    violations: deduped,
    hasUsableViticulturalRate,
    requiresRateConditionChoice: usable.length > 0 &&
      usable.every((r) => r.condition_ambiguous === true),
  };
}
