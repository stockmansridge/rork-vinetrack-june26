// scripts/revenuecat-backfill-dryrun.ts   (OPTIONAL FUTURE TOOLING — not part of Phase 2B)
//
// STATUS (2026-07-28): VineTrack has NO paying customers through Apple,
// Google Play or the portal, so the historical backfill was REMOVED from
// the Phase 2B scope. Do not run this (dry-run or --execute) as part of
// launch validation. It is retained only as standalone, zero-maintenance
// tooling should a future migration of pre-existing RevenueCat customers
// ever be needed. Internal/test RevenueCat records are NOT production
// customers and must not be backfilled.
//
// Enumerates RevenueCat customers, resolves canonical Supabase users, maps
// products through billing_product_catalog, and produces the DRY-RUN report
// required before any production backfill. Idempotent and resumable.
//
// DRY RUN (default — reads only, writes nothing):
//   deno run --allow-net --allow-env scripts/revenuecat-backfill-dryrun.ts
//
// EXECUTE (only after the dry-run report has been reviewed and approved):
//   deno run --allow-net --allow-env scripts/revenuecat-backfill-dryrun.ts --execute
//
// Required environment:
//   REVENUECAT_SECRET_API_KEY   RevenueCat secret API key (sk_...). Dashboard →
//                               Project settings → API keys. NEVER the public
//                               SDK keys.
//   REVENUECAT_PROJECT_ID       RevenueCat project id (proj...).
//   V2_SUPABASE_URL             VineTrack production Supabase URL.
//   V2_SERVICE_ROLE_KEY         Service-role key (server-side only).
//
// Optional:
//   BACKFILL_STARTING_AFTER     resume cursor (customer id from a previous run)
//   BACKFILL_LIMIT              max customers to scan this run (default 1000)
//
// Safety properties:
//   * Uses the RevenueCat REST API v2 LIST endpoint (GET /projects/{id}/customers)
//     — unlike the v1 GET /subscribers/{id} endpoint, listing NEVER creates
//     customers as a side effect.
//   * Only customers whose customer id (or an alias) parses as a Supabase
//     auth UUID are matched; everything else lands in `unmatched`.
//   * Only products with an ACTIVE production mapping in
//     billing_product_catalog are proposed; unknown products are reported,
//     never written.
//   * --execute upserts vinetrack_subscriptions keyed on
//     (billing_provider, external_subscription_id) — re-running never
//     duplicates rows. Rows written by backfill carry
//     last_provider_event = 'BACKFILL' and an audit event
//     'store_subscription_backfilled'.
//   * Rollback: delete (or set deleted_at on) rows where
//     last_provider_event = 'BACKFILL'; access instantly falls back to the
//     client RevenueCat check, so no customer is locked out.
//   * No receipts or purchase tokens are fetched, stored or printed.

// deno-lint-ignore-file no-explicit-any

const RC_KEY = Deno.env.get("REVENUECAT_SECRET_API_KEY") ?? "";
const RC_PROJECT = Deno.env.get("REVENUECAT_PROJECT_ID") ?? "";
const SB_URL = Deno.env.get("V2_SUPABASE_URL") ?? "";
const SB_SERVICE = Deno.env.get("V2_SERVICE_ROLE_KEY") ?? "";
const EXECUTE = Deno.args.includes("--execute");
const LIMIT = Number(Deno.env.get("BACKFILL_LIMIT") ?? "1000");
let cursor = Deno.env.get("BACKFILL_STARTING_AFTER") ?? "";

