import type { ChemicalResearchResult } from "../research/schema.ts";
import { parseChemicalResearchResult } from "../research/schema.ts";
import type { ResponsesCallResult } from "../research/responses_client.ts";
import type { IndexedLabelInput } from "./manufacturer_label_index.ts";

/** Untrusted, allowlisted diagnostic data. Never use a snapshot as approved label evidence. */
export interface IndexedLabelSnapshot {
  version: 2;
  validator_version: 2;
  master: { id: string; revision: number } | null;
  model: string | null;
  response_id: string | null;
  validation: { status: string; reason: string | null } | null;
  complete: boolean;
  truncations?: Array<{ path: string; original: number; retained: number }>;
  locked: { document: string | null; name: string | null; registrant: string | null;
    registration: string | null; actives: Array<{ name: string | null; concentration: number | null; unit: string | null }> };
  tool: { sources: Array<{ action: string | null; refs: Array<string | null> }>;
    citations: Array<string | null>; incomplete: boolean };
  extracted: { product: { name: string | null; registrant: string | null; refs: Array<string | null> };
    registration: Array<{ scheme: string | null; number: string | null; country: string | null; source: string | null }>;
    actives: Array<{ name: string | null; concentration: number | null; unit: string | null; refs: Array<string | null> }>;
    uses: Array<{ crop: string | null; targets: Array<string | null>; restrictions: Array<string | null>;
      refs: Array<string | null>; rates: Array<{ value: number | null; min_value: number | null;
        max_value: number | null; basis: string | null; unit: string | null; raw_text: string | null;
        condition: string | null; table_heading?: string | null; table_context?: string | null;
        refs: Array<string | null> }> }> } | null;
  comparison: { product_source: boolean; product_name: boolean; registrant: boolean;
    normalised: { locked_name: string | null; extracted_name: string | null;
      locked_registrant: string | null; extracted_registrant: string | null } } | null;
}

const MAX_ROWS = 100;
const MAX_REFS = 20;
const MAX_TARGETS = 80;
const MAX_TEXT = 500;
const MAX_URL = 600;

function normal(value: string): string { return value.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim().replace(/\s+/g, " "); }
function sameUrl(a: string, b: string): boolean {
  try { const left = new URL(a); const right = new URL(b); left.hash = ""; right.hash = "";
    return left.protocol === "https:" && left.href === right.href; }
  catch { return false; }
}

