// Supabase Edge Function: get-stripe-invoice-link (Phase 2E)
//
// Mints a fresh, short-lived Stripe invoice URL (hosted view or PDF
// download) for the authenticated Vineyard Owner with billing authority.
// Links are generated ON DEMAND per click — nothing is persisted and no
// Stripe URL is stored for customer use.
//
// Security model (all enforced server-side on every call):
//   * Valid Supabase user JWT required.
//   * Active Owner membership (vineyard_members.role = 'owner') for the
//     requested vineyard.
//   * Caller must be the billing owner of the vineyard's subscription.
//   * The invoice must exist in vinetrack_invoice_records AND belong to
//     this vineyard's billing account (subscription / vineyard / Stripe
//     customer linkage). Foreign invoice IDs are rejected before any
//     Stripe call is made.
//   * Defence in depth: after retrieving the invoice from Stripe, its
//     customer must equal the subscription's stored stripe_customer_id.
//   * Only invoice objects are retrievable — no arbitrary Stripe access.
//
// Request:  POST { "vineyard_id": "<uuid>", "invoice_id": "in_...", "action": "view" | "download" }
// Success:  200 { "invoice_id": "in_...", "action": "view", "url": "https://..." }
// Errors:   401 authentication_required
//           403 owner_required | billing_managed_by_another_owner | invoice_access_denied
//           404 vineyard_not_found | no_billing_relationship | invoice_not_found
//
// Required environment (Supabase function secrets):
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY (auto)
//   STRIPE_SECRET_KEY   server-side Stripe API key

// deno-lint-ignore-file no-explicit-any

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const INVOICE_ID_RE = /^in_[A-Za-z0-9]+$/;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const stripeKey = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
  if (!supabaseUrl || !serviceRoleKey || !anonKey) {
    return json({ error: "server_misconfigured" }, 500);
  }
  if (!stripeKey) {
    console.error("invoice-link: STRIPE_SECRET_KEY not configured");
    return json({ error: "stripe_not_configured" }, 500);
  }

  // ---- 1. Authenticate the caller. -----------------------------------------
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return json({ error: "authentication_required" }, 401);
  }
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData?.user?.id) {
    return json({ error: "authentication_required" }, 401);
  }
  const userId = userData.user.id;

  // ---- 2. Validate input. ---------------------------------------------------
  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const vineyardId: string = String(body?.vineyard_id ?? "");
  const invoiceId: string = String(body?.invoice_id ?? "");
  const action: string = String(body?.action ?? "view");
  if (!UUID_RE.test(vineyardId)) return json({ error: "vineyard_not_found" }, 404);
  if (!INVOICE_ID_RE.test(invoiceId)) return json({ error: "invoice_not_found" }, 404);
  if (action !== "view" && action !== "download") {
    return json({ error: "unsupported_action" }, 400);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // ---- 3. Active Owner membership. -----------------------------------------
  const { data: isOwner, error: ownerErr } = await admin.rpc(
    "_is_active_vineyard_owner",
    { p_user: userId, p_vineyard: vineyardId },
  );
  if (ownerErr) {
    console.error("invoice-link: owner check failed", ownerErr.message);
    return json({ error: "server_error" }, 500);
  }
  if (isOwner !== true) return json({ error: "owner_required" }, 403);

  // ---- 4. Billing authority for this vineyard's subscription. ---------------
  const { data: subId, error: subIdErr } = await admin.rpc(
    "_vineyard_billing_subscription_id",
    { p_vineyard: vineyardId },
  );
  if (subIdErr) {
    console.error("invoice-link: subscription resolve failed", subIdErr.message);
    return json({ error: "server_error" }, 500);
  }
  if (!subId) return json({ error: "no_billing_relationship" }, 404);

  const { data: sub, error: subErr } = await admin
    .from("vinetrack_subscriptions")
    .select("id, owner_user_id, billing_provider, stripe_customer_id")
    .eq("id", subId)
    .is("deleted_at", null)
    .maybeSingle();
  if (subErr || !sub) return json({ error: "no_billing_relationship" }, 404);
  if (sub.owner_user_id !== userId) {
    return json({ error: "billing_managed_by_another_owner" }, 403);
  }
  if (sub.billing_provider !== "stripe" || !sub.stripe_customer_id) {
    return json({ error: "invoice_access_denied" }, 403);
  }

  // ---- 5. The invoice must belong to THIS billing account. ------------------
  const { data: invoice, error: invErr } = await admin
    .from("vinetrack_invoice_records")
    .select("id, subscription_id, vineyard_id, external_customer_id")
    .eq("provider", "stripe")
    .eq("external_invoice_id", invoiceId)
    .maybeSingle();
  if (invErr) {
    console.error("invoice-link: invoice lookup failed", invErr.message);
    return json({ error: "server_error" }, 500);
  }
  if (!invoice) return json({ error: "invoice_not_found" }, 404);

  const linked =
    invoice.subscription_id === sub.id ||
    invoice.vineyard_id === vineyardId ||
    (invoice.external_customer_id !== null &&
      invoice.external_customer_id === sub.stripe_customer_id);
  if (!linked) return json({ error: "invoice_access_denied" }, 403);

  // ---- 6. Retrieve the CURRENT invoice from Stripe (fresh URLs). ------------
  const stripeResp = await fetch(
    `https://api.stripe.com/v1/invoices/${encodeURIComponent(invoiceId)}`,
    { headers: { Authorization: `Bearer ${stripeKey}` } },
  );
  if (stripeResp.status === 404) return json({ error: "invoice_not_found" }, 404);
  if (!stripeResp.ok) {
    const errText = await stripeResp.text();
    console.error(`invoice-link: Stripe API ${stripeResp.status}: ${errText.slice(0, 300)}`);
    return json({ error: "stripe_request_failed" }, 502);
  }
  const stripeInvoice = await stripeResp.json();

  // Defence in depth: Stripe's record must agree on the customer.
  const stripeCustomer =
    typeof stripeInvoice?.customer === "string"
      ? stripeInvoice.customer
      : stripeInvoice?.customer?.id ?? null;
  if (stripeCustomer !== sub.stripe_customer_id) {
    console.error("invoice-link: customer mismatch — refusing to link");
    return json({ error: "invoice_access_denied" }, 403);
  }

  const url =
    action === "download"
      ? stripeInvoice?.invoice_pdf ?? null
      : stripeInvoice?.hosted_invoice_url ?? null;
  if (!url) return json({ error: "invoice_link_unavailable" }, 404);

  return json({ invoice_id: invoiceId, action, url }, 200);
});