if (!RC_KEY || !RC_PROJECT || !SB_URL || !SB_SERVICE) {
  console.error("Missing env: REVENUECAT_SECRET_API_KEY, REVENUECAT_PROJECT_ID, V2_SUPABASE_URL, V2_SERVICE_ROLE_KEY");
  Deno.exit(1);
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function rc(path: string): Promise<any> {
  const res = await fetch(`https://api.revenuecat.com/v2${path}`, {
    headers: { Authorization: `Bearer ${RC_KEY}`, "Content-Type": "application/json" },
  });
  if (res.status === 429) {
    await new Promise((r) => setTimeout(r, 2000));
    return rc(path);
  }
  if (!res.ok) throw new Error(`RevenueCat ${path} -> ${res.status}`);
  return res.json();
}

async function sb(path: string, init: RequestInit = {}): Promise<any> {
  const res = await fetch(`${SB_URL}/rest/v1${path}`, {
    ...init,
    headers: {
      apikey: SB_SERVICE,
      Authorization: `Bearer ${SB_SERVICE}`,
      "Content-Type": "application/json",
      Prefer: "return=representation",
      ...(init.headers ?? {}),
    },
  });
  if (!res.ok) throw new Error(`Supabase ${path} -> ${res.status}: ${await res.text()}`);
  return res.status === 204 ? null : res.json();
}

function storeMapping(store: string): { platform: string; provider: string } | null {
  switch ((store ?? "").toLowerCase()) {
    case "app_store":
    case "mac_app_store":
      return { platform: "ios", provider: "apple" };
    case "play_store":
      return { platform: "android", provider: "google" };
    default:
      return null;
  }
}

const report = {
  mode: EXECUTE ? "EXECUTE" : "DRY_RUN",
  scanned_customers: 0,
  matched_supabase_users: 0,
  unmatched_customers: [] as string[],
  active_pro_subscribers: 0,
  expired_subscribers: 0,
  sandbox_only: 0,
  unknown_products: [] as string[],
  conflicts: [] as any[],
  proposed_rows: [] as any[],
  written_rows: 0,
  next_cursor: null as string | null,
};

// Load the product catalogue once.
const catalog: any[] = await sb(
  "/billing_product_catalog?select=external_product_id,plan_code,platform,environment,is_active,entitlement_id&provider=eq.revenuecat",
);
const plans: any[] = await sb("/vinetrack_plans?select=id,code");
const planIdByCode = new Map(plans.map((p) => [p.code, p.id]));

while (report.scanned_customers < LIMIT) {
  const page = await rc(
    `/projects/${RC_PROJECT}/customers?limit=100${cursor ? `&starting_after=${encodeURIComponent(cursor)}` : ""}`,
  );
  const customers: any[] = page?.items ?? [];
  if (customers.length === 0) break;

  for (const customer of customers) {
    report.scanned_customers++;
    cursor = customer.id;
    const candidates = [customer.id, ...(customer.aliases ?? []).map((a: any) => (typeof a === "string" ? a : a?.id ?? ""))]
      .filter((v: string) => UUID_RE.test(v));
    const supabaseUserId = candidates[0] ?? null;
    if (!supabaseUserId) {
      report.unmatched_customers.push(String(customer.id).slice(0, 24));
      continue;
    }
    report.matched_supabase_users++;

    // Active entitlements + subscriptions for this customer.
    const subs = await rc(`/projects/${RC_PROJECT}/customers/${encodeURIComponent(customer.id)}/subscriptions?limit=20`);
    for (const sub of subs?.items ?? []) {
      const productId: string = sub?.product_id ?? sub?.store_product_identifier ?? "";
      const mapping = storeMapping(sub?.store ?? "");
      const isSandbox = (sub?.environment ?? "").toLowerCase() === "sandbox";
      const isActive = ["active", "trialing", "in_grace_period"].includes((sub?.status ?? "").toLowerCase());

      if (isSandbox) { report.sandbox_only++; continue; }
      if (!mapping) continue;

      const cat = catalog.find((c) =>
        c.external_product_id === productId && c.is_active &&
        (c.platform === mapping.platform || c.platform === "any") &&
        (c.environment === "production" || c.environment === "any")
      );
      if (!cat) {
        if (productId && !report.unknown_products.includes(productId)) report.unknown_products.push(productId);
        continue;
      }
      if (isActive) report.active_pro_subscribers++;
      else report.expired_subscribers++;

      const externalSubId: string = sub?.original_transaction_id ?? sub?.id ?? "";
      // Conflict check: same provider subscription already owned by another user.
      const existing = await sb(
        `/vinetrack_subscriptions?select=id,owner_user_id&billing_provider=eq.${mapping.provider}&external_subscription_id=eq.${encodeURIComponent(externalSubId)}&deleted_at=is.null`,
      );
      if (existing.length > 0 && existing[0].owner_user_id !== supabaseUserId) {
        report.conflicts.push({ external_ref: externalSubId.slice(0, 8) + "…", users: [existing[0].owner_user_id, supabaseUserId] });
        continue;
      }

      const row = {
        owner_user_id: supabaseUserId,
        plan_id: planIdByCode.get(cat.plan_code),
        billing_provider: mapping.provider,
        platform: mapping.platform,
        environment: "production",
        status: isActive ? ((sub?.status ?? "").toLowerCase() === "trialing" ? "trialing" : "active") : "expired",
        current_period_start: sub?.current_period_starts_at ?? null,
        current_period_end: sub?.current_period_ends_at ?? null,
        cancel_at_period_end: sub?.auto_renewal_status === "will_not_renew",
        started_at: sub?.starts_at ?? null,
        expired_at: isActive ? null : (sub?.current_period_ends_at ?? null),
        seats_included: 1,
        revenuecat_app_user_id: supabaseUserId,
        revenuecat_entitlement: "pro",
        external_subscription_id: externalSubId,
        last_provider_event: "BACKFILL",
        last_provider_event_at: new Date().toISOString(),
        last_verified_at: new Date().toISOString(),
      };
      report.proposed_rows.push({ user: supabaseUserId, plan: cat.plan_code, status: row.status, provider: mapping.provider });

      if (EXECUTE && row.plan_id) {
        if (existing.length > 0) {
          await sb(`/vinetrack_subscriptions?id=eq.${existing[0].id}`, { method: "PATCH", body: JSON.stringify(row) });
        } else {
          await sb(`/vinetrack_subscriptions`, { method: "POST", body: JSON.stringify(row) });
        }
        await sb(`/vinetrack_entitlement_audit`, {
          method: "POST",
          body: JSON.stringify({
            user_id: supabaseUserId,
            event_type: "store_subscription_backfilled",
            new_state: { plan_code: cat.plan_code, status: row.status, provider: mapping.provider },
            platform: "server",
          }),
        });
        report.written_rows++;
      }
    }
  }
  if (!page?.next_page) break;
}

report.next_cursor = cursor || null;
console.log(JSON.stringify(report, null, 2));
