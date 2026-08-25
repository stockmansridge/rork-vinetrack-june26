import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { parseRateCell } from "./label_extract.ts";
import type { WireLabelRate } from "./contract.ts";

// ===========================================================================
// Task §4/§5 — multi-rate extraction
//
// The defect: a grapevine label reached the app as the unusable string
// "2 L / 100 L 3 L / 100 L 3 L / 100 L…". That was not a parser crash — it was
// `parseRateCell` deliberately failing the WHOLE cell closed the moment two
// different numbers appeared on one basis, emitting a single `basis:"other"`
// entry whose `raw_text` was the entire cell.
//
// The instinct was right (never guess which rate applies). The remedy was
// wrong: it destroyed both readings instead of keeping them.
//
// These fixtures pin the repaired contract. Every one uses label wording of a
// shape that actually appears on AU registrations.
// ===========================================================================

const per100L = (r: WireLabelRate) =>
  r.basis === "per_100_litres" || r.basis === "range_per_100_litres";
const perHa = (r: WireLabelRate) =>
  r.basis === "per_hectare" || r.basis === "range_per_hectare";

// ---------------------------------------------------------------------------
// Single rates
// ---------------------------------------------------------------------------

Deno.test("one /100 L rate is preserved exactly", () => {
  const cell = "200 mL/100 L";
  const rates = parseRateCell(cell);
  assertEquals(rates.length, 1);
  assertEquals(rates[0].basis, "per_100_litres");
  assertEquals(rates[0].value, 200);
  assertEquals(rates[0].unit, "mL");
  assertEquals(rates[0].raw_text, cell);
  assertEquals(rates[0].condition_ambiguous, undefined);
});

Deno.test("one /ha rate is preserved exactly", () => {
  const cell = "1.5 kg/ha";
  const rates = parseRateCell(cell);
  assertEquals(rates.length, 1);
  assertEquals(rates[0].basis, "per_hectare");
  assertEquals(rates[0].value, 1.5);
  assertEquals(rates[0].unit, "kg");
});

// ---------------------------------------------------------------------------
// Multiple rates on ONE basis
// ---------------------------------------------------------------------------

Deno.test("multiple /100 L rates with different conditions stay separate, each owning its condition", () => {
  const cell = "Dilute spraying: 2 L/100 L Concentrate spraying: 3 L/100 L";
  const rates = parseRateCell(cell);

  assertEquals(rates.length, 2, "both conditional rates survive");
  assertEquals(rates.map((r) => r.value), [2, 3]);
  assertEquals(rates.map((r) => r.label), ["Dilute spraying", "Concentrate spraying"]);
  assert(rates.every(per100L), "both remain per-100 L");
  // Conditions are attributable, so nothing is flagged.
  assert(
    rates.every((r) => r.condition_ambiguous === undefined),
    "distinguishable conditions must not be reported as ambiguous",
  );
});

Deno.test("multiple /ha rates with different conditions stay separate", () => {
  const cell = "Low disease pressure: 1 L/ha High disease pressure: 2 L/ha";
  const rates = parseRateCell(cell);
  assertEquals(rates.length, 2);
  assertEquals(rates.map((r) => r.value), [1, 2]);
  assertEquals(rates.map((r) => r.label), ["Low disease pressure", "High disease pressure"]);
  assert(rates.every(perHa));
});

Deno.test("three rates on one basis all survive", () => {
  const cell = "Early: 2 L/100 L Mid: 3 L/100 L Late: 4 L/100 L";
  const rates = parseRateCell(cell);
  assertEquals(rates.length, 3);
  assertEquals(rates.map((r) => r.value), [2, 3, 4]);
});

// ---------------------------------------------------------------------------
// Both bases together — the §4 requirement
// ---------------------------------------------------------------------------

Deno.test("/100 L and /ha coexist on one use, both retained independently", () => {
  const cell = "Dilute spraying: 35 mL/100 L Concentrate spraying: 540 mL/ha";
  const rates = parseRateCell(cell);

  assertEquals(rates.length, 2);
  const volume = rates.filter(per100L);
  const area = rates.filter(perHa);
  assertEquals(volume.length, 1, "the /100 L rate is retained");
  assertEquals(area.length, 1, "the /ha rate is retained");
  assertEquals(volume[0].value, 35);
  assertEquals(area[0].value, 540);
  // Two bases are two ways of stating one instruction, never a conflict.
  assert(
    rates.every((r) => r.condition_ambiguous === undefined),
    "different bases must never be ambiguous with respect to each other",
  );
});

Deno.test("several rates on BOTH bases all survive", () => {
  const cell = "Dilute: 2 L/100 L Concentrate: 3 L/100 L Airblast: 4 L/ha Boom: 5 L/ha";
  const rates = parseRateCell(cell);
  assertEquals(rates.length, 4);
  assertEquals(rates.filter(per100L).map((r) => r.value), [2, 3]);
  assertEquals(rates.filter(perHa).map((r) => r.value), [4, 5]);
});

// ---------------------------------------------------------------------------
// Ranges
// ---------------------------------------------------------------------------

Deno.test("range rates are preserved on both bases", () => {
  const volume = parseRateCell("150 to 200 mL/100 L");
  assertEquals(volume[0].basis, "range_per_100_litres");
  assertEquals(volume[0].min_value, 150);
  assertEquals(volume[0].max_value, 200);
  assertEquals(volume[0].value, undefined, "a range never collapses to a single value");

  const area = parseRateCell("1.0-2.0 L/ha");
  assertEquals(area[0].basis, "range_per_hectare");
  assertEquals(area[0].min_value, 1);
  assertEquals(area[0].max_value, 2);
});

