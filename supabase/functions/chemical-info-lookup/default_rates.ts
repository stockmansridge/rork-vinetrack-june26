// The shared persistence contract for OPERATIONAL DEFAULT RATES (Gate D3).
//
// # What this stores, and what it deliberately does not
//
// `registered_uses` is label evidence: every rate the regulator approved,
// immutable, and never a statement about what this vineyard actually does.
// An operator working through a spray program does not re-read the whole
// Directions for Use table each time — they have ONE amount they normally use
// for a product. That choice has never been persisted anywhere, so every
// client re-guessed it, and the guesses disagreed.
//
// `saved_chemicals.default_rates` is where that choice lives. It records WHICH
// authoritative rate was chosen, never a new rate. It confers no authority: if
// it is absent, wrong or unreadable, the label evidence is untouched and every
// calculation still has everything it needs.
//
// # Null means "not recorded", never "no rates exist"
//
// A NULL column means no shared default has been recorded for this product.
// A null basis slot means no default is recorded FOR THAT BASIS. Neither says
// anything about what the label offers — that question is answered by
// `registered_uses` and only by `registered_uses`.
//
// This distinction is the whole reason nothing is backfilled. `rate_per_ha`
// and `rates[]` are legacy operator fields with no link back to a registered
// direction, so deriving a default from them would invent a provenance the
// data cannot support: a number that looks chosen, attributed to a label
// direction nobody ever picked. An honest empty is worth more than a
// manufactured history, so this module contains NO path from a legacy value to
// a default. There is nothing to disable and nothing to opt out of.
//
// # Why one default may cite several rate ids
//
// A printed label can support one operational amount from several distinct
// directions. VICOL (APVMA 33182) states 3 L/100 L twice:
//
//     European Red Mites   NSW, Vic, SA
//     Grapevine Scale      NSW, Vic, Qld, SA, WA
//
// Those are two registered directions, each with its own `rate_id` under the
// Gate D1 contract, and both genuinely support the operator's "3 L/100 L".
// Collapsing them to one id would discard a direction the operator is entitled
// to rely on; forcing two separate defaults would invent a choice they never
// made. So `rate_ids` is an ARRAY, always — never a singular `rate_id`.

import {
  normaliseIdentityNumber,
  normaliseIdentityText,
  RATE_ID_VERSION,
  sha256Hex,
} from "./rate_identity.ts";

// ---------------------------------------------------------------------------
// Vocabulary
// ---------------------------------------------------------------------------

/** Contract version. Bump only when the stored shape changes. */
export const DEFAULT_RATES_VERSION = 1 as const;

/** Prefix for a grouped operational option identity. Never a UUID. */
export const DEFAULT_OPTION_ID_VERSION = "default_option_v1";

/**
 * The two bases a default can be recorded against.
 *
 * These are the EXISTING canonical spellings from the structured chemical
 * contract (`save_contract.ts` `CALCULABLE_BASES`). No second vocabulary is
 * introduced here.
 */
export type DefaultRateBasis = "per_hectare" | "per_100_litres";

export const DEFAULT_RATE_BASES: readonly DefaultRateBasis[] = [
  "per_hectare",
  "per_100_litres",
];

/**
 * Where the recorded choice came from. Provenance only.
 *
 * There is deliberately no `inferred`: nothing in this system reconstructs a
 * historical choice, so no value may imply that it did.
 */
export type DefaultRateSource = "operator" | "recommended";

const DEFAULT_RATE_SOURCES = new Set<string>(["operator", "recommended"]);

/**
 * Fold a rate's stated basis onto the slot it belongs in.
 *
 * The structured contract spells a range as `range_per_hectare` /
 * `range_per_100_litres`. That prefix describes the AMOUNT SHAPE, not a third
 * or fourth basis — a range per hectare is still per hectare. Here the shape
 * is carried by `min_value`/`max_value`, so the range spellings fold onto
 * their own basis rather than becoming new slot names.
 *
 * Returns `null` for anything else, including `other`: a verbatim direction
 * with no numbers cannot be an operational default.
 */
export function normaliseDefaultRateBasis(
  raw: string | null | undefined,
): DefaultRateBasis | null {
  switch (String(raw ?? "").trim()) {
    case "per_hectare":
    case "range_per_hectare":
      return "per_hectare";
    case "per_100_litres":
    case "range_per_100_litres":
      return "per_100_litres";
    default:
      return null;
  }
}

