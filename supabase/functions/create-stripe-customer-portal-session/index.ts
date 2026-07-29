// Supabase Edge Function: create-stripe-customer-portal-session (Phase 2E)
//
// Creates a FRESH Stripe Customer Portal session for the authenticated
// Vineyard Owner who holds billing authority for the selected vineyard.
//
// Security model (every rule enforced server-side, on every call):
//   * Request must carry a valid Supabase user JWT (Authorization header).
//   * Caller must hold an ACTIVE Owner membership (vineyard_members.role
//     = 'owner') for the requested vineyard_id.
//   * Caller must be the billing owner (vinetrack_subscriptions.
--     owner_user_id) of the vineyard's Stripe subscription — Owner-role
//     members without billing authority get 'billing_managed_by_another_owner'.
//   * The Stripe customer ID is loaded from trusted records only; any
//     client-supplied customer ID is ignored/unsupported.
//   * The return URL is the server-side allowlisted STRIPE_PORTAL_RETURN_URL.
//   * The session URL is returned once and never persisted.
//
// Request:  POST { "vineyard_id": "<uuid>" }
// Success:  200 { "url": "https://billing.stripe.com/..." }
// Errors:   401 authentication_required
//           403 owner_required | billing_managed_by_another_owner
//           404 vineyard_not_found | no_billing_relationship |
//               stripe_customer_not_found
//
// Required environment (Supabase function secrets):
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY (auto)
//   STRIPE_SECRET_KEY          server-side Stripe API key
//   STRIPE_PORTAL_RETURN_URL   allowlisted return URL, e.g.
//                              https://portal.example.com/account/billing

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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const stripeKey = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
  const returnUrl = Deno.env.get("STRIPE_PORTAL_RETURN_URL") ?? "";
  if (!supabaseUrl || !serviceRoleKey || !anonKey) {
    return json({ error: "server_misconfigured" }, 500);
  }
  if (!stripeKey || !returnUrl) {
    console.error("customer-portal: STRIPE_SECRET_KEY / STRIPE_PORTAL_RETURN_URL not configured");
    return json({ error: "stripe_not_configured" }, 500);
  }

  // ---- 1. Authenticate the caller (their JWT, not the service role). ------
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

  // ---- 2. Validate input (vineyard_id only; customer IDs are unsupported).
  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const vineyardId: string = String(body?.vineyard_id ?? "");
  if (!UUID_RE.test(vineyardId)) return json({ error: "vineyard_not_found" }, 404);

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // ---- 3. Active Owner membership (exact stored role value 'owner'). ------
  const { data: isOwner, error: ownerErr } = await admin.rpc(
    "_is_active_vineyard_owner",
    { p_user: userId, p_vineyard: vineyardId },
  );
  if (ownerErr) {
    console.error("customer-portal: owner check failed", ownerErr.message);
    return json({ error: "server_error" }, 500);
  }
  if (isOwner !== true) return json({ error: "owner_required" }, 403);

  // ---- 4. Resolve the vineyard's billing subscription (server-side). ------
  const { data: subId, error: subIdErr } = await admin.rpc(
    "_vineyard_billing_subscription_id",
    { p_vineyard: vineyardId },
  );
  if (subIdErr) {
    console.error("customer-portal: subscription resolve failed", subIdErr.message);
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

  // ---- 5. Billing authority: must BE the Stripe billing owner. ------------
  if (sub.owner_user_id !== userId) {
    return json({ error: "billing_managed_by_another_owner" }, 403);
  }
  if (sub.billing_provider !== "stripe" || !sub.stripe_customer_id) {
    return json({ error: "stripe_customer_not_found" }, 404);
  }

  // ---- 6. Fresh Stripe Customer Portal session (never persisted). ---------
  const form = new URLSearchParams();
  form.set("customer", sub.stripe_customer_id);
  form.set("return_url", returnUrl);

  const stripeResp = await fetch("https://api.stripe.com/v1/billing_portal/sessions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${stripeKey}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: form.toString(),
  });

  if (!stripeResp.ok) {
    const errText = await stripeResp.text();
    console.error(`customer-portal: Stripe API ${stripeResp.status}: ${errText.slice(0, 300)}`);
    return json({ error: "stripe_session_failed" }, 502);
  }

  const session = await stripeResp.json();
  if (!session?.url) return json({ error: "stripe_session_failed" }, 502);

  return json({ url: session.url }, 200);
});
