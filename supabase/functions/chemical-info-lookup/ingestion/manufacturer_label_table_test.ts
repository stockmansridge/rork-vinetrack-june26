// deno-lint-ignore-file no-import-prefix
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { readManufacturerLabelViaWebIndex } from "./manufacturer_label_index.ts";
import { replayIndexedLabelSnapshot } from "./manufacturer_label_snapshot_replay.ts";
import type { IndexedLabelSnapshot } from "./manufacturer_label_snapshot.ts";
import { cloneResearch, responsesEnvelope } from "../research/test_fixtures.ts";

const pdf = "https://www.adama.com/australia/sites/adama_australia/files/product-documents/2025-01/10150_Adama_Simanex_A4xWebLabel_F_0.pdf";
const locked = { name: "SIMANEX 900 WG HERBICIDE", registrant: "ADAMA AUSTRALIA PTY LIMITED", registrationNumber: "62917",
  activeIngredients: [{ name: "Simazine", concentration: 900, concentration_unit: "g/kg" }], labelUrl: pdf, country: "AU", apiKey: "test" };

// Partial-input regression from the retained 2026-09-28 capture: these six conditions/doses were present,
// but the capture truncated targets at 20 and contains NO table heading or heading-to-cell association.
const retainedDoses = [
  ["Qld", "light", 2, "kg", "2 kg", "Use only if vines are at least two years old."],
  ["Qld", "heavy", 4, "kg", "4 kg", "Use only if vines are at least two years old."],
  ["NSW, Vic, SA, Tas, WA", "light", 1.25, "kg", "1.25 kg", "Use only if vines are at least 12 months old. In first year of use split applications are preferred."],
  ["NSW, Vic, SA, Tas, WA", "light", 60, "g", "60 g/100 L water", "Use only if vines are at least 12 months old. In first year of use split applications are preferred."],
  ["NSW, Vic, SA, Tas, WA", "heavy", 2.5, "kg", "2.5 kg", "Use only if vines are at least 12 months old. In first year of use split applications are preferred."],
  ["NSW, Vic, SA, Tas, WA", "heavy", 120, "g", "120 g/100 L water", "Use only if vines are at least 12 months old. In first year of use split applications are preferred."],
] as const;

// Separate manufacturer-document fixture: page 1's RATE/ha heading and its applicable crop/state/soil
// table association are ADDED evidence, not fields claimed to have existed in the retained snapshot.
function manufacturerTableFixture(targets: string[] = ["Amaranthus", "Suppression: Wireweed"]) {
  const research = cloneResearch();
  research.product = { ...research.product, canonical_name: "SIMANEX® 900 WG Herbicide", registrant: locked.registrant, source_refs: [pdf] };
  research.registration_candidates = [{ ...research.registration_candidates[0], scheme: "apvma", number: "62917/107619", country: "AU", source_url: pdf }];
  research.active_ingredients = [{ ...research.active_ingredients[0], name: "Simazine", concentration: 900, concentration_unit: "g/kg", source_refs: [pdf] }];
  research.registered_uses = retainedDoses.map(([state, soil, value, unit, cell, restriction]) => ({
    crop: "Grapevines", targets: [...targets], whp: null, rei: null, restrictions: [restriction], source_refs: [pdf],
    rates: [{ label: `State: ${state} only; Soil: ${soil} soil`, basis: cell.includes("/100 L") ? "per_100_litres" : "per_hectare",
      value, unit, min_value: null, max_value: null, raw_text: `State: ${state} only; Soil: ${soil} soil; ${cell}`,
      table_heading: "RATE/ha", table_context: `Crop: Grapevines; State: ${state} only; Soil: ${soil} soil`, source_refs: [pdf] }],
  }));
  return research;
}

type Fixture = ReturnType<typeof manufacturerTableFixture>;
function read(research: Fixture, capture?: (snapshot: IndexedLabelSnapshot) => void) {
  const envelope = responsesEnvelope(research, { sources: [pdf] });
  return readManufacturerLabelViaWebIndex({ ...locked, onDiagnosticSnapshot: capture,
    fetchFn: (() => Promise.resolve(new Response(JSON.stringify(envelope)))) as typeof fetch });
}

Deno.test("retained partial input is not a faithful replay and cannot infer missing heading or targets", async () => {
  // Only fields actually retained in the attachment; not a reconstructed full provider response.
  const captured = { version: 2, validator_version: 1, complete: false,
    validation: { status: "label_index_unavailable", reason: "rate_raw_text_mismatch" },
    extracted: { uses: retainedDoses.map(([state, soil, value, unit, cell]) => ({
      targets: [], rates: [{ value, unit,
        raw_text: `State: ${state} only; Soil: ${soil} soil; ${cell}` }] })) } } as unknown as IndexedLabelSnapshot;
  assertEquals(captured.complete, false);
  assertEquals(captured.validation?.reason, "rate_raw_text_mismatch");
  assertEquals(captured.extracted?.uses.length, 6);
  assertEquals(captured.extracted?.uses[0].rates[0].raw_text, "State: Qld only; Soil: light soil; 2 kg");
  assertEquals(captured.extracted?.uses[0].rates[0].table_heading, undefined);
  await assertRejects(async () => { await replayIndexedLabelSnapshot(captured); });
});

