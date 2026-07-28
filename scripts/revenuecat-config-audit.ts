// scripts/revenuecat-config-audit.ts   (Phase 2B §1 — live RevenueCat configuration audit)
//
// READ-ONLY: performs only GET requests against the RevenueCat REST API v2.
// Never creates customers (v2 GETs have no side effects), never writes to
// RevenueCat or Supabase, never prints receipts, tokens or secrets.
//
// Run where your keys are available (your local terminal — the Rork sandbox
// intentionally cannot read private secrets):
//
//   export REVENUECAT_SECRET_API_KEY=sk_...
//   export REVENUECAT_PROJECT_ID=proj...          # optional; auto-detected if you have one project
//   deno run --allow-net --allow-env scripts/revenuecat-config-audit.ts
//
// Optional — audit a specific customer (e.g. Jonathan's Supabase user id):
//   deno run --allow-net --allow-env scripts/revenuecat-config-audit.ts \
//     --customer b5116ecf-1b6c-4d33-a0ed-384b52907f67
//
// Optional — cross-check billing_product_catalog against the live products
// (needs the SQL 134 migration applied):
//   export V2_SUPABASE_URL=https://tbafuqwruefgkbyxrxyb.supabase.co
//   export V2_SERVICE_ROLE_KEY=...                # server-side only, never commit
//
// What it reports (§1 checklist):
//   * project + apps (iOS bundle / Android package linkage)
//   * every entitlement — confirms `pro`, flags any `premium` remnant
//   * every product: platform, store product id, attached-to-pro or ORPHANED
//   * offerings: which is current, packages, per-platform product mapping
//   * per-customer (when --customer given): pro state, subscriptions summary,
//     aliases, most recent platform — no receipts or transaction payloads
//   * catalogue cross-check: which billing_product_catalog rows to activate
//
// Dashboard-only items the public API does not expose (check manually):
//   * webhook configuration + delivery history (Project settings → Integrations)
//   * App Store shared secret / Play service-account credentials
//   * Targeting rules, Experiments, offering overrides, promotional grants

// deno-lint-ignore-file no-explicit-any

const RC_KEY = Deno.env.get("REVENUECAT_SECRET_API_KEY") ?? "";
let RC_PROJECT = Deno.env.get("REVENUECAT_PROJECT_ID") ?? "";
const SB_URL = Deno.env.get("V2_SUPABASE_URL") ?? "";
const SB_SERVICE = Deno.env.get("V2_SERVICE_ROLE_KEY") ?? "";

const customerIds: string[] = [];
for (let i = 0; i < Deno.args.length; i++) {
  if (Deno.args[i] === "--customer" && Deno.args[i + 1]) customerIds.push(Deno.args[++i]);
}

if (!RC_KEY) {
  console.error("Missing env: REVENUECAT_SECRET_API_KEY (sk_...). Dashboard → Project settings → API keys → Secret.");
  Deno.exit(1);
}

async function rc(path: string, tolerate404 = false): Promise<any | null> {
  const res = await fetch(`https://api.revenuecat.com/v2${path}`, {
    headers: { Authorization: `Bearer ${RC_KEY}`, "Content-Type": "application/json" },
  });
  if (res.status === 429) {
    await new Promise((r) => setTimeout(r, 2000));
    return rc(path, tolerate404);
  }
  if (res.status === 404 && tolerate404) return null;
  if (!res.ok) throw new Error(`RevenueCat GET ${path} -> ${res.status} ${await res.text()}`);
  return res.json();
}

async function rcList(path: string): Promise<any[]> {
  const items: any[] = [];
  let next: string | null = `${path}${path.includes("?") ? "&" : "?"}limit=100`;
  while (next) {
    const page = await rc(next);
    items.push(...(page?.items ?? []));
    next = page?.next_page ?? null;
  }
  return items;
}

async function sb(path: string): Promise<any[] | null> {
  if (!SB_URL || !SB_SERVICE) return null;
  const res = await fetch(`${SB_URL}/rest/v1${path}`, {
    headers: { apikey: SB_SERVICE, Authorization: `Bearer ${SB_SERVICE}` },
  });
  if (!res.ok) {
    console.error(`(catalogue cross-check skipped: Supabase ${path} -> ${res.status})`);
    return null;
  }
  return res.json();
}

function appPlatform(app: any): string {
  return app?.type ?? "unknown"; // app_store | play_store | stripe | ...
}