/** Construct exactly one bounded snapshot before the validator's first evidence/identity return. */
export function captureIndexedLabelSnapshot(input: IndexedLabelInput, answer: ResponsesCallResult): IndexedLabelSnapshot {
  let complete = true;
  const truncations: NonNullable<IndexedLabelSnapshot["truncations"]> = [];
  const text = (value: string | null | undefined, max = MAX_TEXT, path = "unknown"): string | null => {
    if (value == null) return null;
    // Do not preserve credentials, private addresses, or unbounded provider prose even inside allowed fields.
    const cleaned = value.replace(/\bBearer\s+\S+|\b(?:api[_ -]?key|token|secret|password)\s*[:=]\s*\S+|\b[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\b|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}/gi, "[redacted]");
    if (cleaned !== value || cleaned.length > max) complete = false;
    if (cleaned.length > max) truncations.push({ path, original: cleaned.length, retained: max });
    return cleaned.slice(0, max);
  };
  const url = (value: string | null | undefined): string | null => {
    if (value == null) return null;
    try {
      const parsed = new URL(value);
      if (parsed.protocol !== "https:" || parsed.username || parsed.password || parsed.search || value.length > MAX_URL) {
        complete = false; return null;
      }
      return text(value, MAX_URL);
    } catch { complete = false; return null; }
  };
  const bounded = <T>(values: T[], limit: number, map: (value: T, index: number) => unknown, path = "unknown") => {
    if (values.length > limit) {
      complete = false;
      truncations.push({ path, original: values.length, retained: limit });
    }
    return values.slice(0, limit).map(map);
  };
  const refs = (values: string[]) => bounded(values, MAX_REFS, (value) => url(value)) as Array<string | null>;
  let research: ChemicalResearchResult | null = null;
  try { research = parseChemicalResearchResult(answer.payload); } catch { complete = false; }
  const lockedName = text(input.name);
  const lockedRegistrant = text(input.registrant);
  const extractedName = text(research?.product.canonical_name);
  const extractedRegistrant = text(research?.product.registrant);
  const ln = normal(lockedName ?? ""); const en = normal(extractedName ?? "");
  const lr = normal(lockedRegistrant ?? ""); const er = normal(extractedRegistrant ?? "");
  const snapshot: IndexedLabelSnapshot = {
    version: 2, validator_version: 2, master: null, model: text(answer.model, 80),
    response_id: text(answer.responseId, 120), validation: null, complete: false, truncations,
    locked: { document: url(input.labelUrl), name: lockedName, registrant: lockedRegistrant,
      registration: text(input.registrationNumber),
      actives: bounded(input.activeIngredients, MAX_ROWS, (active) => ({ name: text(active.name),
        concentration: active.concentration ?? null, unit: text(active.concentration_unit) })) as IndexedLabelSnapshot["locked"]["actives"] },
    tool: { sources: bounded(answer.webSearchCalls, MAX_ROWS, (call) => ({ action: text(call.action_type, 30),
      refs: refs(call.sources) })) as IndexedLabelSnapshot["tool"]["sources"],
      citations: refs(answer.citedUrls), incomplete: answer.incomplete },
    extracted: research ? {
      product: { name: extractedName, registrant: extractedRegistrant, refs: refs(research.product.source_refs) },
      registration: bounded(research.registration_candidates, MAX_ROWS, (candidate) => ({
        scheme: text(candidate.scheme, 30), number: text(candidate.number, 60), country: text(candidate.country, 10),
        source: url(candidate.source_url) })) as NonNullable<IndexedLabelSnapshot["extracted"]>["registration"],
      actives: bounded(research.active_ingredients, MAX_ROWS, (active) => ({ name: text(active.name),
        concentration: active.concentration, unit: text(active.concentration_unit), refs: refs(active.source_refs) })) as NonNullable<IndexedLabelSnapshot["extracted"]>["actives"],
      uses: bounded(research.registered_uses, MAX_ROWS, (use, index) => ({ crop: text(use.crop),
        targets: bounded(use.targets, MAX_TARGETS, (target, targetIndex) =>
          text(target, MAX_TEXT, `extracted.uses[${index}].targets[${targetIndex}]`),
          `extracted.uses[${index}].targets`) as Array<string | null>,
        restrictions: bounded(use.restrictions, MAX_REFS, (restriction) => text(restriction)) as Array<string | null>,
        refs: refs(use.source_refs), rates: bounded(use.rates, MAX_ROWS, (rate, rateIndex) => ({
          value: rate.value, min_value: rate.min_value, max_value: rate.max_value,
          basis: text(rate.basis, 40), unit: text(rate.unit, 30),
          raw_text: text(rate.raw_text, MAX_TEXT, `extracted.uses[${index}].rates[${rateIndex}].raw_text`),
          condition: text(rate.label, MAX_TEXT, `extracted.uses[${index}].rates[${rateIndex}].condition`),
          table_heading: text(rate.table_heading, MAX_TEXT, `extracted.uses[${index}].rates[${rateIndex}].table_heading`),
          table_context: text(rate.table_context, MAX_TEXT, `extracted.uses[${index}].rates[${rateIndex}].table_context`),
          refs: refs(rate.source_refs),
        }), `extracted.uses[${index}].rates`) as NonNullable<IndexedLabelSnapshot["extracted"]>["uses"][number]["rates"] }),
        "extracted.uses") as NonNullable<IndexedLabelSnapshot["extracted"]>["uses"],
    } : null,
    comparison: research ? { product_source: research.product.source_refs.length > 0 &&
      research.product.source_refs.every((source) => sameUrl(source, input.labelUrl)),
      product_name: !!en && !!ln && ln.split(" ").every((token) => en.split(" ").includes(token)),
      registrant: !research.product.registrant || er === lr,
      normalised: { locked_name: ln, extracted_name: en, locked_registrant: lr, extracted_registrant: er } } : null,
  };
  snapshot.complete = complete && !answer.incomplete && research !== null && answer.webSearchCalls.length > 0 &&
    new TextEncoder().encode(JSON.stringify(snapshot)).length <= 140_000;
  return snapshot;
}