// ---------------------------------------------------------------------------
// The stored shape
// ---------------------------------------------------------------------------

/**
 * One recorded operational default.
 *
 * The amount is a SNAPSHOT of the authoritative label amount, in the LABEL's
 * own unit — not the product's stock/pack unit, not the inventory unit, and
 * never a converted convenience figure. A label reading "3 L / 100 L" is
 * persisted as `value: 3, unit: "L"` even for a product the vineyard buys in
 * millilitres, because the snapshot's job is to say what the label said.
 */
export interface SavedChemicalDefaultRateSelection {
  /** Deterministic identity of the grouped choice. See `mintDefaultOptionKey`. */
  option_key: string;
  /**
   * Every authoritative registered rate supporting this amount, de-duplicated
   * and sorted. At least one. These are Gate D1 `rate_v1_` identities of
   * printed DIRECTIONS — never projected target-row identities, never UUIDs.
   */
  rate_ids: string[];
  /** Must equal the slot this selection is stored under. */
  basis: DefaultRateBasis;
  /** The label rate's own unit ("L", "mL", "kg", "g"). */
  unit: string;
  /** Single-value amount, or `null` when the label states a range. */
  value: number | null;
  /** Lower bound of a true range, else `null`. */
  min_value: number | null;
  /** Upper bound of a true range, else `null`. */
  max_value: number | null;
  /** Provenance. Never part of identity. */
  source: DefaultRateSource;
  /** Provenance. Optional; never part of identity. */
  selected_at: string | null;
  /**
   * The label revision the amount was read from, when the structured contract
   * knows it. Provenance for "the label has moved on" detection — it must not
   * influence `rate_id` or `option_key`, or a reissued label restating the
   * same direction would silently orphan the operator's default.
   */
  label_version: string | null;
}

/**
 * The whole column value.
 *
 * The two bases are INDEPENDENT. A product may legitimately have a per-100 L
 * default and no per-hectare one, or both, or neither. One is never
 * manufactured from the other: converting between them needs a water volume
 * that belongs to the job, not to the product.
 */
export interface SavedChemicalDefaultRates {
  version: typeof DEFAULT_RATES_VERSION;
  per_hectare: SavedChemicalDefaultRateSelection | null;
  per_100_litres: SavedChemicalDefaultRateSelection | null;
}

/** A recorded contract with nothing selected on either basis. */
export function emptyDefaultRates(): SavedChemicalDefaultRates {
  return { version: DEFAULT_RATES_VERSION, per_hectare: null, per_100_litres: null };
}

// ---------------------------------------------------------------------------
// Option identity
// ---------------------------------------------------------------------------

/**
 * Canonical rate-id list: trimmed, de-duplicated, sorted.
 *
 * Sorting is what makes the identity order-independent — a client that lists
 * the Grapevine Scale direction first must reach the same option as one that
 * lists European Red Mites first, because they made the same choice.
 */
export function canonicalRateIds(
  ids: readonly (string | null | undefined)[] | null | undefined,
): string[] {
  const trimmed = (ids ?? [])
    .map((id) => String(id ?? "").trim())
    .filter((id) => id.length > 0);
  return [...new Set(trimmed)].sort();
}

/** The amount half of an option's identity. */
export interface DefaultRateAmount {
  unit?: string | null;
  value?: number | null;
  min_value?: number | null;
  max_value?: number | null;
}

/**
 * The exact bytes hashed for an option identity.
 *
 * Name-tagged and unit-separated (U+001F) for the same reason as the rate
 * identity: without both, two different field splits could hash alike.
 *
 * Contains ONLY what makes the choice the choice — basis, label unit, amount,
 * and the supporting direction set. Deliberately absent: `source`,
 * `selected_at`, `label_version`, UI ordering, recommendation state, the
 * product's stock unit, label URL, `fetched_at` and any cache key. Every one
 * of those can differ between two clients that made the identical choice, and
 * an identity that moved with them would make the same default look like two.
 *
 * No separate product identity layer is added: `rate_ids` are already
 * product-bound — country, scheme and registration number are inside every
 * `rate_v1_` — so two products can never share a supporting direction set.
 */
