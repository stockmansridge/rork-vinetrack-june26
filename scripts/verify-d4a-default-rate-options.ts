// D4A production smoke gate — canonical `default_rate_options` served live.
//
// ONE structured lookup against production, then every assertion the gate
// asks for, evaluated mechanically so the result is a verdict rather than a
// paragraph to read.
//
// READ-ONLY. `action: "structured"` is a lookup. This script performs no
// saved-chemical write, no `default_rates` write, and no Master Catalogue
// mutation — it sends one POST and inspects the response body.
//
// Usage (from the project root, on the deployed commit):
//
//   LOOKUP_JWT=<app anon key> \
//   deno run --allow-net --allow-env scripts/verify-d4a-default-rate-options.ts
//
// Optional overrides:
//   LOOKUP_ENDPOINT   full function URL
//   LOOKUP_COUNTRY    default "AU"
//
// Exit code 0 = every assertion passed. Exit code 1 = at least one failed,
// which under the gate means STOP and do not begin D4B.

const ENDPOINT = Deno.env.get("LOOKUP_ENDPOINT") ??
  "https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/chemical-info-lookup";
const COUNTRY = Deno.env.get("LOOKUP_COUNTRY") ?? "AU";

const REGISTRATION = "33182";
const PRODUCT = "VICOL WINTER OIL INSECTICIDE";

// deno-lint-ignore no-explicit-any
type Json = any;

let failures = 0;
let checks = 0;

function check(label: string, ok: boolean, detail?: unknown): void {
  checks++;
  if (!ok) failures++;
  const mark = ok ? "PASS" : "FAIL";
  const suffix = detail === undefined ? "" : `  → ${JSON.stringify(detail)}`;
  console.log(`  [${mark}] ${label}${suffix}`);
}

function eq(label: string, actual: unknown, expected: unknown): void {
  check(
    label,
    JSON.stringify(actual) === JSON.stringify(expected),
    { actual, expected },
  );
}

function heading(text: string): void {
  console.log(`\n${text}\n${"-".repeat(text.length)}`);
}

/** Unique, sorted, non-empty strings. */
function uniq(values: unknown): string[] {
  if (!Array.isArray(values)) return [];
  return [...new Set(values.map((v) => String(v)).filter((v) => v.length))]
    .sort();
}

// ---------------------------------------------------------------------------
// Semantic normalisation for the D4A.3 printed-direction assertions
// ---------------------------------------------------------------------------
//
// The gate asks whether the SEMANTIC direction is served, not whether a string
// matches byte for byte. Comma spacing, state order and singular/plural pest
// wording are presentation, and pinning them would turn a cosmetic label
// reissue into a failed production gate. What must not drift is the meaning:
// which jurisdictions, which number, which basis, which pests.

const STATE_ABBREVIATIONS = new Set([
  "nsw",
  "vic",
  "qld",
  "sa",
  "wa",
  "tas",
  "nt",
  "act",
]);

/** Long forms folded to the abbreviation the label actually prints. */
const STATE_PHRASES: [RegExp, string][] = [
  [/new south wales/g, "nsw"],
  [/south australia/g, "sa"],
  [/western australia/g, "wa"],
  [/northern territory/g, "nt"],
  [/australian capital territory/g, "act"],
  [/tasmania/g, "tas"],
  [/victoria/g, "vic"],
  [/queensland/g, "qld"],
];

/**
 * The set of jurisdictions a condition names, sorted so "NSW, Vic, SA" and
 * "SA, NSW, Vic" are the same condition — because they are.
 */
function stateSet(text: unknown): string[] {
  let s = String(text ?? "").toLowerCase();
  for (const [phrase, abbr] of STATE_PHRASES) s = s.replace(phrase, abbr);
  const tokens = s.split(/[^a-z]+/).filter((t) => STATE_ABBREVIATIONS.has(t));
  return [...new Set(tokens)].sort();
}

