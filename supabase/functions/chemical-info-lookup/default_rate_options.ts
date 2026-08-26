// Canonical OPERATIONAL DEFAULT-RATE OPTIONS, derived from authoritative
// registered uses (Gate D4A).
//
// # Why the backend produces these, and not the clients
//
// D3 established WHERE an operator's chosen default is stored and what makes
// two choices the same choice. It did not say who computes that. Left open,
// the answer would have been "everyone": the Portal would hash its own
// `default_option_v1`, iOS would write a Swift SHA-256, and the two would
// agree right up until one of them normalised a unit slightly differently.
// At that point the same operator choice would carry two identities and the
// shared column would silently hold two answers to one question.
//
// So there is exactly ONE producer, and it is this module. Clients display
// options, let the operator pick one, and persist the object they were handed.
// They never mint `option_key`, never group `rate_ids`, and never snapshot an
// amount themselves.
//
// # What an option IS
//
// An option is an operational amount the label supports — "3 L per 100 L" —
// together with every printed direction that supports it. It is derived
// purely from `registered_uses`, which is label evidence, and it adds no new
// authority: the numbers, the units and the identities all come from the
// label rows unchanged.
//
// # Why one option can cite several directions
//
// A label commonly states the same amount under several directions. VICOL
// (APVMA 33182) prints 3 L/100 L twice:
//
//     European Red Mites   NSW, Vic, SA
//     Grapevine Scale      NSW, Vic, Qld, SA, WA
//
// An operator who says "I use 3 L per 100 L of VICOL" is relying on both. Six
// pest rows would be six defaults for one decision they made once; one row
// would discard a direction they are entitled to rely on. So the printed rows
// are GROUPED by the operational amount, and the group cites every supporting
// `rate_id`.
//
// # What this module refuses to do
//
// It never converts. Not between bases — /ha and /100 L need a water volume
// that belongs to the job, not the product — and not between label units. A
// label saying "3 L/100 L" and one saying "3000 mL/100 L" are left as two
// options, because collapsing them would require this layer to invent a
// canonical-equivalence rule the structured contract has never stated.
//
// It never fabricates identity. A rate without a stable `rate_v1_` id cannot
// take part in something an operator will persist and rely on years later, so
// it produces no option and is reported instead.
//
// # Why only grapevine uses become options (Gate D4A.1)
//
// An operational default is a VINEYARD default: it is what gets pre-filled on
// a spray record for a block of vines. Most APVMA labels register a product on
// many crops, and a citrus or pome-fruit dose printed on the same label is a
// real, authoritative fact about that drum — but it is not a dose anyone may
// apply to vines. Offering it as a selectable default would put a wrong rate
// behind a plausible name, which is the one failure mode this whole area of
// the product exists to prevent.
//
// So other crops stay exactly where they are — in `registered_uses`, and in
// the `other_crop_uses` projection, with their identities intact — and simply
// never reach the grouping stage. Eligibility is decided by `isGrapevineCrop`,
// the SAME predicate `projectGrapevineUses` already uses to build
// `grapevine_uses`. There is deliberately no second reading of what "grapes"
// means: if these two ever disagreed, a rate could be a grapevine rate in one
// half of the response and not the other.

import { isGrapevineCrop } from "./grapevine_label.ts";
import {
  type DefaultRateBasis,
  DEFAULT_RATE_BASES,
  mintDefaultOptionKey,
  normaliseDefaultRateBasis,
} from "./default_rates.ts";
import {
  normaliseIdentityNumber,
  normaliseIdentityText,
  RATE_ID_VERSION,
} from "./rate_identity.ts";

// deno-lint-ignore no-explicit-any
type Jsonish = any;

// ---------------------------------------------------------------------------
// The wire shape
// ---------------------------------------------------------------------------

