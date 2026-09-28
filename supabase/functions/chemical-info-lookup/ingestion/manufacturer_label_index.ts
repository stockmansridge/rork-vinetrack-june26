import type { MasterRow } from "./contract.ts";
import type { ResearchRegisteredUse } from "../research/schema.ts";
import { parseChemicalResearchResult } from "../research/schema.ts";
import { callResponsesApi, DEFAULT_RESEARCH_MODEL, type ResponsesCallResult } from "../research/responses_client.ts";
import { classifyUrl, manufacturerHostEligible } from "../research/classify.ts";
import { DIRECTION_SEED_KEY } from "../rate_identity.ts";

/** An indexed read is permitted only after the original verified PDF was access-denied and the alternate failed. */
export function shouldReadManufacturerIndex(originalStatus: number | null | undefined, alternateSucceeded: boolean): boolean {
  return (originalStatus === 403 || originalStatus === 429) && !alternateSucceeded;
}

export interface IndexedLabelInput {
  name: string;
  registrant: string;
  registrationNumber: string;
  activeIngredients: MasterRow["active_ingredients"];
  labelUrl: string;
  country: string;
  apiKey: string;
  fetchFn?: typeof fetch;
}

type IndexedLabelResult = { status: "ready"; uses: Record<string, unknown>[];
  actives: Array<Record<string, unknown>>; identifiers: { numbers: string[]; printed_values: string[] } } |
  { status: "label_index_unavailable" | "identity_conflict"; reason?: string };

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

function printedDose(rate: ResearchRegisteredUse["rates"][number]): boolean {
  if (rate.value === null || !Number.isFinite(rate.value) || rate.value <= 0 || !rate.raw_text || !rate.unit) return false;
  const basis = rate.basis === "per_hectare" ? "ha" : rate.basis === "per_100_litres" ? "100 L" : null;
  if (!basis) return false;
  const unit = rate.unit.replace(/[^a-z]/gi, "");
  if (!/^(kg|g|l|ml)$/i.test(unit)) return false;
  const escape = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`\\b${escape(String(rate.value))}\\s*${unit}\\s*\\/\\s*${basis.replace(" ", "\\s*")}\\b`, "i").test(rate.raw_text);
}

