// Manufacturer-label-first grapevine projection.
//
// # What changed, and why
//
// The pipeline was built register-first: the APVMA register decided identity
// AND supplied the practical spray data. That is the wrong order for the
// second half. The register's PubCRIS extract is a regulatory dataset — it
// carries hosts, pests and registration facts, but the printed label is where
// the rate table, the conditional states and the dormancy restrictions
// actually live.
//
// So the priority is now split:
//
//   IDENTITY (unchanged, still register-authoritative)
//     registration number, registered product name, registrant, country,
//     regulatory confirmation
//
//   PRACTICAL LABEL DATA (this module)
//     1. manufacturer-hosted product label
//     2. regulator label + registration data
//     3. manufacturer product page
//     4. other research — discovery/support only
//
// # Why grapevine is not "just another crop"
//
// A vineyard label lists almonds, pome fruit, stone fruit and citrus beside
// grapevines. Serving all of them equally buries the two rows a grower needs
// behind twenty they will never use. Grapevine uses lead; everything else is
// retained in full but secondary.
//
// # The rule that must not be softened
//
// If the label does not register the product on grapevines, this module does
// NOT invent one. It offers a clearly-classified reference range built from
// like-for-like bases so an operator can see the order of magnitude the label
// works in — explicitly `not_registered_for_grapevine`, never a rate.

// deno-lint-ignore-file no-explicit-any

import type { WireLabelRate } from "./ingestion/contract.ts";

/**
 * Crop wording that means grapevines.
 *
 * Deliberately a closed list of WHOLE tokens, not a substring test:
 * "GRAPEFRUIT" contains "grape" and is a citrus. Matching it would put a
 * citrus rate on a vineyard spray record.
 */
const GRAPEVINE_TOKENS = new Set<string>([
  "grape",
  "grapes",
  "grapevine",
  "grapevines",
  "vine",
  "vines",
  "vineyard",
  "vineyards",
  "winegrape",
  "winegrapes",
  "tablegrape",
  "tablegrapes",
]);

/**
 * Multi-word crop wordings that mean grapevines.
 *
 * Checked as adjacent token pairs, so "WINE GRAPES", "TABLE GRAPES" and
 * "DRIED GRAPES" resolve without letting a bare "wine" or "dried" through.
 */
const GRAPEVINE_PHRASES = new Set<string>([
  "wine grape",
  "wine grapes",
  "table grape",
  "table grapes",
  "dried grape",
  "dried grapes",
  "grape vine",
  "grape vines",
]);

/** VineTrack's single normalised crop class for everything above. */
export const GRAPEVINE_CROP_CLASS = "Grapevines";

function cropTokens(crop: string): string[] {
  return String(crop ?? "")
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((t) => t.length > 0);
}

/**
 * Whether a label's crop wording means grapevines.
 *
 * Whole-token and adjacent-pair matching only. `GRAPEFRUIT` must never match:
 * it is a citrus, and a citrus rate on a vineyard record is a wrong dose with
 * a plausible name.
 */
