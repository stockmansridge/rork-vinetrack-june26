import type { MasterRow } from "./contract.ts";
import type { ResearchRegisteredUse } from "../research/schema.ts";
import { parseChemicalResearchResult } from "../research/schema.ts";
import { callResponsesApi, DEFAULT_RESEARCH_MODEL, OpenAIResearchError, type ResponsesCallResult } from "../research/responses_client.ts";
import { classifyUrl, manufacturerHostEligible } from "../research/classify.ts";
import { DIRECTION_SEED_KEY } from "../rate_identity.ts";
import { captureIndexedLabelSnapshot, type IndexedLabelSnapshot } from "./manufacturer_label_snapshot.ts";

/** An indexed read is permitted only after the original verified PDF was access-denied and the alternate failed. */
export function shouldReadManufacturerIndex(originalStatus: number | null | undefined, alternateSucceeded: boolean): boolean {
  return (originalStatus === 403 || originalStatus === 429) && !alternateSucceeded;
}

/** A query-string change cannot make an access-denied PDF into a distinct alternate. */
export function distinctLabelDocument(original: string, candidate: string): boolean {
  try {
    const first = new URL(original); const second = new URL(candidate);
    return first.protocol === "https:" && second.protocol === "https:" &&
      (first.host !== second.host || first.pathname !== second.pathname);
  } catch { return false; }
}

/** The indexed candidate is the last distinct approved PDF actually fetched, never an unattempted discovery lead. */
export function finalAttemptedLabelUrl(original: string, alternate: string | null, alternateAttempted: boolean): string {
  return alternateAttempted && alternate ? alternate : original;
}

export const MANUFACTURER_INDEX_TIMEOUT_MS = 60_000;

export type IndexFailureReason = "candidate_not_approved" | "index_request_failed" |
  "index_request_timeout" | "index_request_transient" | "index_request_permanent" | "index_request_refusal" | "no_web_search_evidence" |
  "exact_url_not_consulted" | "malformed_index_result" | "product_identity_mismatch" |
  "registration_missing" | "active_identity_mismatch" | "rate_no_vineyard_rows" |
  "rate_use_source_mismatch" | "rate_source_mismatch" | "rate_value_invalid" |
  "rate_raw_text_missing" | "rate_basis_unrecognised" | "rate_unit_unrecognised" |
  "rate_raw_text_mismatch" | "rate_state_soil_missing" | "simanex_completeness_failed";

export interface IndexedLabelInput {
  name: string;
  registrant: string;
  registrationNumber: string;
  activeIngredients: MasterRow["active_ingredients"];
  labelUrl: string;
  country: string;
  apiKey: string;
  fetchFn?: typeof fetch;
  /** Opt-in controlled capture; never logged or included in the public preview response. */
  onDiagnosticSnapshot?: (snapshot: IndexedLabelSnapshot) => void;
}

type IndexedLabelResult = { status: "ready"; uses: Record<string, unknown>[];
  actives: Array<Record<string, unknown>>; identifiers: { numbers: string[]; printed_values: string[] } } |
  { status: "label_index_unavailable"; reason: IndexFailureReason } |
  { status: "identity_conflict"; reason: "product_identity_mismatch" | "printed_registration_mismatch" | "active_identity_mismatch" };

function exactUrl(a: string, b: string): boolean {
  try {
    const left = new URL(a); const right = new URL(b);
    left.hash = ""; right.hash = "";
    return left.protocol === "https:" && left.href === right.href;
  } catch { return false; }
}

function normal(text: string): string {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim().replace(/\s+/g, " ");
}

function stateSoil(text: string): string | null {
  // Explicit context is required for every indexed vineyard dose; vague prose must not mint an identity.
  const state = /\b(?:state|region)\s*:\s*((?:(?:Qld|NSW|Vic|SA|Tas|WA|ACT|NT)(?:\s*[,/ -]+\s*)?)+)(?:\bonly\b)?/i.exec(text)?.[1];
  const soil = /\b(?:soil)\s*:\s*(light|heavy)\b/i.exec(text)?.[1];
  if (!state || !soil) return null;
  const states = state.match(/Qld|NSW|Vic|SA|Tas|WA|ACT|NT/gi) ?? [];
  return states.length ? `State: ${[...new Set(states.map((s) => s.toUpperCase()))].join(", ")}; Soil: ${soil.toLowerCase()}` : null;
}