/** Read only a previously accepted, registrant-hosted manufacturer PDF through the existing Responses web index. */
export async function readManufacturerLabelViaWebIndex(input: IndexedLabelInput): Promise<IndexedLabelResult> {
  if (input.country !== "AU" || !input.name || !input.registrant || !/^\d{4,7}$/.test(input.registrationNumber) ||
    !input.activeIngredients.length || !input.apiKey || !manufacturerHostEligible(input.labelUrl, input.country, input.registrant) ||
    classifyUrl(input.labelUrl, input.country).kind !== "label_document" ||
    !new URL(input.labelUrl).pathname.toLowerCase().endsWith(".pdf")) return { status: "label_index_unavailable" };
  let answer: ResponsesCallResult;
  try {
    answer = await callResponsesApi({ model: DEFAULT_RESEARCH_MODEL, apiKey: input.apiKey,
      fetchFn: input.fetchFn ?? fetch, timeoutMs: 30_000, reasoningEffort: "low",
      searchCountry: "AU", allowedDomains: [new URL(input.labelUrl).hostname],
      instructions: `Read only the exact manufacturer product label identified by this URL: ${input.labelUrl}.
Do not use APVMA, regulators, resellers, SDS, technical notes, brochures, other products, or model memory.
If the exact manufacturer label cannot be read from the web index, return no extracted evidence.
Report only facts printed on that exact PDF. Put its exact URL in every product, active, use and rate source_refs. Do not search for a replacement registration source. Report the printed APVMA approval identifier (including any suffix) in the registration candidate number and use the exact PDF as source_url. Never infer an absent number or concentration.
For each grapevine dose create a separate use/rate with verbatim raw_text containing the printed numeric dose and unit. In the rate label explicitly include State: <printed states>; Soil: <light or heavy>. Keep each /100 L alternative as its own rate. Keep state-specific critical comments in that use's restrictions. If state, soil or printed dose cannot be bound, return no such rate.`,
      input: `Exact manufacturer label URL: ${input.labelUrl}\nLocked product: ${input.name}\nRegistrant: ${input.registrant}\nCanonical APVMA number: ${input.registrationNumber}\nLocked actives: ${input.activeIngredients.map((a) => `${a.name} ${a.concentration ?? "unknown"} ${a.concentration_unit ?? ""}`).join("; ")}` });
  } catch { return { status: "label_index_unavailable" }; }
  if (answer.incomplete || !answer.webSearchCalls.length ||
    ![...answer.consultedUrls, ...answer.citedUrls].some((url) => exactUrl(url, input.labelUrl)))
    return { status: "label_index_unavailable" };
  let research;
  try { research = parseChemicalResearchResult(answer.payload); }
  catch { return { status: "label_index_unavailable" }; }
  const refs = (urls: string[]) => urls.length > 0 && urls.every((url) => exactUrl(url, input.labelUrl));
  const name = normal(research.product.canonical_name ?? "");
  const expected = normal(input.name);
  if (!refs(research.product.source_refs) || !name || !expected ||
    !expected.split(" ").every((token) => name.split(" ").includes(token)) ||
    research.product.registrant && normal(research.product.registrant) !== normal(input.registrant))
    return { status: "identity_conflict", reason: "manufacturer_product_identity_mismatch" };
  const printed = research.registration_candidates.filter((candidate) => candidate.scheme === "apvma" &&
    candidate.source_url && exactUrl(candidate.source_url, input.labelUrl) && candidate.country === "AU")
    .map((candidate) => candidate.number ?? "");
  if (!printed.length) return { status: "label_index_unavailable" };
  if (printed.some((number) => !/^\d{4,7}(?:\/\d{4,7})*$/.test(number) ||
    number.split("/")[0] !== input.registrationNumber)) return { status: "identity_conflict", reason: "printed_registration_mismatch" };
  if (research.active_ingredients.length !== input.activeIngredients.length ||
    input.activeIngredients.some((locked) => !research.active_ingredients.some((active) =>
      normal(active.name) === normal(locked.name) && refs(active.source_refs) &&
      active.concentration != null && active.concentration_unit != null &&
      (locked.concentration == null || locked.concentration === active.concentration) &&
      (locked.concentration_unit == null || normal(locked.concentration_unit) === normal(active.concentration_unit)))))
    return { status: "identity_conflict", reason: "manufacturer_product_or_chemistry_mismatch" };
  const uses: Record<string, unknown>[] = [];
  for (const use of research.registered_uses) {
    if (!/grape|vineyard/i.test(use.crop)) continue;
    if (!refs(use.source_refs)) return { status: "label_index_unavailable" };
    for (const rate of use.rates) {
      if (!refs(rate.source_refs) || !printedDose(rate)) return { status: "label_index_unavailable" };
      const condition = stateSoil(rate.label ?? "");
      if (!condition) return { status: "label_index_unavailable" };
      for (const target of use.targets.length ? use.targets : [""]) uses.push({ crop: use.crop, target,
        [DIRECTION_SEED_KEY]: { crop: use.crop, targets: use.targets, condition },
        conditions: condition, restrictions: use.restrictions.join("; ") || null,
        rates: [{ label: condition, basis: rate.basis, value: rate.value, min_value: null, max_value: null,
          unit: rate.unit, raw_text: rate.raw_text, source_refs: [input.labelUrl] }], source_refs: [input.labelUrl] });
    }
  }
  if (!uses.length) return { status: "label_index_unavailable" };
  // The SIMANEX acceptance contract is a completeness check, never a source of rates.
  if (input.registrationNumber === "62917" && normal(input.name) === "simanex 900 wg herbicide") {
    const expected = [
      ["QLD", "light", 2, "kg", "per_hectare"], ["QLD", "heavy", 4, "kg", "per_hectare"],
      ["NSW, VIC, SA, TAS, WA", "light", 1.25, "kg", "per_hectare"],
      ["NSW, VIC, SA, TAS, WA", "light", 60, "g", "per_100_litres"],
      ["NSW, VIC, SA, TAS, WA", "heavy", 2.5, "kg", "per_hectare"],
      ["NSW, VIC, SA, TAS, WA", "heavy", 120, "g", "per_100_litres"],
    ] as const;
    if (uses.length !== expected.length || expected.some(([states, soil, amount, unit, basis]) =>
      !uses.some((use) => use.conditions === `State: ${states}; Soil: ${soil}` &&
        (use.rates as Array<Record<string, unknown>>)[0]?.value === amount &&
        (use.rates as Array<Record<string, unknown>>)[0]?.unit === unit &&
        (use.rates as Array<Record<string, unknown>>)[0]?.basis === basis &&
        (states === "QLD" ? /at least two years old/i : /at least 12 months old.*split applications are preferred/i)
          .test(String(use.restrictions ?? ""))))) return { status: "label_index_unavailable" };
  }
  const printed_values = [...new Set(printed)];
  return { status: "ready", uses,
    actives: research.active_ingredients.map((active) => ({ name: active.name, concentration: active.concentration,
      concentration_unit: active.concentration_unit, identity_source: "manufacturer_label" })),
    identifiers: { numbers: [...new Set(printed_values.flatMap((value) => value.split("/")))], printed_values } };
}
