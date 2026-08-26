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
