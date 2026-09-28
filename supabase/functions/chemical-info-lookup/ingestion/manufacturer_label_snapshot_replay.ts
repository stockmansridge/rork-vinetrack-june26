import type { ChemicalResearchResult, ResearchRateBasis } from "../research/schema.ts";
import { readManufacturerLabelViaWebIndex } from "./manufacturer_label_index.ts";
import type { IndexedLabelSnapshot } from "./manufacturer_label_snapshot.ts";

/** Offline diagnostic replay only: never promotes snapshot data to evidence or writes a preview. */
export function replayIndexedLabelSnapshot(snapshot: IndexedLabelSnapshot) {
  if (snapshot.version !== 2 || snapshot.validator_version !== 2 || !snapshot.validation ||
    !snapshot.complete || !snapshot.extracted || !snapshot.locked.document || !snapshot.locked.name ||
    !snapshot.locked.registrant || !snapshot.locked.registration || snapshot.tool.sources.length === 0) {
    throw new Error("Snapshot is incomplete; cannot replay faithfully");
  }
  const strings = (refs: Array<string | null>): string[] => refs.filter((ref): ref is string => ref !== null);
  const data = snapshot.extracted;
  const research: ChemicalResearchResult = {
    product: { searched_name: "offline diagnostic replay", canonical_name: data.product.name, registrant: data.product.registrant,
      manufacturer: null, category: null, form_type: null, country: "AU", source_refs: strings(data.product.refs) },
    registration_candidates: data.registration.map((entry) => ({ scheme: entry.scheme, number: entry.number,
      registered_product_name: null, country: entry.country ?? "", source_url: entry.source,
      source_domain: null, confidence: "high", reason: "" })),
    active_ingredients: data.actives.map((active) => ({ name: active.name ?? "", concentration: active.concentration,
      concentration_unit: active.unit, suggested_scheme: null, suggested_group: null, source_refs: strings(active.refs) })),
    registered_uses: data.uses.map((use) => ({ crop: use.crop ?? "", targets: strings(use.targets),
      restrictions: strings(use.restrictions), whp: null, rei: null, source_refs: strings(use.refs),
      rates: use.rates.map((rate) => ({ label: rate.condition, basis: rate.basis as ResearchRateBasis,
        value: rate.value, min_value: rate.min_value, max_value: rate.max_value,
        unit: rate.unit, raw_text: rate.raw_text, table_heading: rate.table_heading ?? null,
        table_context: rate.table_context ?? null, source_refs: strings(rate.refs) })) })),
    documents: { official_label_candidates: [], product_page_candidates: [], sds_candidates: [] },
    sources: [], unresolved: [], notes: null,
  };
  const envelope = { status: snapshot.tool.incomplete ? "incomplete" : "completed", output: [
    ...snapshot.tool.sources.map((call) => ({ type: "web_search_call", action: {
      type: call.action, sources: strings(call.refs).map((url) => ({ url })) } })),
    { type: "message", content: [{ type: "output_text", text: JSON.stringify(research),
      annotations: strings(snapshot.tool.citations).map((url) => ({ url })) }] },
  ] };
  const fetchFn = (() => Promise.resolve(new Response(JSON.stringify(envelope), { status: 200 }))) as typeof fetch;
  return readManufacturerLabelViaWebIndex({ name: snapshot.locked.name, registrant: snapshot.locked.registrant,
    registrationNumber: snapshot.locked.registration, labelUrl: snapshot.locked.document,
    activeIngredients: snapshot.locked.actives.map((active) => ({ name: active.name ?? "",
      concentration: active.concentration, concentration_unit: active.unit })), country: "AU",
    apiKey: "offline-replay", fetchFn });
}