Deno.test("manufacturer table fixture binds bare numeric cells to RATE/ha, preserving /100 L and raw wording", async () => {
  const research = manufacturerTableFixture();
  const outcome = await read(research);
  assertEquals(outcome.status, "ready");
  if (outcome.status !== "ready") return;
  assertEquals(outcome.uses.length, 12);
  const first = (outcome.uses[0].rates as Array<Record<string, unknown>>)[0];
  assertEquals(first.raw_text, research.registered_uses[0].rates[0].raw_text);
  assertEquals(first.basis, "per_hectare");
  assertEquals((outcome.uses[6].rates as Array<Record<string, unknown>>)[0].basis, "per_100_litres");
  assertEquals(outcome.uses[1].target, "Suppression: Wireweed");
});

Deno.test("absent, unrelated, conflicting heading/row, different cell dose or units fail closed", async () => {
  const variants: Array<(data: Fixture) => void> = [
    (r) => { r.registered_uses[0].rates[0].table_heading = null; },
    (r) => { r.registered_uses[0].rates[0].table_heading = "RATE per 100 m"; },
    (r) => { r.registered_uses[0].rates[0].table_context = "Crop: Apples; State: Qld; Soil: light"; },
    (r) => { r.registered_uses[0].rates[0].table_context = "Crop: Grapevines; State: NSW; Soil: light"; },
    (r) => { r.registered_uses[0].rates[0].table_context = "Crop: Grapevines; State: Qld; Soil: heavy"; },
    (r) => { r.registered_uses[0].rates[0].raw_text = "State: Qld; Soil: light; 3 kg"; },
    (r) => { r.registered_uses[0].rates[0].raw_text = "State: Qld; Soil: light; 2 g"; },
    (r) => { r.registered_uses[0].rates[0].raw_text = "State: Qld; Soil: light; 2 kg/100 L"; },
    (r) => { r.registered_uses[0].rates[0].raw_text = "State: Qld; Soil: light; 2 kg/acre"; },
    (r) => { r.registered_uses[3].rates[0].basis = "per_hectare"; },
    (r) => { r.registered_uses[0].rates[0].raw_text += " and 4 kg"; },
  ];
  for (const change of variants) {
    const research = manufacturerTableFixture(); change(research);
    assertEquals(await read(research), { status: "label_index_unavailable", reason: "rate_raw_text_mismatch" });
  }
});

Deno.test("six distinct condition-bearing doses expand to >120 target rows; diagnostics retain bounded lists", async () => {
  const targets = Array.from({ length: 26 }, (_, i) => i === 25 ? "Suppression: Annual Ryegrass" : `Controlled weed ${i}`);
  let snapshot: IndexedLabelSnapshot | null = null;
  const result = await read(manufacturerTableFixture(targets), (value) => { snapshot = value; });
  assertEquals(result.status, "ready");
  if (result.status !== "ready" || !snapshot) return;
  const captured: IndexedLabelSnapshot = snapshot;
  assertEquals(result.uses.length, 156);
  assertEquals(new Set(result.uses.map((use) => use.target)).size, 26);
  assertEquals(captured.complete, true);
  assertEquals(captured.truncations, []);
  assertEquals(captured.extracted?.uses.map((use) => use.targets.length), Array(6).fill(26));
  assertEquals(await replayIndexedLabelSnapshot(captured).then((value) => value.status), "ready");
  const excess = Array.from({ length: 81 }, (_, i) => `Target ${i}`);
  let truncated: IndexedLabelSnapshot | null = null;
  await read(manufacturerTableFixture(excess), (value) => { truncated = value; });
  if (!truncated) throw Error("missing snapshot");
  const bounded: IndexedLabelSnapshot = truncated;
  assertEquals(bounded.complete, false);
  assertEquals(bounded.truncations?.[0], { path: "extracted.uses[0].targets", original: 81, retained: 80 });
  await assertRejects(async () => { await replayIndexedLabelSnapshot(bounded); });
  assert(JSON.stringify(bounded).length < 150_000);
});

Deno.test("conflicting duplicate dose never passes six-dose completeness", async () => {
  const research = manufacturerTableFixture();
  research.registered_uses[5] = structuredClone(research.registered_uses[0]);
  assertEquals(await read(research), { status: "label_index_unavailable", reason: "simanex_completeness_failed" });
});