/**
 * One operational amount the label supports.
 *
 * The first seven fields are STRUCTURALLY IDENTICAL to a D3 persisted
 * selection minus its provenance. A client persists a choice by taking this
 * object and adding `source` and `selected_at` — nothing is recomputed,
 * because recomputing is exactly what this gate removes.
 *
 * Everything after `max_value` is DISPLAY METADATA. It exists so a screen can
 * explain why an option is on it, and it is excluded from `option_key` by
 * construction: the key is minted from the semantic fields alone. It must not
 * be written into `default_rates` unless a later gate decides so explicitly.
 */
export interface DefaultRateOption {
  option_key: string;
  /** Every supporting registered rate, de-duplicated and sorted. Never empty. */
  rate_ids: string[];
  basis: DefaultRateBasis;
  /** The LABEL's own unit. Never the product's stock or inventory unit. */
  unit: string;
  value: number | null;
  min_value: number | null;
  max_value: number | null;

  // --- display metadata: presentation only, never identity ---

  /** Printed directions supporting this amount, sorted. */
  direction_ids: string[];
  /** Pests/targets the supporting directions name, de-duplicated and sorted. */
  targets: string[];
  /**
   * The supporting directions' own condition wording — jurisdictions
   * ("NSW, Vic, SA"), spray types ("Dilute spraying") — de-duplicated and
   * sorted.
   */
  conditions: string[];
  /** Crops the supporting directions name, de-duplicated and sorted. */
  crops: string[];
  /**
   * At least one supporting rate could not be tied to its condition by the
   * deterministic grammar (`condition_ambiguous`).
   *
   * Surfaced so a client can make the operator choose deliberately rather
   * than presenting an unproven association as settled. It says nothing about
   * whether the NUMBER is right — that was read verbatim from the label.
   */
  condition_ambiguous: boolean;
}

/** Options for a product, split by basis. The two are wholly independent. */
export interface DefaultRateOptions {
  per_hectare: DefaultRateOption[];
  per_100_litres: DefaultRateOption[];
}

/**
 * A rate that should have been able to produce an option but could not.
 *
 * Reported rather than silently dropped. A calculable, unit-bearing,
 * well-formed label rate that reaches the response boundary without a stable
 * identity means an upstream invariant slipped — either the product never
 * locked, or a projection lost the id — and that is worth seeing rather than
 * quietly returning a shorter list.
 */
export interface DefaultRateOptionViolation {
  code: "rate_id_missing" | "rate_id_malformed";
  basis: DefaultRateBasis;
  /** The direction the rate was printed under, when known. */
  direction_id: string | null;
  /** Enough label wording to find the row, never enough to act on. */
  detail: string;
}

export interface DefaultRateOptionResult {
  options: DefaultRateOptions;
  violations: DefaultRateOptionViolation[];
}

export function emptyDefaultRateOptions(): DefaultRateOptions {
  return { per_hectare: [], per_100_litres: [] };
}

// ---------------------------------------------------------------------------
// Grouping
// ---------------------------------------------------------------------------

const text = (v: unknown): string => String(v ?? "").trim();

const isFiniteNumber = (v: unknown): v is number =>
  typeof v === "number" && Number.isFinite(v);

/**
 * Whether a rate id is a Gate D1 registered-rate identity.
 *
 * `direction_v1_` is deliberately refused as well as garbage: a direction is
 * not a rate, and accepting one would let a default cite something that says
 * nothing about an amount.
 */
function isStableRateId(id: string): boolean {
  return id.startsWith(`${RATE_ID_VERSION}_`) && id.length > RATE_ID_VERSION.length + 1;
}

/**
 * The amount a rate states, or `null` when it states none usable.
 *
 * A true range keeps BOTH bounds. Nothing here picks a midpoint, a minimum or
 * a maximum: the label printed a range because the range is what it meant, and
 * collapsing it would restate it as a precision it never claimed.
 */
function readAmount(
  rate: Jsonish,
): { value: number | null; min_value: number | null; max_value: number | null } | null {
  const value = rate?.value;
  const min = rate?.min_value;
  const max = rate?.max_value;

  // A range is anything that states bounds — whichever basis spelling was
  // used, since `range_per_hectare` folds onto `per_hectare` upstream.
  if (min !== null && min !== undefined || max !== null && max !== undefined) {
    if (!isFiniteNumber(min) || !isFiniteNumber(max)) return null;
    if (min > max) return null;
    return { value: null, min_value: min, max_value: max };
  }
  if (!isFiniteNumber(value)) return null;
  return { value, min_value: null, max_value: null };
}

