// Production verification — chemical-info-lookup structured resolver.
//
// Runs AFTER the resolver upgrade is deployed (post Stage 5H closure).
// READ-ONLY against production: action=structured performs no catalogue
// writes except the candidate enqueue the pipeline itself is contracted to
// do for register-verified identities (existing rows always win; no schema
// changes, no Saved Chemicals / Spray Records writes).
//
// Usage (from the project root):
//   LOOKUP_JWT=<any valid JWT — the app anon key works> \
//   deno run --allow-net --allow-env scripts/verify-chemical-lookup-production.ts \
//     ["Product Name" ...]
//
// With no args it runs the standard verification set:
//   Spray Seal | Custodia 320SC | Custodia Forte |
//   Prosaro 420 SC Foliar Fungicide | Ridomil Gold (deliberately ambiguous)
//
// For each product it prints the FULL production JSON, then a summary of:
//   match_source, jurisdiction, registration identity, active ingredients,
//   groups, registered uses (rates / WHP / REI per claim), field_provenance,
//   unresolved_fields, conflicts, discovery envelope.
//
// Summary paths follow the structured contract exactly:
//   registration number  -> registration.registration_number
//   registrant           -> registration.registrant
//   unresolved fields    -> verification.unresolved_fields
//   conflicts            -> verification.conflicts

const ENDPOINT = Deno.env.get("LOOKUP_ENDPOINT") ??
  "https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/chemical-info-lookup";
const COUNTRY = Deno.env.get("LOOKUP_COUNTRY") ?? "Australia";

const DEFAULT_PRODUCTS: string[] = [
  "Spray Seal",
  "Custodia 320SC",
  "Custodia Forte",
  "Prosaro 420 SC Foliar Fungicide",
  "Ridomil Gold",
];

// deno-lint-ignore no-explicit-any
type Json = any;

function line(label: string, value: unknown): void {
  console.log(`${label}: ${value === undefined || value === null ? "(absent)" : JSON.stringify(value)}`);
}

async function verifyOne(jwt: string, productName: string): Promise<void> {
  console.log(`\n${"=".repeat(72)}\nPRODUCT: ${productName}  (country: ${COUNTRY})\n${"=".repeat(72)}`);
  const started = Date.now();
  const res = await fetch(ENDPOINT, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${jwt}`,
      "apikey": jwt,
    },
    body: JSON.stringify({ action: "structured", productName, country: COUNTRY }),
  });
  const body: Json = await res.json().catch(() => null);
  console.log(`HTTP ${res.status} in ${Date.now() - started} ms`);
  console.log("\n--- FULL PRODUCTION JSON ---");
  console.log(JSON.stringify(body, null, 2));

  if (!body || typeof body !== "object") return;
  console.log("\n--- SUMMARY ---");
  line("match_source", body.match_source);
  line("jurisdiction", body.jurisdiction);
  line("discovery", body.discovery);
  line("registration_number", body.registration?.registration_number);
  line("registrant", body.registration?.registrant);
  line("product_name", body.product_name ?? body.registration?.registered_product_name);
  const actives: Json[] = Array.isArray(body.active_ingredients) ? body.active_ingredients : [];
  for (const a of actives) {
    line(
      "active",
      `${a?.name ?? "?"} ${a?.concentration ?? "?"} ${a?.concentration_unit ?? ""} group=${
        JSON.stringify(a?.activity_group ?? null)
      }`,
    );
  }
  line("activity_groups", body.activity_groups);
  const uses: Json[] = Array.isArray(body.registered_uses) ? body.registered_uses : [];
  if (!uses.length) line("registered_uses", "(empty)");
  for (const u of uses) {
    line(
      "use",
      `${u?.crop ?? "?"} — ${u?.target_raw ?? u?.target ?? "?"} | rates=${JSON.stringify(u?.rates ?? [])} | WHP=${
        u?.withholding_period_days ?? "unstated"
      } | REI=${u?.re_entry_period_hours ?? "unstated"} | provenance=${JSON.stringify(u?.provenance ?? null)}`,
    );
  }
  line("ai_suggested_uses", body.ai_suggested_uses);
  line("field_provenance", body.field_provenance);
  line("verification_status", body.verification?.status);
  line("unresolved_fields", body.verification?.unresolved_fields);
  line("conflicts", body.verification?.conflicts);
}

async function main(): Promise<void> {
  const jwt = Deno.env.get("LOOKUP_JWT") ?? "";
  if (!jwt) {
    console.error("LOOKUP_JWT is required (any valid JWT — the app anon key works).");
    Deno.exit(1);
  }
  const products = Deno.args.length ? Deno.args : DEFAULT_PRODUCTS;
  for (const p of products) {
    try {
      await verifyOne(jwt, p);
    } catch (err) {
      console.error(`"${p}" failed: ${err instanceof Error ? err.message : String(err)}`);
    }
    await new Promise((r) => setTimeout(r, 800));
  }
}

if (import.meta.main) {
  await main();
}