const report: any = {
  generated_at: new Date().toISOString(),
  project: null,
  apps: [],
  entitlements: [],
  entitlement_findings: { pro_exists: false, premium_exists: false, other_identifiers: [] as string[] },
  products: [],
  orphaned_products: [] as string[],
  offerings: [],
  customers: [],
  catalogue_crosscheck: null,
  dashboard_only_checks: [
    "Webhook URL + Authorization header + delivery history (Integrations)",
    "App Store shared secret / Play service-account credentials",
    "Targeting rules / Experiments / offering overrides / promotional entitlements",
  ],
};

// ---- Project ----------------------------------------------------------------
if (!RC_PROJECT) {
  const projects = await rcList("/projects");
  if (projects.length === 1) RC_PROJECT = projects[0].id;
  else {
    console.error(`Multiple projects found — set REVENUECAT_PROJECT_ID. Candidates: ${projects.map((p) => `${p.id} (${p.name})`).join(", ")}`);
    Deno.exit(1);
  }
}
const project = await rc(`/projects/${RC_PROJECT}`);
report.project = { id: project?.id, name: project?.name };

// ---- Apps ---------------------------------------------------------------------
const apps = await rcList(`/projects/${RC_PROJECT}/apps`);
report.apps = apps.map((a) => ({
  id: a.id,
  name: a.name,
  type: appPlatform(a),
  bundle_id: a?.app_store?.bundle_id ?? null,
  package_name: a?.play_store?.package_name ?? null,
}));

// ---- Entitlements + attached products ----------------------------------------
const entitlements = await rcList(`/projects/${RC_PROJECT}/entitlements`);
const productsByEntitlement = new Map<string, any[]>();
for (const ent of entitlements) {
  const attached = await rcList(`/projects/${RC_PROJECT}/entitlements/${ent.id}/products`);
  productsByEntitlement.set(ent.lookup_key, attached);
  report.entitlements.push({
    id: ent.id,
    lookup_key: ent.lookup_key,
    display_name: ent.display_name,
    attached_product_count: attached.length,
  });
  if (ent.lookup_key === "pro") report.entitlement_findings.pro_exists = true;
  else if (ent.lookup_key === "premium") report.entitlement_findings.premium_exists = true;
  else report.entitlement_findings.other_identifiers.push(ent.lookup_key);
}

// ---- Products (classify attached vs orphaned) ---------------------------------
const allProducts = await rcList(`/projects/${RC_PROJECT}/products`);
const proProductIds = new Set((productsByEntitlement.get("pro") ?? []).map((p: any) => p.id));
const appById = new Map(apps.map((a) => [a.id, a]));
for (const p of allProducts) {
  const app = appById.get(p.app_id);
  const attachedTo = entitlements
    .filter((e) => (productsByEntitlement.get(e.lookup_key) ?? []).some((ap: any) => ap.id === p.id))
    .map((e) => e.lookup_key);
  const row = {
    rc_product_id: p.id,
    store_identifier: p.store_identifier,
    type: p.type,
    platform: appPlatform(app),
    app_name: app?.name ?? p.app_id,
    attached_to: attachedTo,
    activates_pro: proProductIds.has(p.id),
  };
  report.products.push(row);
  if (attachedTo.length === 0) report.orphaned_products.push(`${row.platform}:${row.store_identifier}`);
}

// ---- Offerings, packages, per-platform product mapping -------------------------
const offerings = await rcList(`/projects/${RC_PROJECT}/offerings`);
const productById = new Map(allProducts.map((p) => [p.id, p]));
for (const off of offerings) {
  const packages = await rcList(`/projects/${RC_PROJECT}/offerings/${off.id}/packages`);
  const pkgRows: any[] = [];
  for (const pkg of packages) {
    const pkgProducts = await rcList(`/projects/${RC_PROJECT}/packages/${pkg.id}/products`);
    pkgRows.push({
      lookup_key: pkg.lookup_key,
      display_name: pkg.display_name,
      products: pkgProducts.map((pp: any) => {
        const full = productById.get(pp.id) ?? pp;
        const app = appById.get(full.app_id);
        return {
          platform: appPlatform(app),
          store_identifier: full.store_identifier,
          activates_pro: proProductIds.has(full.id),
        };
      }),
    });
  }
  report.offerings.push({
    id: off.id,
    lookup_key: off.lookup_key,
    display_name: off.display_name,
    is_current: off.is_current === true,
    packages: pkgRows,
  });
}