export function canonicalDefaultOptionInput(
  basis: DefaultRateBasis,
  amount: DefaultRateAmount,
  rateIds: readonly (string | null | undefined)[] | null | undefined,
): string {
  const ids = canonicalRateIds(rateIds)
    .map((id) => normaliseIdentityText(id))
    .sort();
  return [
    `v=${DEFAULT_OPTION_ID_VERSION}`,
    `basis=${normaliseIdentityText(basis) || "-"}`,
    `unit=${normaliseIdentityText(amount.unit) || "-"}`,
    `value=${normaliseIdentityNumber(amount.value)}`,
    `min=${normaliseIdentityNumber(amount.min_value)}`,
    `max=${normaliseIdentityNumber(amount.max_value)}`,
    `rates=${ids.join("\u001e") || "-"}`,
  ].join("\u001f");
}

/**
 * Mint the deterministic identity of a grouped operational choice.
 *
 * Pure: the same choice yields the same key on any machine, in any order, at
 * any time. A UUID would change on every write, which would make the key
 * useless for recognising that two clients chose the same thing.
 */
export function mintDefaultOptionKey(
  basis: DefaultRateBasis,
  amount: DefaultRateAmount,
  rateIds: readonly (string | null | undefined)[] | null | undefined,
): string {
  const digest = sha256Hex(canonicalDefaultOptionInput(basis, amount, rateIds));
  return `${DEFAULT_OPTION_ID_VERSION}_${digest.slice(0, 32)}`;
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/** Every way a stored default can fail to be readable. */
export type DefaultRatesViolationCode =
  | "not_an_object"
  | "version_unsupported"
  | "selection_not_an_object"
  | "basis_unrecognised"
  | "basis_slot_mismatch"
  | "rate_ids_missing"
  | "rate_id_malformed"
  | "unit_missing"
  | "amount_shape_invalid"
  | "amount_not_finite"
  | "amount_range_inverted"
  | "source_unrecognised"
  | "option_key_mismatch"
  | "provenance_malformed";

export interface DefaultRatesViolation {
  code: DefaultRatesViolationCode;
  /** `"default_rates"`, or `"default_rates.per_hectare"` for a slot fault. */
  field: string;
  message: string;
}

export interface DefaultRatesValidation {
  /**
   * The readable contract, or `null` when nothing usable was recorded.
   *
   * A rejected SLOT is null while the other slot survives — one unreadable
   * choice is not a reason to discard a good one.
   */
  value: SavedChemicalDefaultRates | null;
  violations: DefaultRatesViolation[];
}

const isFiniteNumber = (v: unknown): v is number =>
  typeof v === "number" && Number.isFinite(v);

function optionalText(value: unknown): { text: string | null; malformed: boolean } {
  if (value === null || value === undefined) return { text: null, malformed: false };
  if (typeof value !== "string") return { text: null, malformed: true };
  const trimmed = value.trim();
  return { text: trimmed.length > 0 ? trimmed : null, malformed: false };
}

/**
 * Validate ONE slot's selection.
 *
 * Returns `null` for anything it cannot vouch for. Nothing is repaired,
 * defaulted or guessed: a selection that fails any structural rule is a
 * selection whose meaning is unknown, and honouring an unknown meaning in a
 * dosing record is worse than having no default at all.
 *
 * Provenance is the one exception. `selected_at` and `label_version` describe
 * the circumstances of the choice rather than the choice itself, so a
 * malformed one is dropped to null and reported — it cannot make an otherwise
 * sound default unusable.
 */
function validateSelection(
  raw: unknown,
  slot: DefaultRateBasis,
  violations: DefaultRatesViolation[],
): SavedChemicalDefaultRateSelection | null {
  const field = `default_rates.${slot}`;
  const add = (code: DefaultRatesViolationCode, message: string): null => {
    violations.push({ code, field, message });
    return null;
  };

  if (raw === null || raw === undefined) return null;
  if (typeof raw !== "object" || Array.isArray(raw)) {
    return add("selection_not_an_object", "Default rate selection must be an object.");
  }
  const s = raw as Record<string, unknown>;

  // Basis, and its agreement with the slot it was found in. A selection filed
  // under per_hectare that calls itself per_100_litres is not a conversion
  // problem to fix — it is a record whose own two statements disagree.
  const basis = normaliseDefaultRateBasis(s.basis as string | null | undefined);
  if (!basis) {
    return add("basis_unrecognised", "Default rate basis is not a recognised basis.");
  }
  if (basis !== slot) {
    return add(
      "basis_slot_mismatch",
      `Default rate stored under ${slot} declares basis ${basis}.`,
    );
  }

  // Supporting directions.
  const rawIds = Array.isArray(s.rate_ids) ? (s.rate_ids as unknown[]) : null;
  if (!rawIds) {
    return add("rate_ids_missing", "Default rate must cite at least one registered rate.");
  }
  const ids = canonicalRateIds(rawIds.map((v) => (typeof v === "string" ? v : "")));
  if (ids.length === 0) {
    return add("rate_ids_missing", "Default rate must cite at least one registered rate.");
  }
  if (!ids.every((id) => id.startsWith(`${RATE_ID_VERSION}_`))) {
    return add(
      "rate_id_malformed",
      `Default rate must cite ${RATE_ID_VERSION}_ registered rate identities.`,
    );
  }

  // The label's unit. Never inferred from the product's stock unit.
  const unit = typeof s.unit === "string" ? s.unit.trim() : "";
  if (!unit) return add("unit_missing", "Default rate must record the label rate unit.");

  // Amount shape: exactly one of single value / true range.
  const value = s.value === null || s.value === undefined ? null : s.value;
  const minValue = s.min_value === null || s.min_value === undefined ? null : s.min_value;
  const maxValue = s.max_value === null || s.max_value === undefined ? null : s.max_value;
  const hasSingle = value !== null;
  const hasAnyBound = minValue !== null || maxValue !== null;

  if (hasSingle && hasAnyBound) {
    return add(
      "amount_shape_invalid",
      "Default rate is either a single amount or a range, never both.",
    );
  }
  if (!hasSingle && !hasAnyBound) {
    return add("amount_shape_invalid", "Default rate must record an amount.");
  }

  if (hasSingle) {
    if (!isFiniteNumber(value)) {
      return add("amount_not_finite", "Default rate amount must be a finite number.");
    }
  } else {
    // A true range keeps BOTH bounds. Collapsing one to a midpoint, minimum or
    // maximum would restate the label as a precision it never printed.
    if (!isFiniteNumber(minValue) || !isFiniteNumber(maxValue)) {
      return add("amount_shape_invalid", "A default rate range must record both bounds.");
    }
    if (minValue > maxValue) {
      return add("amount_range_inverted", "Default rate range is inverted.");
    }
  }

  // Provenance vocabulary is closed in v1.
  const source = typeof s.source === "string" ? s.source.trim() : "";
  if (!DEFAULT_RATE_SOURCES.has(source)) {
    return add("source_unrecognised", "Default rate source is not a recognised source.");
  }

  const selectedAt = optionalText(s.selected_at);
  const labelVersion = optionalText(s.label_version);
  if (selectedAt.malformed || labelVersion.malformed) {
    violations.push({
      code: "provenance_malformed",
      field,
      message: "Default rate provenance was unreadable and has been dropped.",
    });
  }

  const amount: DefaultRateAmount = {
    unit,
    value: hasSingle ? (value as number) : null,
    min_value: hasSingle ? null : (minValue as number),
    max_value: hasSingle ? null : (maxValue as number),
  };
  const expectedKey = mintDefaultOptionKey(basis, amount, ids);
  const storedKey = typeof s.option_key === "string" ? s.option_key.trim() : "";
  if (storedKey !== expectedKey) {
    // The key is derived from the very content beside it, so a mismatch means
    // one of the two was edited without the other. Which one is right is
    // unknowable from here, so neither is trusted.
    return add(
      "option_key_mismatch",
      "Default rate option key does not match its own content.",
    );
  }

  return {
    option_key: expectedKey,
    rate_ids: ids,
    basis,
    unit,
    value: amount.value ?? null,
    min_value: amount.min_value ?? null,
    max_value: amount.max_value ?? null,
    source: source as DefaultRateSource,
    selected_at: selectedAt.text,
    label_version: labelVersion.text,
  };
}

/**
 * Read a stored `default_rates` value.
 *
 * Total: never throws, whatever is in the column. That is the point. This
 * value is optional convenience riding alongside authoritative chemistry, so
 * the failure mode must be "no default recorded", never "this chemical cannot
 * be read". A crash here would take a product out of the operator's Chemical
 * Store over a preference.
 *
 * `null`/absent is NOT a fault and produces no violation: the overwhelming
 * majority of rows have never recorded a default and are perfectly valid.
 */
export function validateDefaultRates(raw: unknown): DefaultRatesValidation {
  const violations: DefaultRatesViolation[] = [];
  if (raw === null || raw === undefined) return { value: null, violations };

  if (typeof raw !== "object" || Array.isArray(raw)) {
    violations.push({
      code: "not_an_object",
      field: "default_rates",
      message: "Default rates must be an object.",
    });
    return { value: null, violations };
  }

  const root = raw as Record<string, unknown>;
  if (root.version !== DEFAULT_RATES_VERSION) {
    // A future version is not corrupt — it is simply not ours to interpret.
    // Reading it with v1 rules would be a guess about someone else's contract.
    violations.push({
      code: "version_unsupported",
      field: "default_rates",
      message: `Default rates version ${String(root.version)} is not supported.`,
    });
    return { value: null, violations };
  }

  return {
    value: {
      version: DEFAULT_RATES_VERSION,
      per_hectare: validateSelection(root.per_hectare, "per_hectare", violations),
      per_100_litres: validateSelection(root.per_100_litres, "per_100_litres", violations),
    },
    violations,
  };
}

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

/** What a client supplies when recording a choice. */
export interface DefaultRateSelectionInput {
  /** The rate's own basis, in structured-contract spelling. */
  basis: string;
  unit: string;
  value?: number | null;
  min_value?: number | null;
  max_value?: number | null;
  rate_ids: readonly (string | null | undefined)[];
  source: DefaultRateSource;
  selected_at?: string | null;
  label_version?: string | null;
}

/**
 * Build a canonical selection, minting its option key.
 *
 * Runs the result back through the reader, so a selection can only be produced
 * if it would also survive being read. One rule set, one place — a client
 * cannot construct something the validator would later reject.
 */
export function buildDefaultRateSelection(
  input: DefaultRateSelectionInput,
): { selection: SavedChemicalDefaultRateSelection | null; violations: DefaultRatesViolation[] } {
  const basis = normaliseDefaultRateBasis(input.basis);
  if (!basis) {
    return {
      selection: null,
      violations: [{
        code: "basis_unrecognised",
        field: "default_rates",
        message: "Default rate basis is not a recognised basis.",
      }],
    };
  }

  const ids = canonicalRateIds(input.rate_ids);
  const hasSingle = input.value !== null && input.value !== undefined;
  const amount: DefaultRateAmount = {
    unit: input.unit,
    value: hasSingle ? input.value ?? null : null,
    min_value: hasSingle ? null : input.min_value ?? null,
    max_value: hasSingle ? null : input.max_value ?? null,
  };

  const draft = {
    option_key: mintDefaultOptionKey(basis, amount, ids),
    rate_ids: ids,
    basis,
    unit: String(input.unit ?? "").trim(),
    value: amount.value ?? null,
    min_value: amount.min_value ?? null,
    max_value: amount.max_value ?? null,
    source: input.source,
    selected_at: input.selected_at ?? null,
    label_version: input.label_version ?? null,
  };

  const violations: DefaultRatesViolation[] = [];
  const selection = validateSelection(draft, basis, violations);
  return { selection, violations };
}

/**
 * Record a selection on its own basis, leaving the other basis alone.
 *
 * Pure — the input contract is not mutated.
 */
export function withDefaultRateSelection(
  contract: SavedChemicalDefaultRates | null | undefined,
  selection: SavedChemicalDefaultRateSelection,
): SavedChemicalDefaultRates {
  const base = contract ?? emptyDefaultRates();
  return { ...base, version: DEFAULT_RATES_VERSION, [selection.basis]: selection };
}

/**
 * Clear ONE basis. The other is untouched, and no conversion is attempted:
 * clearing a per-hectare default says nothing about the per-100 L one.
 */
export function clearDefaultRateBasis(
  contract: SavedChemicalDefaultRates | null | undefined,
  basis: DefaultRateBasis,
): SavedChemicalDefaultRates {
  const base = contract ?? emptyDefaultRates();
  return { ...base, version: DEFAULT_RATES_VERSION, [basis]: null };
}

/** Whether anything at all is recorded. */
export function hasAnyDefaultRate(
  contract: SavedChemicalDefaultRates | null | undefined,
): boolean {
  return Boolean(contract && (contract.per_hectare || contract.per_100_litres));
}