/**
 * Pest wording reduced to its meaning: case, punctuation and trailing plurals
 * removed, so "European Red Mites" and "European red mite" agree.
 */
function normaliseTarget(text: unknown): string {
  return String(text ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .split(" ")
    .filter((w) => w.length > 0)
    .map((w) => (w.length > 3 && w.endsWith("s") ? w.slice(0, -1) : w))
    .join(" ");
}

/** Does any listed condition mention every one of these tokens? */
function conditionMentions(option: Json, tokens: string[]): boolean {
  const haystack = [
    ...(Array.isArray(option?.conditions) ? option.conditions : []),
    ...(Array.isArray(option?.targets) ? option.targets : []),
  ].join(" | ").toLowerCase();
  return tokens.every((t) => haystack.includes(t.toLowerCase()));
}

async function main(): Promise<void> {
  const jwt = Deno.env.get("LOOKUP_JWT") ?? "";
  if (!jwt) {
    console.error(
      "LOOKUP_JWT is required (the app anon key works). Nothing was sent.",
    );
    Deno.exit(2);
  }

  console.log("D4A production smoke gate — canonical default_rate_options");
  console.log(`endpoint:     ${ENDPOINT}`);
  console.log(`country:      ${COUNTRY}`);
  console.log(`registration: ${REGISTRATION}`);
  console.log(`product:      ${PRODUCT}`);
  console.log("mode:         READ-ONLY (one structured lookup, no writes)");

  const started = Date.now();
  const res = await fetch(ENDPOINT, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${jwt}`,
      "apikey": jwt,
    },
    // The registration is sent so the identity lock pins the answer to the
    // registration under test rather than to the typed phrase.
    body: JSON.stringify({
      action: "structured",
      productName: PRODUCT,
      registrationNumber: REGISTRATION,
      country: COUNTRY,
      client: {
        platform: "portal",
        app_version: "d4a-smoke",
        app_build: "0",
        correlation_id: `d4a-smoke-${Date.now()}`,
      },
    }),
  });

  const body: Json = await res.json().catch(() => null);
  const elapsed = Date.now() - started;

  console.log(`\nHTTP ${res.status} in ${elapsed} ms`);
  console.log("\n--- FULL RESPONSE ---");
  console.log(JSON.stringify(body, null, 2));

  if (!body || typeof body !== "object") {
    console.error("\nNo JSON body — nothing can be asserted.");
    Deno.exit(1);
  }

  // -- §1/§7 deployed build + which path served it ------------------------
  heading("Deployed build and serving path (§1, §7)");
  const diag: Json = body.diagnostics ?? {};
  const sha = diag?.server?.lookup_version ?? null;
  console.log(`  lookup_version: ${JSON.stringify(sha)}`);
  console.log(`  project_ref:    ${JSON.stringify(diag?.server?.project_ref)}`);
  console.log(`  lookup_method:  ${JSON.stringify(diag?.lookup_method)}`);
  console.log(`  cache:          ${JSON.stringify(diag?.cache)}`);
  check(
    "LOOKUP_GIT_SHA is set (not the literal \"unknown\")",
    typeof sha === "string" && sha.length > 0 && sha !== "unknown",
    sha,
  );

  // -- §4 registration identity served -----------------------------------
  heading("Registration identity served (§4)");
  eq(
    "registration_number",
    body.registration?.registration_number ?? null,
    REGISTRATION,
  );
  check(
    "scheme is APVMA",
    String(body.registration?.scheme ?? "").toLowerCase() === "apvma",
    body.registration?.scheme ?? null,
  );

  // -- §3 identity assertions --------------------------------------------
  heading("Identity assertions (§3)");
  const uses: Json[] = Array.isArray(body.registered_uses)
    ? body.registered_uses
    : [];
  const grapevineUses = uses.filter((u) =>
    String(u?.crop ?? "").toLowerCase().includes("grape") ||
    String(u?.crop ?? "").toLowerCase().includes("vine")
  );
  const directionIds = uniq(grapevineUses.map((u) => u?.direction_id));
  const rateIds = uniq(
    grapevineUses.flatMap((u) =>
      (Array.isArray(u?.rates) ? u.rates : []).map((r: Json) => r?.rate_id)
    ),
  );

  eq("projected grapevine target rows", grapevineUses.length, 6);
  eq("unique direction_id values", directionIds.length, 4);
  eq("unique rate_id values", rateIds.length, 4);
  check(
    "every direction_id is a stable direction_v1_ identity",
    directionIds.every((id) => id.startsWith("direction_v1_")),
    directionIds,
  );
  check(
    "every rate_id is a stable rate_v1_ identity",
    rateIds.every((id) => id.startsWith("rate_v1_")),
    rateIds,
  );

  // -- D4A.3 §1 the four semantic printed directions ----------------------
  //
  // Counting ids proves the fan-out collapsed correctly; it does not prove the
  // right four directions were recovered. Four wrong directions would satisfy
  // every count above. So each printed direction is identified by its MEANING
  // — jurisdictions, number, basis, pests — and the served set must be exactly
  // these four with nothing left over.
  heading("The four semantic printed directions (D4A.3 §1)");

  interface ServedDirection {
    direction_id: string;
    states: string[];
    values: number[];
    bases: string[];
    targets: string[];
    rateIds: string[];
    rows: number;
  }

  const byDirection = new Map<string, Json[]>();
  for (const use of grapevineUses) {
    const id = String(use?.direction_id ?? "");
    const bucket = byDirection.get(id);
    if (bucket) bucket.push(use);
    else byDirection.set(id, [use]);
  }

  const served: ServedDirection[] = [...byDirection.entries()].map(
    ([direction_id, rows]) => {
      const rates: Json[] = rows.flatMap((r) =>
        Array.isArray(r?.rates) ? r.rates : []
      );
      return {
        direction_id,
        // The state condition travels as the rate's own `label` — the label
        // prints the state column as what it calls the rate.
        states: [
          ...new Set(rates.flatMap((r) => stateSet(r?.label))),
        ].sort(),
        values: [
          ...new Set(
            rates
              .map((r) => Number(r?.value))
              .filter((v) => Number.isFinite(v)),
          ),
        ].sort((x, y) => x - y),
        bases: uniq(rates.map((r) => r?.basis)),
        targets: [
          ...new Set(
            rows
              .map((r) => normaliseTarget(r?.target_raw ?? r?.target))
              .filter((t) => t.length > 0),
          ),
        ].sort(),
        rateIds: uniq(rates.map((r) => r?.rate_id)),
        rows: rows.length,
      };
    },
  );

  console.log(`  served directions: ${JSON.stringify(served, null, 2)}`);

  interface ExpectedDirection {
    name: string;
    states: string[];
    value: number;
    targets: string[];
    rows: number;
  }

  // Sorted exactly as the normalisers above produce them.
  const EXPECTED: ExpectedDirection[] = [
    {
      name: "A — Tas, 2 L/100 L, three mites",
      states: ["tas"],
      value: 2,
      targets: [
        "european red mite",
        "grapeleaf blister mite",
        "two spotted mite",
      ],
      rows: 3,
    },
    {
      name: "B — NSW, Vic, SA, 3 L/100 L, European Red Mites",
      states: ["nsw", "sa", "vic"],
      value: 3,
      targets: ["european red mite"],
      rows: 1,
    },
    {
      name: "C — NSW, Vic, Qld, SA, WA, 3 L/100 L, Grapevine Scale",
      states: ["nsw", "qld", "sa", "vic", "wa"],
      value: 3,
      targets: ["grapevine scale"],
      rows: 1,
    },
    {
      name: "D — Tas, 2 L/100 L, Grapevine Scale",
      states: ["tas"],
      value: 2,
      targets: ["grapevine scale"],
      rows: 1,
    },
  ];

  eq("grapevine direction groups", served.length, 4);

  const matched = new Set<string>();
  for (const want of EXPECTED) {
    // A and D are both "Tas, 2 L/100 L" and are distinguished ONLY by their
    // pests, so the whole tuple identifies the direction.
    const hits = served.filter((s) =>
      JSON.stringify(s.states) === JSON.stringify(want.states) &&
      JSON.stringify(s.values) === JSON.stringify([want.value]) &&
      JSON.stringify(s.bases) === JSON.stringify(["per_100_litres"]) &&
      JSON.stringify(s.targets) === JSON.stringify(want.targets)
    );
    check(
      `direction ${want.name} is served exactly once`,
      hits.length === 1,
      {
        matches: hits.length,
        expected: {
          states: want.states,
          value: want.value,
          basis: "per_100_litres",
          targets: want.targets,
        },
      },
    );
    const hit = hits[0];
    if (!hit) continue;
    matched.add(hit.direction_id);
    eq(`${want.name} — projected target rows`, hit.rows, want.rows);
    eq(`${want.name} — one printed rate identity`, hit.rateIds.length, 1);
  }

  eq(
    "every served direction is one of the four expected",
    served.filter((s) => !matched.has(s.direction_id)).map((s) => ({
      direction_id: s.direction_id,
      states: s.states,
      values: s.values,
      targets: s.targets,
    })),
    [],
  );
  eq("the four directions are distinct identities", matched.size, 4);

  // -- D4A.3 §3 no verbatim-only grapevine rate --------------------------
  heading("No verbatim-only grapevine rate (D4A.3 §3)");
  const grapevineRates: Json[] = grapevineUses.flatMap((u) =>
    Array.isArray(u?.rates) ? u.rates : []
  );
  check(
    "every grapevine row states at least one rate",
    grapevineUses.every((u) => (Array.isArray(u?.rates) ? u.rates : []).length > 0),
    grapevineUses.map((u) => (Array.isArray(u?.rates) ? u.rates.length : 0)),
  );
  eq(
    "no served grapevine rate has basis \"other\"",
    grapevineRates
      .filter((r) => String(r?.basis) === "other")
      .map((r) => ({ basis: r?.basis, raw_text: r?.raw_text })),
    [],
  );
  eq(
    "every served grapevine rate is per_100_litres in L",
    uniq(grapevineRates.map((r) => `${r?.basis}|${r?.unit}`)),
    ["per_100_litres|L"],
  );

  // -- D4A.3 §5 audit trail, once per PRINTED rate ------------------------
  //
  // Deduplicated by rate_id on purpose: direction A fans out to three target
  // rows that share ONE printed rate, and checking per row would report that
  // single rate three times and quietly inflate a pass.
  heading("Glyph-repair audit trail per unique rate_id (D4A.3 §5)");
  const ratesById = new Map<string, Json>();
  const occurrences = new Map<string, number>();
  for (const rate of grapevineRates) {
    const id = String(rate?.rate_id ?? "");
    if (!id) continue;
    if (!ratesById.has(id)) ratesById.set(id, rate);
    occurrences.set(id, (occurrences.get(id) ?? 0) + 1);
  }

  eq("unique printed grapevine rates", ratesById.size, 4);
  eq(
    "the fan-out is 3+1+1+1 rows across those four printed rates",
    [...occurrences.values()].sort((x, y) => x - y),
    [1, 1, 1, 3],
  );

  for (const [id, rate] of ratesById) {
    const rawText = String(rate?.raw_text ?? "");
    const textLayer = rate?.text_layer_text;
    const label = `rate ${id}`;
    check(
      `${label} — raw_text is the repaired human-readable reading`,
      /\/\s*100\s*L/.test(rawText) && !/1OO/.test(rawText),
      { raw_text: rawText },
    );
    check(
      `${label} — text_layer_text preserves the original extracted 1OO`,
      typeof textLayer === "string" && textLayer.includes("1OO"),
      { text_layer_text: textLayer ?? null },
    );
    check(
      `${label} — the two readings differ only in the repaired glyphs`,
      typeof textLayer === "string" &&
        textLayer === rawText.replace(/100/g, "1OO"),
      { raw_text: rawText, text_layer_text: textLayer ?? null },
    );
  }

  // -- §4 default_rate_options -------------------------------------------
  heading("default_rate_options assertions (§4)");
  const opts: Json = body.default_rate_options;
  check("default_rate_options is present", !!opts && typeof opts === "object");
  if (!opts || typeof opts !== "object") {
    console.error("\nContract absent — remaining assertions cannot run.");
    Deno.exit(1);
  }

  const perHa: Json[] = Array.isArray(opts.per_hectare) ? opts.per_hectare : [];
  const per100: Json[] = Array.isArray(opts.per_100_litres)
    ? opts.per_100_litres
    : [];

  eq("per_hectare is empty (no /ha option)", perHa.length, 0);
  eq("per_100_litres option count", per100.length, 2);

  const byValue = (v: number): Json | undefined =>
    per100.find((o) => Number(o?.value) === v);

  // Option A — 2 L/100 L, Tasmania directions.
  const a = byValue(2);
  check("Option A (value 2) present", !!a);
  if (a) {
    eq("A unit", a.unit, "L");
    eq("A basis", a.basis, "per_100_litres");
    eq("A unique rate_ids", uniq(a.rate_ids).length, 2);
    eq("A unique direction_ids", uniq(a.direction_ids).length, 2);
    check(
      "A cites the Tasmania multi-mite direction",
      conditionMentions(a, ["tas"]) &&
        (conditionMentions(a, ["mite"]) || conditionMentions(a, ["mites"])),
      { conditions: a.conditions, targets: a.targets },
    );
    check(
      "A cites the Tasmania Grapevine Scale direction",
      conditionMentions(a, ["tas"]) && conditionMentions(a, ["scale"]),
      { conditions: a.conditions, targets: a.targets },
    );
  }

  // Option B — 3 L/100 L, mainland directions.
  const b = byValue(3);
  check("Option B (value 3) present", !!b);
  if (b) {
    eq("B unit", b.unit, "L");
    eq("B basis", b.basis, "per_100_litres");
    eq("B unique rate_ids", uniq(b.rate_ids).length, 2);
    eq("B unique direction_ids", uniq(b.direction_ids).length, 2);
    check(
      "B cites European Red Mites — NSW, Vic, SA",
      conditionMentions(b, ["european red"]) ||
        (conditionMentions(b, ["nsw"]) && conditionMentions(b, ["mite"])),
      { conditions: b.conditions, targets: b.targets },
    );
    check(
      "B cites Grapevine Scale — NSW, Vic, Qld, SA, WA",
      conditionMentions(b, ["scale"]) &&
        (conditionMentions(b, ["qld"]) || conditionMentions(b, ["wa"])),
      { conditions: b.conditions, targets: b.targets },
    );
  }

  // No duplicates, no six-row explosion.
  eq("exactly one 2 L option", per100.filter((o) => Number(o?.value) === 2).length, 1);
  eq("exactly one 3 L option", per100.filter((o) => Number(o?.value) === 3).length, 1);
  check(
    "options are grouped, not one per target row",
    per100.length === 2 && grapevineUses.length === 6,
    { options: per100.length, projected_rows: grapevineUses.length },
  );

  const allOptionRateIds = uniq([
    ...per100.flatMap((o) => (Array.isArray(o?.rate_ids) ? o.rate_ids : [])),
    ...perHa.flatMap((o) => (Array.isArray(o?.rate_ids) ? o.rate_ids : [])),
  ]);
  eq("unique rate_ids across both options", allOptionRateIds.length, 4);
  check(
    "option rate_ids all appear in the served projection",
    allOptionRateIds.every((id) => rateIds.includes(id)),
    { option_rate_ids: allOptionRateIds, projection_rate_ids: rateIds },
  );

  // -- §5 grapevine-only -------------------------------------------------
  heading("Grapevine-only assertion (§5)");
  for (const [name, option] of [["A", a], ["B", b]] as const) {
    if (!option) continue;
    const crops = uniq(option.crops);
    check(
      `${name} crops are grapevine evidence only`,
      crops.length > 0 &&
        crops.every((c) =>
          c.toLowerCase().includes("grape") || c.toLowerCase().includes("vine")
        ),
      crops,
    );
  }
  const otherCropRateIds = uses
    .filter((u) => !grapevineUses.includes(u))
    .flatMap((u) =>
      (Array.isArray(u?.rates) ? u.rates : []).map((r: Json) => r?.rate_id)
    )
    .filter((id) => typeof id === "string");
  check(
    "no other-crop rate_id appears in any option",
    !allOptionRateIds.some((id) => otherCropRateIds.includes(id)),
    { other_crop_rate_ids: uniq(otherCropRateIds) },
  );

  // -- §6 option keys ----------------------------------------------------
  heading("Option key assertion (§6)");
  const keys = per100.map((o) => String(o?.option_key ?? ""));
  check("both options carry an option_key", keys.every((k) => k.length > 0), keys);
  check(
    "every option_key uses the default_option_v1_ prefix",
    keys.every((k) => k.startsWith("default_option_v1_")),
    keys,
  );
  eq("option keys are distinct", new Set(keys).size, keys.length);
  for (const [name, option] of [["A", a], ["B", b]] as const) {
    if (!option) continue;
    const ids: string[] = Array.isArray(option.rate_ids) ? option.rate_ids : [];
    check(
      `${name} rate_ids are deduplicated and sorted (deterministic)`,
      JSON.stringify(ids) === JSON.stringify(uniq(ids)),
      ids,
    );
  }

  // -- §8 diagnostics ----------------------------------------------------
  heading("Diagnostics (§8)");
  const degraded: string[] = Array.isArray(diag?.degraded) ? diag.degraded : [];
  console.log(`  degraded: ${JSON.stringify(degraded)}`);
  const identityRelated = degraded.filter((d) =>
    d.includes("default_rate_option") ||
    d.includes("rate_id") ||
    d.includes("identity")
  );
  eq("no default-rate identity/option degradation", identityRelated, []);
  check(
    "verification carries no default-option unresolved marker",
    !(Array.isArray(body.verification?.unresolved_fields)
      ? body.verification.unresolved_fields
      : []).some((f: unknown) =>
        String(f).includes("default_rate") || String(f).includes("rate_id")
      ),
    body.verification?.unresolved_fields ?? null,
  );

  // -- D4A.3 §4 grapevine rates are no longer an unresolved field ---------
  //
  // The live defect declared grapevine rates unresolved because nothing
  // calculable could be read. Recovery is only real if that marker is gone —
  // both bare and in any qualified `rates:GRAPEVINE:<target>` form.
  const unresolvedFields: string[] =
    (Array.isArray(body.verification?.unresolved_fields)
      ? body.verification.unresolved_fields
      : []).map((f: unknown) => String(f));
  console.log(`  unresolved_fields: ${JSON.stringify(unresolvedFields)}`);
  eq(
    "unresolved_fields contains no rates:GRAPEVINE marker (bare or qualified)",
    unresolvedFields.filter((f) => {
      const norm = f.trim().toLowerCase();
      return norm === "rates:grapevine" || norm.startsWith("rates:grapevine:");
    }),
    [],
  );

  // -- verdict -----------------------------------------------------------
  heading("Verdict");
  console.log(`  ${checks - failures}/${checks} assertions passed`);
  if (failures) {
    console.log("  GATE FAILED — do not begin D4B.");
  } else {
    console.log("  GATE PASSED — canonical default_rate_options served live.");
  }
  console.log("  No production data was written by this script.");
  Deno.exit(failures ? 1 : 0);
}

if (import.meta.main) {
  await main();
}