type PrintedDoseFailure = Extract<IndexFailureReason,
  "rate_value_invalid" | "rate_raw_text_missing" | "rate_basis_unrecognised" |
  "rate_unit_unrecognised" | "rate_raw_text_mismatch">;

function printedDoseFailure(rate: ResearchRegisteredUse["rates"][number], crop: string): PrintedDoseFailure | null {
  if (rate.value === null || !Number.isFinite(rate.value) || rate.value <= 0) return "rate_value_invalid";
  if (!rate.raw_text) return "rate_raw_text_missing";
  const basis = rate.basis === "per_hectare" ? "ha" : rate.basis === "per_100_litres" ? "100 L" : null;
  if (!basis) return "rate_basis_unrecognised";
  if (!rate.unit) return "rate_unit_unrecognised";
  const unit = rate.unit.replace(/[^a-z]/gi, "");
  if (!/^(kg|g|l|ml)$/i.test(unit)) return "rate_unit_unrecognised";
  const doseTokens = [...rate.raw_text.matchAll(/\b(\d+(?:\.\d+)?)\s*(kg|g|ml|l)\b(?:\s*\/\s*(ha|100\s*l)\b)?/gi)];
  if (doseTokens.length !== 1 || Number(doseTokens[0][1]) !== rate.value ||
    doseTokens[0][2].toLowerCase() !== unit.toLowerCase()) return "rate_raw_text_mismatch";
  if (/^\s*\/\s*\S+/.test(rate.raw_text.slice((doseTokens[0].index ?? 0) + doseTokens[0][0].length)))
    return "rate_raw_text_mismatch";
  const printedBasis = doseTokens[0][3]?.replace(/\s/g, "").toLowerCase();
  if (printedBasis) return printedBasis === basis.replace(/\s/g, "").toLowerCase() ? null : "rate_raw_text_mismatch";
  const context = rate.table_context ?? "";
  const heading = rate.table_heading ?? "";
  if (!/^\s*RATE\s*\/\s*ha\s*$/i.test(heading) || basis !== "ha" ||
    normal(/^\s*Crop\s*:\s*([^;]+)\s*;/i.exec(context)?.[1] ?? "") !== normal(crop) ||
    !stateSoil(context) || stateSoil(context) !== stateSoil(rate.label ?? "")) return "rate_raw_text_mismatch";
  return null;
}