// ---- Customer lookups (safe summary only) --------------------------------------
for (const cid of customerIds) {
  const customer = await rc(`/projects/${RC_PROJECT}/customers/${encodeURIComponent(cid)}`, true);
  if (!customer) {
    report.customers.push({ customer_id: cid, found: false });
    continue;
  }
  const active = await rc(`/projects/${RC_PROJECT}/customers/${encodeURIComponent(cid)}/active_entitlements?limit=20`, true);
  const subs = await rc(`/projects/${RC_PROJECT}/customers/${encodeURIComponent(cid)}/subscriptions?limit=20`, true);
  const aliases = await rc(`/projects/${RC_PROJECT}/customers/${encodeURIComponent(cid)}/aliases?limit=20`, true);
  report.customers.push({
    customer_id: cid,
    found: true,
    first_seen_at: customer.first_seen_at ?? null,
    last_seen_at: customer.last_seen_at ?? null,
    aliases: (aliases?.items ?? []).map((a: any) => String(a.id ?? a).slice(0, 12) + "…"),
    active_entitlements: (active?.items ?? []).map((e: any) => e.entitlement_id ?? e.lookup_key ?? "?"),
    pro_active: (active?.items ?? []).some((e: any) => (e.lookup_key ?? e.entitlement_id ?? "") === "pro"),
    subscriptions: (subs?.items ?? []).map((s: any) => ({
      product_id: s.product_id ?? s.store_product_identifier ?? "?",
      store: s.store ?? "?",
      status: s.status ?? "?",
      environment: s.environment ?? "?",
      auto_renewal: s.auto_renewal_status ?? "?",
      current_period_ends_at: s.current_period_ends_at ?? null,
      has_linked_store_transaction: Boolean(s.original_transaction_id ?? s.id),
    })),
  });
}

// ---- Catalogue cross-check (optional) -------------------------------------------
const catalog = await sb("/billing_product_catalog?select=external_product_id,plan_code,platform,environment,is_active&provider=eq.revenuecat");
if (catalog) {
  const liveIds = new Set(report.products.map((p: any) => p.store_identifier));
  report.catalogue_crosscheck = {
    catalogue_rows: catalog.length,
    live_products_missing_from_catalogue: report.products
      .filter((p: any) => p.activates_pro && !catalog.some((c: any) => c.external_product_id === p.store_identifier))
      .map((p: any) => `${p.platform}:${p.store_identifier}`),
    catalogue_rows_not_in_revenuecat: catalog
      .filter((c: any) => !liveIds.has(c.external_product_id))
      .map((c: any) => `${c.platform}:${c.external_product_id} (${c.is_active ? "ACTIVE" : "inactive"})`),
    inactive_rows_matching_live_pro_products: catalog
      .filter((c: any) => !c.is_active && report.products.some((p: any) => p.activates_pro && p.store_identifier === c.external_product_id))
      .map((c: any) => `${c.platform}:${c.external_product_id} → plan ${c.plan_code} (activate after review)`),
  };
}

console.log(JSON.stringify(report, null, 2));

// ---- Human summary ---------------------------------------------------------------
const f = report.entitlement_findings;
console.error("\n──── Summary ────");
console.error(`Project: ${report.project?.name} (${report.project?.id})`);
console.error(`Apps: ${report.apps.map((a: any) => `${a.type}:${a.bundle_id ?? a.package_name ?? a.name}`).join(", ")}`);
console.error(`Entitlement 'pro': ${f.pro_exists ? "FOUND" : "MISSING — configuration problem"}`);
if (f.premium_exists) console.error("WARNING: legacy 'premium' entitlement still exists — webhook classifies it needs_review, never grants.");
if (f.other_identifiers.length) console.error(`Other entitlements: ${f.other_identifiers.join(", ")}`);
console.error(`Products: ${report.products.length} total, ${report.products.filter((p: any) => p.activates_pro).length} activate 'pro', ${report.orphaned_products.length} ORPHANED${report.orphaned_products.length ? ` (${report.orphaned_products.join(", ")})` : ""}`);
const current = report.offerings.find((o: any) => o.is_current);
console.error(`Current offering: ${current ? `${current.lookup_key} with ${current.packages.length} package(s)` : "NONE marked current — check dashboard"}`);
for (const c of report.customers) {
  console.error(c.found
    ? `Customer ${c.customer_id.slice(0, 8)}…: pro=${c.pro_active ? "ACTIVE" : "inactive/absent"}, ${c.subscriptions.length} subscription(s), ${c.aliases.length} alias(es)`
    : `Customer ${c.customer_id.slice(0, 8)}…: NOT FOUND in RevenueCat (no purchase or never logged in)`);
}
if (report.catalogue_crosscheck) {
  const cc = report.catalogue_crosscheck;
  console.error(`Catalogue: ${cc.catalogue_rows} rows; missing mappings: ${cc.live_products_missing_from_catalogue.length}; stale rows: ${cc.catalogue_rows_not_in_revenuecat.length}; ready to activate: ${cc.inactive_rows_matching_live_pro_products.length}`);
}
