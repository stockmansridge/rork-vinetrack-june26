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
//
// Strict fail-closed contract (checked-but-unverified register consults):
// when discovery.outcome is unresolved/ambiguous on a supported register,
// match_source must be "unresolved" (never "ai_candidate"), every canonical
// product field must be unresolved, and the AI reading may appear ONLY in
// the clearly-non-authoritative `ai_suggestion` advisory beside `guidance`.

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
  // Stage LD-1 — official label document discovery + provenance.
  line("label_reference", body.registration?.label_reference);
  line("label_reference_provenance", body.field_provenance?.label_reference);
  const labelDocSources: Json[] =
    (Array.isArray(body.verification?.sources) ? body.verification.sources : [])
      .filter((s: Json) =>
        s?.kind === "manufacturer_label" &&
        String(s?.name ?? "").includes("label document")
      );
  if (!labelDocSources.length) line("label_document_source", "(none)");
  for (const s of labelDocSources) {
    line("label_document_source", `${s?.name} -> ${s?.reference}`);
  }
  // Stage LD-2 — document extraction envelope (rates parsed from the
  // official label PDF; unbound rows are the fail-closed audit trail).
  if (body.label_extraction && typeof body.label_extraction === "object") {
    const e: Json = body.label_extraction;
    line(
      "label_extraction",
      `parser v${e.parser_version} sha256=${String(e.document_sha256 ?? "").slice(0, 16)}… url=${e.document_url}`,
    );
    const unbound: Json[] = Array.isArray(e.unbound_rows) ? e.unbound_rows : [];
    if (!unbound.length) line("unbound_rows", "(none — every DFU row bound)");
    for (const r of unbound) {
      line(
        "unbound_row",
        `${r?.crop_text} — ${JSON.stringify(r?.target_texts ?? [])} (${r?.reason}) rates=${
          JSON.stringify(r?.rate_texts ?? [])
        }`,
      );
    }
  } else {
    line("label_extraction", "(absent — no document text pass this lookup)");
  }
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
  if (body.ai_suggestion && typeof body.ai_suggestion === "object") {
    const s: Json = body.ai_suggestion;
    line(
      "ai_suggestion",
      `present (product_name=${JSON.stringify(s.product_name ?? null)}, registrant=${
        JSON.stringify(s.registrant ?? null)
      }, actives=${Array.isArray(s.active_ingredients) ? s.active_ingredients.length : 0}, uses=${
        Array.isArray(s.registered_uses) ? s.registered_uses.length : 0
      })`,
    );
  } else {
    line("ai_suggestion", body.ai_suggestion);
  }
  line("guidance", body.guidance);
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
