// deno-lint-ignore-file no-import-prefix
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { containRowFailure, pendingIds, selectBackfillRows } from "./master-chemical-backfill-v2.ts";
import type { MasterRow } from "../supabase/functions/chemical-info-lookup/ingestion/contract.ts";

Deno.test("canary selection is stable by id and only incomplete by default", () => {
  const row = (id: string, state: "unresolved" | "classified") => ({
    id, registration_country: "AU", registration_scheme: "apvma", registration_number: "90143",
    registration_identity_key: "AU:apvma:90143", registered_product_name: id, product_category: "herbicide",
    active_ingredients: [{ name: "Glufosinate-ammonium", concentration: 200, concentration_unit: "g/L", activity_group: { scheme: "hrac", code: "10" } }],
    activity_groups: ["10"], resistance_classification_state: state, registered_uses: [],
    viticulture_rates: { per_hectare: [], per_100_litres: [] },
    verification_sources: [{ kind: "manufacturer_label", name: "Label", reference: "https://cropsure.com/wp-content/uploads/2023/03/cropsure-beast-200-herbicide-label-v2.pdf" }],
    verification_unresolved_fields: [],
  }) as unknown as MasterRow;
  assertEquals(selectBackfillRows([row("z", "unresolved"), row("a", "classified"), row("b", "unresolved")], null, 1).map((r) => r.id), ["b"]);
  assertEquals(selectBackfillRows([row("z", "unresolved")], "z", 1).map((r) => r.id), ["z"]);
});

Deno.test("one failing lookup is contained and the next row still runs", async () => {
  let visited = 0;
  const first = await containRowFailure(() => { visited++; return Promise.reject(new Error("timeout")); });
  const second = await containRowFailure(() => { visited++; return Promise.resolve("preview_ready"); });
  assertEquals(first.error, true);
  assertEquals(second.value, "preview_ready");
  assertEquals(visited, 2);
});

Deno.test("resume skips successes and failures; retry-failed targets only failures", () => {
  const checkpoint = { ids: ["a", "b", "c", "d"], completed: { a: "updated" }, failed: { c: "lookup_unavailable" } };
  assertEquals(pendingIds(checkpoint, false), ["b", "d"]);
  assertEquals(pendingIds(checkpoint, true), ["c"]);
});