/**
 * The key two rates must share to be the SAME operational amount.
 *
 * Deliberately built from the same canonicalisation `mintDefaultOptionKey`
 * uses — folded text for the unit, canonical decimals for the numbers — so
 * grouping and identity can never disagree. If two rates group here, they
 * provably mint one key; if they do not, they provably mint two.
 *
 * The unit is COMPARED case-insensitively but never converted: "L" and "l"
 * are one unit written two ways, while "L" and "mL" are two units and stay
 * two options.
 */
function amountGroupKey(
  basis: DefaultRateBasis,
  unit: string,
  amount: { value: number | null; min_value: number | null; max_value: number | null },
): string {
  return [
    basis,
    normaliseIdentityText(unit) || "-",
    normaliseIdentityNumber(amount.value),
    normaliseIdentityNumber(amount.min_value),
    normaliseIdentityNumber(amount.max_value),
  ].join("\u001f");
}

interface Bucket {
  basis: DefaultRateBasis;
  /** Every raw label spelling seen for this unit, so one can be chosen. */
  unitSpellings: Set<string>;
  amount: { value: number | null; min_value: number | null; max_value: number | null };
  rateIds: Set<string>;
  directionIds: Set<string>;
  targets: Set<string>;
  conditions: Set<string>;
  crops: Set<string>;
  conditionAmbiguous: boolean;
}

const sortedList = (set: Set<string>): string[] =>
  [...set].filter((v) => v.length > 0).sort();

/**
 * Deterministic order WITHIN a basis.
 *
 * Single amounts ascending first, then ranges by lower bound and then upper,
 * then `option_key` as a final tie-break. Every step is a property of the
 * data, so two isolates reading the same label produce the same list — the
 * parser's array order never leaks into what the operator sees.
 */
function compareOptions(a: DefaultRateOption, b: DefaultRateOption): number {
  const aSingle = a.value !== null;
  const bSingle = b.value !== null;
  if (aSingle !== bSingle) return aSingle ? -1 : 1;

  if (aSingle && bSingle) {
    if (a.value !== b.value) return (a.value ?? 0) - (b.value ?? 0);
  } else {
    const minDiff = (a.min_value ?? 0) - (b.min_value ?? 0);
    if (minDiff !== 0) return minDiff;
    const maxDiff = (a.max_value ?? 0) - (b.max_value ?? 0);
    if (maxDiff !== 0) return maxDiff;
  }
  // Same amount, different unit or supporting set: still deterministic.
  if (a.unit !== b.unit) return a.unit < b.unit ? -1 : 1;
  return a.option_key < b.option_key ? -1 : a.option_key > b.option_key ? 1 : 0;
}

/**
 * Build every canonical default-rate option a product's label supports.
 *
 * Pure and total: `uses` is read, never mutated, and malformed input yields
 * fewer options rather than an exception. This runs at the response boundary
 * on rows that have already been resolved, merged, enriched and identity
 * minted, so it sees exactly what the client will see.
 *
 * ONLY grapevine uses are eligible. A product registered solely on other crops
 * yields zero options, which is a legitimate product state and not a
 * degradation — the label evidence is served in full either way.
 */