/** Read only a previously accepted, registrant-hosted manufacturer PDF through the existing Responses web index. */
export async function readManufacturerLabelViaWebIndex(input: IndexedLabelInput): Promise<IndexedLabelResult> {
  if (input.country !== "AU" || !input.name || !input.registrant || !/^\d{4,7}$/.test(input.registrationNumber) ||
    !input.activeIngredients.length || !input.apiKey || !manufacturerHostEligible(input.labelUrl, input.country, input.registrant) ||
    classifyUrl(input.labelUrl, input.country).kind !== "label_document" ||
    !new URL(input.labelUrl).pathname.toLowerCase().endsWith(".pdf")) return { status: "label_index_unavailable", reason: "candidate_not_approved" };
  let answer: ResponsesCallResult;
  try {
    answer = await callResponsesApi({ model: DEFAULT_RESEARCH_MODEL, apiKey: input.apiKey,
      fetchFn: input.fetchFn ?? fetch, timeoutMs: MANUFACTURER_INDEX_TIMEOUT_MS, reasoningEffort: "low",
      searchCountry: "AU", allowedDomains: [new URL(input.labelUrl).hostname],
      instructions: `Read only the exact manufacturer product label identified by this URL: ${input.labelUrl}.
Do not use APVMA, regulators, resellers, SDS, technical notes, brochures, other products, or model memory.
If the exact manufacturer label cannot be read from the web index, return no extracted evidence.
Report only facts printed on that exact PDF. Put its exact URL in every product, active, use and rate source_refs. Do not search for a replacement registration source. Report the printed APVMA approval identifier (including any suffix) in the registration candidate number and use the exact PDF as source_url. Never infer an absent number or concentration.
For each grapevine dose create a separate use/rate. Preserve the printed rate cell in raw_text, without appending a denominator not printed in the cell. If the denominator appears only in the SAME table's heading directly governing that crop/state/soil cell, provide the verbatim table_heading and table_context (Crop: <crop>; State: <states>; Soil: <light or heavy>) on that rate; otherwise leave them null. An explicit cell denominator (including /100 L water) always overrides the heading. In the rate label explicitly include State: <printed states>; Soil: <light or heavy>. Keep each /100 L alternative as its own rate. Keep controlled weeds and suppression claims distinct in targets (prefix a suppression target with 'Suppression: '); never merge the claims. Keep state-specific critical comments in that use's restrictions. If state, soil or printed dose cannot be bound, return no such rate.`,
      input: `Exact manufacturer label URL: ${input.labelUrl}\nLocked product: ${input.name}\nRegistrant: ${input.registrant}\nCanonical APVMA number: ${input.registrationNumber}\nLocked actives: ${input.activeIngredients.map((a) => `${a.name} ${a.concentration ?? "unknown"} ${a.concentration_unit ?? ""}`).join("; ")}` });
  } catch (error) {
    const category = error instanceof OpenAIResearchError ? error.category : null;
    const reason: IndexFailureReason = category === "malformed" ? "malformed_index_result" :
      category === "timeout" ? "index_request_timeout" :
      category === "transient" ? "index_request_transient" :
      category === "permanent" ? "index_request_permanent" :
      category === "refusal" ? "index_request_refusal" : "index_request_failed";
    return { status: "label_index_unavailable", reason };
  }
  let snapshot: IndexedLabelSnapshot | null = null;
  if (input.onDiagnosticSnapshot) {
    try { snapshot = captureIndexedLabelSnapshot(input, answer); }
    catch { /* Diagnostic delivery must not affect validation. */ }
  }
  const finish = (result: IndexedLabelResult): IndexedLabelResult => {
    if (snapshot && input.onDiagnosticSnapshot) {
      snapshot.validation = { status: result.status, reason: result.status === "ready" ? null : result.reason };
      try { input.onDiagnosticSnapshot(snapshot); } catch { /* Diagnostic delivery must not affect validation. */ }
    }
    return result;
  };
  if (answer.incomplete || !answer.webSearchCalls.length)
    return finish({ status: "label_index_unavailable", reason: "no_web_search_evidence" });
  if (![...answer.consultedUrls, ...answer.citedUrls].some((url) => exactUrl(url, input.labelUrl)))
    return finish({ status: "label_index_unavailable", reason: "exact_url_not_consulted" });
  let research;
  try { research = parseChemicalResearchResult(answer.payload); }
  catch { return finish({ status: "label_index_unavailable", reason: "malformed_index_result" }); }
  const refs = (urls: string[]) => urls.length > 0 && urls.every((url) => exactUrl(url, input.labelUrl));
  const name = normal(research.product.canonical_name ?? "");
  const expected = normal(input.name);
  if (!refs(research.product.source_refs) || !name || !expected ||
    !expected.split(" ").every((token) => name.split(" ").includes(token)) ||
    research.product.registrant && normal(research.product.registrant) !== normal(input.registrant))
    return finish({ status: "identity_conflict", reason: "product_identity_mismatch" });
  const printed = research.registration_candidates.filter((candidate) => candidate.scheme === "apvma" &&
    candidate.source_url && exactUrl(candidate.source_url, input.labelUrl) && candidate.country === "AU")
    .map((candidate) => candidate.number ?? "");
  if (!printed.length) return finish({ status: "label_index_unavailable", reason: "registration_missing" });
  if (printed.some((number) => !/^\d{4,7}(?:\/\d{4,7})*$/.test(number) ||
    number.split("/")[0] !== input.registrationNumber)) return finish({ status: "identity_conflict", reason: "printed_registration_mismatch" });
  if (research.active_ingredients.length !== input.activeIngredients.length ||
    input.activeIngredients.some((locked) => !research.active_ingredients.some((active) =>
      normal(active.name) === normal(locked.name) && refs(active.source_refs) &&
      active.concentration != null && active.concentration_unit != null &&
      (locked.concentration == null || locked.concentration === active.concentration) &&
      (locked.concentration_unit == null || normal(locked.concentration_unit) === normal(active.concentration_unit)))))
    return finish({ status: "identity_conflict", reason: "active_identity_mismatch" });
  const uses: Record<string, unknown>[] = [];
  const doseRows: Array<{ condition: string; value: number | null; unit: string | null; basis: string; restrictions: string }> = [];
  for (const use of research.registered_uses) {
    if (!/grape|vineyard/i.test(use.crop)) continue;
    if (!refs(use.source_refs)) return finish({ status: "label_index_unavailable", reason: "rate_use_source_mismatch" });
    for (const rate of use.rates) {
      if (!refs(rate.source_refs)) return finish({ status: "label_index_unavailable", reason: "rate_source_mismatch" });
      const doseFailure = printedDoseFailure(rate, use.crop);
      if (doseFailure) return finish({ status: "label_index_unavailable", reason: doseFailure });
      const condition = stateSoil(rate.label ?? "");
      if (!condition) return finish({ status: "label_index_unavailable", reason: "rate_state_soil_missing" });
      doseRows.push({ condition, value: rate.value, unit: rate.unit, basis: rate.basis,
        restrictions: use.restrictions.join("; ") });
      for (const target of use.targets.length ? use.targets : [""]) uses.push({ crop: use.crop, target,
        [DIRECTION_SEED_KEY]: { crop: use.crop, targets: use.targets, condition },
        conditions: condition, restrictions: use.restrictions.join("; ") || null,
        rates: [{ label: condition, basis: rate.basis, value: rate.value, min_value: null, max_value: null,
          unit: rate.unit, raw_text: rate.raw_text, source_refs: [input.labelUrl] }], source_refs: [input.labelUrl] });
    }
  }
  if (!uses.length) return finish({ status: "label_index_unavailable", reason: "rate_no_vineyard_rows" });
  // The SIMANEX acceptance contract is a completeness check, never a source of rates.
  if (input.registrationNumber === "62917" && normal(input.name) === "simanex 900 wg herbicide") {
    const expected = [
      ["QLD", "light", 2, "kg", "per_hectare"], ["QLD", "heavy", 4, "kg", "per_hectare"],
      ["NSW, VIC, SA, TAS, WA", "light", 1.25, "kg", "per_hectare"],
      ["NSW, VIC, SA, TAS, WA", "light", 60, "g", "per_100_litres"],
      ["NSW, VIC, SA, TAS, WA", "heavy", 2.5, "kg", "per_hectare"],
      ["NSW, VIC, SA, TAS, WA", "heavy", 120, "g", "per_100_litres"],
    ] as const;
    if (doseRows.length !== expected.length || expected.some(([states, soil, amount, unit, basis]) =>
      doseRows.filter((row) => row.condition === `State: ${states}; Soil: ${soil}` &&
        row.value === amount && row.unit === unit && row.basis === basis &&
        (states === "QLD" ? /at least two years old/i : /at least 12 months old.*split applications are preferred/i)
          .test(row.restrictions)).length !== 1)) return finish({ status: "label_index_unavailable", reason: "simanex_completeness_failed" });
  }
  const printed_values = [...new Set(printed)];
  return finish({ status: "ready", uses,
    actives: research.active_ingredients.map((active) => ({ name: active.name, concentration: active.concentration,
      concentration_unit: active.concentration_unit, identity_source: "manufacturer_label" })),
    identifiers: { numbers: [...new Set(printed_values.flatMap((value) => value.split("/")))], printed_values } });
}