Deno.test("a range and a single rate coexist without either being flattened", () => {
  const cell = "Dilute spraying: 35 or 54 mL/100 L Concentrate spraying: 540 mL/ha";
  const rates = parseRateCell(cell);
  assertEquals(rates.length, 2);
  assertEquals(rates[0].basis, "range_per_100_litres");
  assertEquals(rates[0].min_value, 35);
  assertEquals(rates[0].max_value, 54);
  assertEquals(rates[1].basis, "per_hectare");
  assertEquals(rates[1].value, 540);
});

// ---------------------------------------------------------------------------
// The Hortitrol-style regression
// ---------------------------------------------------------------------------

Deno.test("REGRESSION: a concatenated multi-rate cell never collapses into one unusable entry", () => {
  // The reported shape: several rates run together, no attributable
  // qualifiers. This produced ONE `basis:"other"` row whose raw_text was the
  // whole run — the "2 L / 100 L 3 L / 100 L 3 L / 100 L…" the operator saw.
  const cell = "2 L/100 L 3 L/100 L 4 L/100 L";
  const rates = parseRateCell(cell);

  assert(
    !(rates.length === 1 && rates[0].basis === "other"),
    "the whole cell collapsed into one unusable entry again",
  );
  // Three readings: the repeated 3 L is deduplicated only if truly identical,
  // and these are three distinct numbers.
  assertEquals(rates.map((r) => r.value), [2, 3, 4]);
  assert(rates.every(per100L), "the authoritative basis is preserved on every rate");

  // Nothing distinguishes them, so the ASSOCIATION is declared unproven
  // rather than invented — the conservative half of §5.
  assert(
    rates.every((r) => r.condition_ambiguous === true),
    "unattributable rates must be flagged, not silently ordered",
  );
  // The source wording survives for a human to adjudicate.
  assert(rates.every((r) => r.raw_text === cell));
});

Deno.test("an identical rate printed twice is ONE rate, not two", () => {
  const rates = parseRateCell("3 L/100 L 3 L/100 L");
  assertEquals(rates.length, 1);
  assertEquals(rates[0].value, 3);
  // One reading is unambiguous, so no flag.
  assertEquals(rates[0].condition_ambiguous, undefined);
});

Deno.test("the same number under DIFFERENT conditions is two rates", () => {
  // Deduplication keys on the condition too: collapsing these would delete a
  // distinction the label actually draws.
  const cell = "Dilute spraying: 3 L/100 L Concentrate spraying: 3 L/100 L";
  const rates = parseRateCell(cell);
  assertEquals(rates.length, 2);
  assertEquals(rates.map((r) => r.label), ["Dilute spraying", "Concentrate spraying"]);
});

Deno.test("rates sharing a NON-distinct condition are still flagged", () => {
  // Two rates both labelled the same thing are no more attributable than two
  // labelled nothing.
  const cell = "Grapevines: 2 L/100 L Grapevines: 3 L/100 L";
  const rates = parseRateCell(cell);
  assertEquals(rates.length, 2);
  assert(rates.every((r) => r.condition_ambiguous === true));
});

// ---------------------------------------------------------------------------
// No conversion, ever
// ---------------------------------------------------------------------------

Deno.test("a /100 L-only label yields NO hectare rate", () => {
  // Converting would require a carrier volume the label never states.
  const rates = parseRateCell("200 mL/100 L");
  assertEquals(rates.filter(perHa).length, 0);
});

Deno.test("a /ha-only label yields NO per-100 L rate", () => {
  const rates = parseRateCell("2 L/ha");
  assertEquals(rates.filter(per100L).length, 0);
  assertEquals(rates.length, 1);
});

Deno.test("a column-header basis hint never rewrites a basis the cell states", () => {
  // "540 mL/ha" sitting in a per-100 L column stays per-hectare: the cell is
  // more specific than the heading.
  const rates = parseRateCell("540 mL/ha", "per_100_litres");
  assertEquals(rates[0].basis, "per_hectare");
});

Deno.test("a bare quantity adopts its column's basis and nothing more", () => {
  const volume = parseRateCell("200 g", "per_100_litres");
  assertEquals(volume[0].basis, "per_100_litres");
  assertEquals(volume[0].value, 200);
  assertEquals(volume[0].unit, "g");

  const area = parseRateCell("200 g", "per_hectare");
  assertEquals(area[0].basis, "per_hectare");

  // With no heading to speak for it, a bare quantity is quoted, never guessed.
  assertEquals(parseRateCell("200 g")[0].basis, "other");
});

// ---------------------------------------------------------------------------
// Unchanged guarantees
// ---------------------------------------------------------------------------

Deno.test("unparseable wording is still quoted verbatim, never numericised", () => {
  const rates = parseRateCell("Apply as directed by an agronomist");
  assertEquals(rates, [{
    label: "",
    basis: "other",
    unit: "",
    raw_text: "Apply as directed by an agronomist",
  }]);
});

Deno.test("an empty or dashed cell states no rate at all", () => {
  assertEquals(parseRateCell("   "), []);
  assertEquals(parseRateCell("-"), []);
  assertEquals(parseRateCell("N/A"), []);
});

Deno.test("every rate carries the verbatim source wording", () => {
  const cell = "Dilute spraying: 2 L/100 L Concentrate spraying: 3 L/100 L";
  const rates = parseRateCell(cell);
  assert(
    rates.every((r) => r.raw_text === cell),
    "structured values must never replace the authoritative wording",
  );
});