export function buildDefaultRateOptions(uses: unknown): DefaultRateOptionResult {
  const options = emptyDefaultRateOptions();
  const violations: DefaultRateOptionViolation[] = [];
  if (!Array.isArray(uses)) return { options, violations };

  const buckets = new Map<string, Bucket>();

  for (const rawUse of uses) {
    if (!rawUse || typeof rawUse !== "object") continue;
    const use = rawUse as Jsonish;
    if (!Array.isArray(use.rates)) continue;

    const crop = text(use.crop);
    // Crop eligibility is decided HERE — before amount parsing, before the
    // identity check, and before grouping. Doing it first is what keeps an
    // other-crop row that happens to state the same number from joining a
    // grapevine option's `rate_ids`, and what stops a malformed id on a citrus
    // row from being reported as a vineyard default-option invariant. That row
    // was never eligible to become a vineyard default, so nothing about it is
    // a breach of this contract.
    if (!isGrapevineCrop(crop)) continue;

    const directionId = text(use.direction_id);
    // `target_raw` is the authoritative label wording; `target` is the mapped
    // VineTrack enum and only stands in when the raw wording is absent.
    const target = text(use.target_raw) || text(use.target);

    for (const rawRate of use.rates) {
      if (!rawRate || typeof rawRate !== "object") continue;
      const rate = rawRate as Jsonish;

      // Only the two operational bases. `other` carries verbatim wording and
      // no numbers, so it can never be an operational amount.
      const basis = normaliseDefaultRateBasis(rate.basis);
      if (!basis) continue;

      const unit = text(rate.unit);
      if (!unit) continue;

      const amount = readAmount(rate);
      if (!amount) continue;

      // Everything above says this IS a usable operational amount. So a
      // missing identity here is a real invariant breach, not an ordinary
      // absence — report it and emit nothing rather than inventing an id or
      // falling back to a target/index handle that would not survive a
      // re-extraction.
      const rateId = text(rate.rate_id);
      if (!rateId) {
        violations.push({
          code: "rate_id_missing",
          basis,
          direction_id: directionId || null,
          detail: `${crop || "?"} — ${target || "?"} (${unit})`,
        });
        continue;
      }
      if (!isStableRateId(rateId)) {
        violations.push({
          code: "rate_id_malformed",
          basis,
          direction_id: directionId || null,
          detail: `${crop || "?"} — ${target || "?"} (${rateId})`,
        });
        continue;
      }

      const key = amountGroupKey(basis, unit, amount);
      let bucket = buckets.get(key);
      if (!bucket) {
        bucket = {
          basis,
          unitSpellings: new Set<string>(),
          amount,
          rateIds: new Set<string>(),
          directionIds: new Set<string>(),
          targets: new Set<string>(),
          conditions: new Set<string>(),
          crops: new Set<string>(),
          conditionAmbiguous: false,
        };
        buckets.set(key, bucket);
      }

      bucket.unitSpellings.add(unit);
      bucket.rateIds.add(rateId);
      if (directionId) bucket.directionIds.add(directionId);
      if (target) bucket.targets.add(target);
      if (crop) bucket.crops.add(crop);
      // `label` is what the label calls the rate, which the D1 contract
      // documents as carrying the jurisdiction/condition wording.
      const condition = text(rate.label);
      if (condition) bucket.conditions.add(condition);
      if (rate.condition_ambiguous === true) bucket.conditionAmbiguous = true;
    }
  }

  for (const bucket of buckets.values()) {
    const rateIds = [...bucket.rateIds].sort();
    if (rateIds.length === 0) continue;

    // Spellings in one bucket differ only by case, so any is faithful to the
    // label; the first sorted one is chosen purely so the answer is stable.
    const unit = [...bucket.unitSpellings].sort()[0];

    const option: DefaultRateOption = {
      // The D3 minter, called — never reimplemented. Canonical input is
      // basis + label unit + amount + sorted unique rate_ids, so this key is
      // already the one `validateDefaultRates` will re-derive when the
      // client persists the choice.
      option_key: mintDefaultOptionKey(bucket.basis, { unit, ...bucket.amount }, rateIds),
      rate_ids: rateIds,
      basis: bucket.basis,
      unit,
      value: bucket.amount.value,
      min_value: bucket.amount.min_value,
      max_value: bucket.amount.max_value,
      direction_ids: sortedList(bucket.directionIds),
      targets: sortedList(bucket.targets),
      conditions: sortedList(bucket.conditions),
      crops: sortedList(bucket.crops),
      condition_ambiguous: bucket.conditionAmbiguous,
    };
    options[bucket.basis].push(option);
  }

  for (const basis of DEFAULT_RATE_BASES) options[basis].sort(compareOptions);

  violations.sort((a, b) =>
    `${a.code}${a.basis}${a.detail}` < `${b.code}${b.basis}${b.detail}` ? -1 : 1
  );
  return { options, violations };
}

