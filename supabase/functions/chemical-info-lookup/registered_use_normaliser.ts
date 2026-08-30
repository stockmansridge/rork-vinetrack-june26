// The handler's registered-use normaliser.
//
// # Why this is its own module
//
// This stage rebuilds every registered use as a FRESH object. That makes it
// the single most dangerous place in the pipeline for an additive field: a
// field it forgets to copy is not corrupted, it is silently ABSENT, and an
// absent safety field renders as "not stated on label" — indistinguishable
// from a label that genuinely says nothing.
//
// That is not hypothetical. The label document parser read CHATEAU 80647's
// "DO NOT HARVEST FOR 14 WEEKS AFTER APPLICATION" correctly, and this
// normaliser then discarded the wording one stage before any client could see
// it. It lived inside the edge function's request module, which exports
// nothing and calls `Deno.serve` at load, so it could not be imported and
// therefore could not be tested. It is extracted here so the carry contract is
// provable rather than assumed.
//
// Every field below is carried on purpose. Adding a field to the contract
// without adding it here is a silent data-loss bug.

import { DIRECTION_SEED_KEY } from "./rate_identity.ts";

/** A finite number, or null. Strings are accepted because upstream JSON varies. */
export function parseNumber(value: any): number | null {
  if (typeof value === "number" && isFinite(value)) return value;
  if (typeof value === "string") {
    const n = Number(value.trim());
    if (isFinite(n)) return n;
  }
  return null;
}

/**
 * A non-empty string, or null.
 *
 * The literal strings "null" and "unknown" are treated as absent: models and
 * scrapers emit them as text, and storing them would render to an operator as
 * though the label said the word "unknown".
 */
export function parseString(value: any): string | null {
  if (typeof value !== "string") return null;
  const t = value.trim();
  if (!t || t.toLowerCase() === "null" || t.toLowerCase() === "unknown") return null;
  return t;
}

/** Rate bases the wire contract carries. Anything else degrades to "other". */
export const RATE_BASES = new Set([
  "per_100_litres",
  "per_hectare",
  "range_per_100_litres",
  "range_per_hectare",
  "other",
]);

/**
 * Read an internal direction seed, keeping only its canonical grouping fields.
 *
 * Defensive by design: the seed is internal, so anything shaped unexpectedly
 * is dropped rather than trusted — a malformed seed must degrade to "no
 * grouping", never to a wrong one.
 */
export function readDirectionSeed(
  raw: any,
): { crop: string | null; targets: string[]; condition: string | null } | null {
  if (!raw || typeof raw !== "object") return null;
  const targets = Array.isArray(raw.targets)
    ? raw.targets.filter((t: unknown): t is string => typeof t === "string")
    : [];
  const crop = parseString(raw.crop);
  const condition = parseString(raw.condition);
  if (!targets.length && !crop && !condition) return null;
  return { crop, targets, condition };
}

export function normaliseRegisteredUses(raw: any): any[] {
  if (!Array.isArray(raw)) return [];
  const out: any[] = [];
  for (const use of raw) {
    const crop = parseString(use?.crop);
    const target = parseString(use?.target) ?? parseString(use?.target_raw);
    if (!crop && !target) continue;
    const rates: any[] = [];
    if (Array.isArray(use?.rates)) {
      for (const r of use.rates) {
        let basis = parseString(r?.basis)?.toLowerCase() ?? "other";
        if (!RATE_BASES.has(basis)) basis = "other";
        const value = parseNumber(r?.value);
        const minValue = parseNumber(r?.min_value);
        const maxValue = parseNumber(r?.max_value);
        // A rate with no number at all is only meaningful if the label text was
        // captured verbatim; otherwise it says nothing and is dropped.
        const rawText = parseString(r?.raw_text);
        if (value === null && minValue === null && !rawText) continue;
        // An identity minted upstream is CARRIED, never dropped and re-derived.
        // This normaliser rebuilds every row as a fresh object, so anything it
        // forgets to copy is silently lost — and a rate identity re-derived
        // here would be computed from the projected single target rather than
        // the printed direction it came from (Gate D1.2).
        const rateId = parseString(r?.rate_id);
        // Whether the label made this rate conditional on something the
        // parser could not resolve. Dropping it would present a qualified
        // rate as an unqualified one.
        const conditionAmbiguous = r?.condition_ambiguous === true;

        rates.push({
          label: parseString(r?.label) ?? "",
          basis,
          value,
          min_value: minValue,
          max_value: maxValue,
          unit: parseString(r?.unit) ?? "",
          raw_text: rawText,
          ...(rateId ? { rate_id: rateId } : {}),
          ...(conditionAmbiguous ? { condition_ambiguous: true } : {}),
        });
      }
    }
    // A CONDITIONAL re-entry rule ("until the spray has dried") has no number
    // in it. Carrying only the hours dropped the rule entirely, and the app
    // then reported "Not stated on label" about a label that states it
    // plainly. The wording travels BESIDE the hours, never instead of them,
    // and never becomes a fabricated number.
    const reEntryStatement = parseString(use?.re_entry_statement);
    // The withholding WORDING, carried for exactly the reason the re-entry
    // wording is. The number is the scheduling projection; this is the legal
    // instruction, and a client must be able to show the operator both.
    const withholdingStatement = parseString(use?.withholding_statement);
    // Carried for the same reason as `rate_id` above: this row may be one of
    // several fanned out from a single printed direction, and only the
    // upstream minter could still see that direction's complete target set.
    const directionId = parseString(use?.direction_id);
    // Which source established this row's safety fields. Without it a client
    // cannot tell a registrant label from a model's reading.
    const provenance = use?.provenance && typeof use.provenance === "object"
      ? { ...use.provenance }
      : null;
    // The internal pre-lock grouping (Gate D1.3). This normaliser rebuilds
    // every row as a fresh object, so a seed it forgot to copy would be
    // silently lost — and the printed direction's complete target set with it,
    // leaving the later mint to derive identity from one surviving pest.
    const directionSeed = readDirectionSeed(use?.[DIRECTION_SEED_KEY]);

    out.push({
      crop: crop ?? "",
      target_raw: target ?? "",
      ...(directionId ? { direction_id: directionId } : {}),
      ...(directionSeed ? { [DIRECTION_SEED_KEY]: directionSeed } : {}),
      rates,
      withholding_period_days: parseNumber(use?.withholding_period_days),
      ...(withholdingStatement ? { withholding_statement: withholdingStatement } : {}),
      re_entry_period_hours: parseNumber(use?.re_entry_period_hours),
      ...(reEntryStatement ? { re_entry_statement: reEntryStatement } : {}),
      restrictions: parseString(use?.restrictions),
      ...(provenance ? { provenance } : {}),
    });
  }
  return out;
}