export function isGrapevineCrop(crop: string): boolean {
  const tokens = cropTokens(crop);
  if (!tokens.length) return false;
  for (const t of tokens) if (GRAPEVINE_TOKENS.has(t)) return true;
  for (let i = 0; i < tokens.length - 1; i++) {
    if (GRAPEVINE_PHRASES.has(`${tokens[i]} ${tokens[i + 1]}`)) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Rate ordering
// ---------------------------------------------------------------------------

/** Bases that express a dose per 100 L of spray solution. */
const PER_100L_BASES = new Set(["per_100_litres", "range_per_100_litres"]);
/** Bases that express a dose per hectare. */
const PER_HA_BASES = new Set(["per_hectare", "range_per_hectare"]);

export function isPer100L(rate: { basis?: string }): boolean {
  return PER_100L_BASES.has(String(rate?.basis ?? ""));
}

export function isPerHectare(rate: { basis?: string }): boolean {
  return PER_HA_BASES.has(String(rate?.basis ?? ""));
}

/**
 * Order rates for display: /100 L first, then /ha, then verbatim-only.
 *
 * STABLE within each group, so the label's printed order survives. This is
 * presentation ONLY — nothing is dropped, nothing is converted, and the /ha
 * rate is never removed because a /100 L rate exists. A label that states
 * both states both.
 */
export function orderRatesPer100LFirst<T extends { basis?: string }>(
  rates: T[],
): T[] {
  const rank = (r: T): number => (isPer100L(r) ? 0 : isPerHectare(r) ? 1 : 2);
  return [...(rates ?? [])]
    .map((rate, index) => ({ rate, index }))
    .sort((a, b) => rank(a.rate) - rank(b.rate) || a.index - b.index)
    .map((x) => x.rate);
}

// ---------------------------------------------------------------------------
// Grapevine-first partitioning
// ---------------------------------------------------------------------------

export interface GrapevinePartition<T> {
  /** Uses registered on grapevines, rates already ordered /100 L first. */
  grapevine: T[];
  /** Every other crop on the label, retained in full and in label order. */
  otherCrops: T[];
}

/**
 * Split registered uses into grapevine and everything else.
 *
 * Other crops are RETAINED, not discarded: they are real label content, and a
 * grower checking whether a drum can be used elsewhere needs them. They are
 * simply not the vineyard workflow, so they belong in a collapsed section.
 */
export function partitionGrapevineUses<T extends { crop?: string; rates?: any[] }>(
  uses: T[],
): GrapevinePartition<T> {
  const grapevine: T[] = [];
  const otherCrops: T[] = [];
  for (const use of uses ?? []) {
    const bucket = isGrapevineCrop(String(use?.crop ?? "")) ? grapevine : otherCrops;
    bucket.push(
      Array.isArray(use?.rates)
        ? { ...use, rates: orderRatesPer100LFirst(use.rates) }
        : use,
    );
  }
  return { grapevine, otherCrops };
}

// ---------------------------------------------------------------------------
// Reference range for products with no grapevine registration
// ---------------------------------------------------------------------------

/** Why a reference range was produced instead of a registered rate. */
export type LabelReferenceClassification = "not_registered_for_grapevine";

export interface LabelReferenceRateRange {
  /** Always the same value today; explicit so a client cannot mistake this
   *  for a registered rate. */
  classification: LabelReferenceClassification;
  /** "per_100_litres" or "per_hectare" — the BASIS the range was built from.
   *  Ranges are never built across bases. */
  basis: "per_100_litres" | "per_hectare";
  min_value: number;
  max_value: number;
  unit: string;
  /** The crops whose rates contributed, so the operator can judge relevance. */
  derived_from_crops: string[];
  /** Plain-language statement of what this is and is not. */
  note: string;
}

/** All numeric readings a rate carries, whatever its basis. */
function rateValues(rate: WireLabelRate): number[] {
  const out: number[] = [];
  if (typeof rate.value === "number" && Number.isFinite(rate.value)) {
    out.push(rate.value);
  }
  if (typeof rate.min_value === "number" && Number.isFinite(rate.min_value)) {
    out.push(rate.min_value);
  }
  if (typeof rate.max_value === "number" && Number.isFinite(rate.max_value)) {
    out.push(rate.max_value);
  }
  return out;
}

/**
 * Derive like-for-like reference ranges from a label with no grapevine use.
 *
 * # What this is for
 *
 * A grower holding a drum that is not registered on grapevines still needs to
 * know roughly what the label works in — 100–200 mL/100 L is a very different
 * product from 2–3 L/100 L. That context is useful. Presenting it as a
 * grapevine rate would be a compliance failure.
 *
 * # The rules
 *
 *   * LIKE-FOR-LIKE ONLY. /100 L is ranged with /100 L, /ha with /ha. Mixing
 *     them would require a carrier volume the label never stated.
 *   * ONE UNIT PER RANGE. mL and L are not ranged together — "100 mL to 3 L"
 *     is arithmetic, not a label reading. The unit with the most readings
 *     wins; a tie fails closed and emits nothing for that basis.
 *   * NEVER returned when a grapevine use exists. Caller enforces; asserted
 *     by tests.
 *
 * Returns one entry per basis that produced a usable range, or [] when the
 * label states nothing comparable.
 */
export function deriveLabelReferenceRateRanges(
  uses: { crop?: string; rates?: WireLabelRate[] }[],
): LabelReferenceRateRange[] {
  const buckets = new Map<
    string,
    { values: number[]; crops: Set<string>; basis: "per_100_litres" | "per_hectare" }
  >();

  for (const use of uses ?? []) {
    const crop = String(use?.crop ?? "").trim();
    for (const rate of use?.rates ?? []) {
      const basis = isPer100L(rate)
        ? "per_100_litres"
        : isPerHectare(rate)
        ? "per_hectare"
        : null;
      if (!basis) continue; // basis "other" is verbatim wording, not a number
      const unit = String(rate.unit ?? "").trim();
      if (!unit) continue;
      const values = rateValues(rate);
      if (!values.length) continue;

      const key = `${basis}::${unit}`;
      const bucket = buckets.get(key) ?? { values: [], crops: new Set(), basis };
      bucket.values.push(...values);
      if (crop) bucket.crops.add(crop);
      buckets.set(key, bucket);
    }
  }

  const out: LabelReferenceRateRange[] = [];
  for (const basis of ["per_100_litres", "per_hectare"] as const) {
    const forBasis = [...buckets.entries()].filter(([, b]) => b.basis === basis);
    if (!forBasis.length) continue;

    // One unit per basis. A tie between two units is genuinely undecidable, so
    // nothing is emitted rather than picking one — a reference range in the
    // wrong unit is worse than no reference range.
    const sorted = [...forBasis].sort((a, b) => b[1].values.length - a[1].values.length);
    if (sorted.length > 1 && sorted[0][1].values.length === sorted[1][1].values.length) {
      continue;
    }
    const [key, bucket] = sorted[0];
    const unit = key.split("::")[1] ?? "";
    const min = Math.min(...bucket.values);
    const max = Math.max(...bucket.values);
    const basisLabel = basis === "per_100_litres" ? "/100 L" : "/ha";

    out.push({
      classification: "not_registered_for_grapevine",
      basis,
      min_value: min,
      max_value: max,
      unit,
      derived_from_crops: [...bucket.crops].sort(),
      note: `This product is not registered for use on grapevines. The label ` +
        `states rates between ${min} and ${max} ${unit}${basisLabel} for other ` +
        `crops. Shown for reference only — it is not a registered grapevine ` +
        `rate and must not be used as one.`,
    });
  }
  return out;
}

// ---------------------------------------------------------------------------
// Label references — manufacturer first, regulator second
// ---------------------------------------------------------------------------

export interface LabelReferences {
  /**
   * The registrant/manufacturer-hosted label document. The PRIMARY
   * "Open label" link for growers: it is the label they physically hold, and
   * usually the more readable rendering.
   */
  manufacturer_label_url: string | null;
  /**
   * The regulator's approved label (APVMA eLabels etc.). Authoritative for
   * registration, and kept ALWAYS — a manufacturer page can never substitute
   * for the approved label, only lead with it.
   */
  regulator_label_url: string | null;
  /** The registrant's marketing/product page. Never a label. */
  manufacturer_product_url: string | null;
  /**
   * The Safety Data Sheet, when one was found.
   *
   * Carried as its OWN identity so it can never drift into a label slot. An
   * SDS describes handling and first aid; its wording beside a rate table
   * would read as label direction.
   */
  sds_url: string | null;
  /** Back-compat: the single field older clients read. */
  label_reference: string | null;
}

/** Hosts whose documents are the regulator's own. */
function isRegulatorHost(url: string): boolean {
  try {
    const host = new URL(url).hostname.toLowerCase();
    return host.endsWith("apvma.gov.au") ||
      host.endsWith("gov.au") ||
      host.endsWith("govt.nz") ||
      host.endsWith("epa.govt.nz");
  } catch {
    return false;
  }
}

function cleanUrl(raw: unknown): string | null {
  const v = String(raw ?? "").trim();
  if (!v) return null;
  return /^https?:\/\//i.test(v) ? v : null;
}

/**
 * Split discovered label URLs into the manufacturer label, the regulator
 * label and the product page.
 *
 * # Why `label_reference` still exists
 *
 * Shipped clients read one field. If this returned only the two new ones,
 * every installed build would show no label at all. `label_reference` keeps
 * pointing at the REGULATOR label when there is one — the authoritative
 * document, and what those builds already expect — so nothing regresses while
 * new clients adopt the split.
 *
 * A regulator-hosted URL offered as the manufacturer label is reclassified
 * rather than duplicated: the two fields must mean different things, or the
 * UI's "manufacturer first, regulator second" ordering becomes one document
 * printed twice.
 */
export function selectLabelReferences(input: {
  manufacturerLabelUrl?: unknown;
  regulatorLabelUrl?: unknown;
  productUrl?: unknown;
  sdsUrl?: unknown;
}): LabelReferences {
  const regulatorFromInput = cleanUrl(input.regulatorLabelUrl);
  const manufacturerRaw = cleanUrl(input.manufacturerLabelUrl);

  // A regulator-hosted "manufacturer label" is a regulator label.
  const manufacturerIsRegulator = manufacturerRaw !== null &&
    isRegulatorHost(manufacturerRaw);

  const regulator = regulatorFromInput ??
    (manufacturerIsRegulator ? manufacturerRaw : null);
  const manufacturer = manufacturerIsRegulator ? null : manufacturerRaw;

  return {
    manufacturer_label_url: manufacturer,
    regulator_label_url: regulator,
    manufacturer_product_url: cleanUrl(input.productUrl),
    sds_url: cleanUrl(input.sdsUrl),
    // Authoritative document first for legacy readers.
    label_reference: regulator ?? manufacturer,
  };
}

// ---------------------------------------------------------------------------
// The projection served to clients
// ---------------------------------------------------------------------------

export interface GrapevineProjection {
  /** Grapevine uses, /100 L rates first. Empty when not registered. */
  grapevine_uses: any[];
  /** Every other crop on the label, retained. */
  other_crop_uses: any[];
  /** True when the label registers this product on grapevines. */
  registered_for_grapevine: boolean;
  /** Reference ranges — ONLY when there is no grapevine registration. */
  label_reference_rate_ranges: LabelReferenceRateRange[];
}

/**
 * Project registered uses into the grapevine-first shape the review screen
 * consumes.
 *
 * The reference range is computed ONLY when no grapevine use exists. Emitting
 * both would put a registered rate and an unregistered reference range on one
 * screen, and the first misreading of that would be a spray.
 */
export function projectGrapevineUses(uses: any[]): GrapevineProjection {
  const { grapevine, otherCrops } = partitionGrapevineUses(uses ?? []);
  const registered = grapevine.length > 0;
  return {
    grapevine_uses: grapevine,
    other_crop_uses: otherCrops,
    registered_for_grapevine: registered,
    label_reference_rate_ranges: registered
      ? []
      : deriveLabelReferenceRateRanges(otherCrops),
  };
}