/**
 * Attach `default_rate_options` to a structured lookup response, in place.
 *
 * Derived at the RESPONSE BOUNDARY, from the final `registered_uses` — after
 * register resolution, manufacturer enrichment and D1 identity minting have
 * all had their say, and after any cache has been read. That ordering is
 * deliberate: options are a pure function of the label rows, so deriving them
 * here means a cached row written before this gate existed still produces
 * current options, and the cache never becomes a second contract that could
 * go stale in its own right.
 *
 * `grapevine_uses` and `other_crop_uses` are projections of `registered_uses`
 * and are NOT read — a projection cannot add an amount the authoritative
 * array does not already state, and reading both would only risk counting one
 * direction twice. The grapevine filter is applied to the authoritative array
 * using the projection's own predicate, so the two agree by construction
 * rather than by coincidence.
 *
 * Additive and idempotent. Nothing about `registered_uses` is read
 * destructively, reordered or removed.
 */
export function applyDefaultRateOptions(structured: unknown): DefaultRateOptionViolation[] {
  const s = structured as Record<string, unknown> | null;
  if (!s || typeof s !== "object") return [];

  const { options, violations } = buildDefaultRateOptions(s.registered_uses);
  s.default_rate_options = options;
  return violations;
}

// ---------------------------------------------------------------------------
// Identity readiness (Gate D4A.2)
// ---------------------------------------------------------------------------

/**
 * Whether a set of registered uses could produce persistable defaults TODAY.
 *
 * # Why this lives here and not in the caller
 *
 * The Master Chemical Catalogue fast path serves a stored row verbatim, so it
 * has to decide in advance whether that row's rates can survive being turned
 * into something an operator persists. Answering that question requires
 * knowing what an "eligible operational rate" is — grapevine crop, an
 * operational basis, a usable label unit, a usable amount — which is exactly
 * what {@link buildDefaultRateOptions} already decides.
 *
 * Writing that test a second time inside `master_lookup.ts` would create a
 * THIRD interpretation of a persistable default rate (after the producer and
 * D3's validator), and the three would drift the moment any one of them
 * learned about a new basis or unit. So this helper does not re-implement the
 * rule: it RUNS the producer and reads its verdict. A violation is by
 * definition a rate that was eligible in every respect except identity, which
 * is precisely the readiness question and nothing more.
 *
 * That reuse is what makes the surrounding gates hold without restating them:
 * a citrus rate, a verbatim `other` rate and an amount-less row are all
 * ineligible upstream, so none of them can ever make a row "not ready".
 *
 * Pure: `uses` is read and never mutated — notably, no identity is minted for
 * a row found wanting. A row that cannot answer is sent to be reconstructed
 * from its authoritative source, not repaired from its own projection.
 */
export interface DefaultRateOptionIdentityReadiness {
  /** No eligible grapevine rate is missing a valid `rate_v1_` identity. */
  ready: boolean;
  /** Eligible grapevine rates that DO carry a usable identity. */
  identified_rate_count: number;
  /** Why it is not ready — empty exactly when `ready` is true. */
  violations: DefaultRateOptionViolation[];
}

export function inspectDefaultRateOptionIdentityReadiness(
  uses: unknown,
): DefaultRateOptionIdentityReadiness {
  const { options, violations } = buildDefaultRateOptions(uses);
  const identified = new Set<string>();
  for (const basis of DEFAULT_RATE_BASES) {
    for (const option of options[basis]) {
      for (const id of option.rate_ids) identified.add(id);
    }
  }
  return {
    ready: violations.length === 0,
    identified_rate_count: identified.size,
    violations,
  };
}
