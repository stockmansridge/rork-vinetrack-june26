// Supabase Edge Function: revenuecat-webhook   (DRAFT — billing/entitlements)
//
// ⚠️  DRAFT ONLY. Part of the VineTrack July 2026 pricing/billing foundation.
//     This function syncs RevenueCat subscription lifecycle events into the
//     new draft entitlement tables (public.vinetrack_*). It does NOT change any
//     existing app/portal access behaviour — NewBackendRootView still gates on
//     the current RevenueCat SDK check. These tables are only consulted once the
//     app/portal adopt public.get_my_vinetrack_access().
//
// What it does:
//   1. Verifies a shared webhook secret (RevenueCat "Authorization" header).
//   2. Logs EVERY received event to public.vinetrack_billing_events (append-only).
//   3. Resolves the RevenueCat app_user_id as the Supabase auth user UUID.
//   4. Maps RevenueCat product/entitlement -> plan code:
//        legacy_monthly | legacy_yearly | solo
//   5. Upserts public.vinetrack_subscriptions for that user (apple provider).
//   6. Upserts public.vinetrack_user_licences (one active seat for the user).
//   7. Is idempotent on the RevenueCat event id.
//
// What it deliberately does NOT do:
//   * No invoice records for Solo / legacy Apple subscriptions — Apple owns the
//     receipt. (Stripe invoices for Team/Enterprise are handled elsewhere.)
//   * No Team/Enterprise handling — those come from Stripe, not RevenueCat.
//   * No access enforcement.
//
// Request: RevenueCat POSTs JSON of shape { api_version, event: {...} }.
//   See https://www.revenuecat.com/docs/webhooks for the event schema.
//
// Required environment:
//   SUPABASE_URL                  (auto-provided)
//   SUPABASE_SERVICE_ROLE_KEY     (auto-provided; bypasses RLS)
//   REVENUECAT_WEBHOOK_SECRET     shared secret; set the SAME value in the
//                                 RevenueCat dashboard "Authorization header"
//                                 field for this webhook.

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

// ---------------------------------------------------------------------------
// Product / entitlement -> plan code mapping
// ---------------------------------------------------------------------------
// ⚠️  PLACEHOLDERS. Replace the keys below with the REAL RevenueCat entitlement
//     identifiers and the REAL Apple product IDs (App Store Connect) once they
//     exist. Only legacy + Solo are handled here; Team/Enterprise are Stripe.
//
// Mapping precedence at runtime:
//   1. Exact Apple product id  (PRODUCT_TO_PLAN)
//   2. RevenueCat entitlement  (ENTITLEMENT_TO_PLAN)
//   3. null -> event is logged but no subscription/licence change is made.
const PRODUCT_TO_PLAN: Record<string, string> = {
  // --- Legacy monthly (available until 2026-06-30) ---
  "com.vinetrack.legacy.monthly": "legacy_monthly", // TODO: real product id
  "vinetrack_monthly": "legacy_monthly", // TODO: real product id
  // --- Legacy yearly ---
  "com.vinetrack.legacy.yearly": "legacy_yearly", // TODO: real product id
  "vinetrack_yearly": "legacy_yearly", // TODO: real product id
  // --- Solo (from 2026-07-01, 3-month trial) ---
  "com.vinetrack.solo.yearly": "solo", // TODO: real product id
  "vinetrack_solo_yearly": "solo", // TODO: real product id
};

const ENTITLEMENT_TO_PLAN: Record<string, string> = {
  // RevenueCat entitlement identifier -> plan code.
  "legacy": "legacy_yearly", // TODO: real entitlement id (legacy fallback)
  "solo": "solo", // TODO: real entitlement id
  // The current production entitlement that already gates the app:
  "premium": "legacy_yearly", // TODO: confirm the real production entitlement id
};

// ---------------------------------------------------------------------------
// RevenueCat event-type -> internal subscription status
// ---------------------------------------------------------------------------
// Statuses supported by the draft schema: trialing | active | past_due |
// canceled | expired | paused | manual.
//
// Note: CANCELLATION in RevenueCat means auto-renew was turned OFF; the user
// usually keeps access until expiration. We treat it as still-active but flag
// cancel_at_period_end. EXPIRATION is the terminal "access ended" event.
type RcStatusResult = {
  status: string;
  cancelAtPeriodEnd: boolean;
  // When true the user's licence should be revoked (access has actually ended).
  revokeLicence: boolean;
};

function resolveStatus(eventType: string, periodType: string | null): RcStatusResult {
  const isTrial = periodType === "TRIAL" || periodType === "INTRO";
  switch (eventType) {
    case "INITIAL_PURCHASE":
    case "RENEWAL":
    case "UNCANCELLATION":
    case "PRODUCT_CHANGE":
    case "SUBSCRIPTION_EXTENDED":
    case "TRANSFER":
      return {
        status: isTrial ? "trialing" : "active",
        cancelAtPeriodEnd: false,
        revokeLicence: false,
      };
    case "NON_RENEWING_PURCHASE":
      return { status: "active", cancelAtPeriodEnd: true, revokeLicence: false };
    case "CANCELLATION":
      // Auto-renew off; access continues until current_period_end.
      return {
        status: isTrial ? "trialing" : "active",
        cancelAtPeriodEnd: true,
        revokeLicence: false,
      };
    case "BILLING_ISSUE":
      return { status: "past_due", cancelAtPeriodEnd: false, revokeLicence: false };
    case "SUBSCRIPTION_PAUSED":
      return { status: "paused", cancelAtPeriodEnd: false, revokeLicence: true };
    case "EXPIRATION":
      return { status: "expired", cancelAtPeriodEnd: true, revokeLicence: true };
    default:
      // Unknown / informational event (e.g. TEST). Logged, no state change.
      return { status: "", cancelAtPeriodEnd: false, revokeLicence: false };
  }
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function msToIso(ms: unknown): string | null {
  if (typeof ms !== "number" || !Number.isFinite(ms) || ms <= 0) return null;
  try {
    return new Date(ms).toISOString();
  } catch {
    return null;
  }
}

function planForEvent(productId: string | null, entitlementIds: string[]): string | null {
  if (productId && PRODUCT_TO_PLAN[productId]) return PRODUCT_TO_PLAN[productId];
  for (const ent of entitlementIds) {
    if (ENTITLEMENT_TO_PLAN[ent]) return ENTITLEMENT_TO_PLAN[ent];
  }
  return null;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  // --- 1. Verify the shared webhook secret -------------------------------
  const expectedSecret = Deno.env.get("REVENUECAT_WEBHOOK_SECRET") ?? "";
  if (!expectedSecret) {
    // Fail closed: never accept unauthenticated billing writes.
    console.log("[revenuecat-webhook] REVENUECAT_WEBHOOK_SECRET not configured");
    return json({ error: "Webhook secret not configured" }, 500);
  }
  const authHeader = req.headers.get("Authorization") ?? "";
  if (authHeader !== expectedSecret) {
    console.log("[revenuecat-webhook] rejected: invalid Authorization header");
    return json({ error: "Unauthorized" }, 401);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !serviceRoleKey) {
    return json({ error: "Server is missing Supabase service configuration" }, 500);
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const event: any = body?.event ?? {};
  const eventId: string = typeof event?.id === "string" ? event.id : "";
  const eventType: string = typeof event?.type === "string" ? event.type : "";
  if (!eventId || !eventType) {
    return json({ error: "Missing event id/type" }, 400);
  }

  const appUserId: string = typeof event?.app_user_id === "string"
    ? event.app_user_id.trim()
    : "";
  const productId: string | null = typeof event?.product_id === "string"
    ? event.product_id
    : null;
  const entitlementIds: string[] = Array.isArray(event?.entitlement_ids)
    ? event.entitlement_ids.filter((e: unknown): e is string => typeof e === "string")
    : (typeof event?.entitlement_id === "string" ? [event.entitlement_id] : []);
  const periodType: string | null = typeof event?.period_type === "string"
    ? event.period_type
    : null;
  const environment: string = typeof event?.environment === "string"
    ? event.environment
    : "UNKNOWN";

  // Only treat the app_user_id as an owner when it is a real Supabase UUID.
  // Anonymous RevenueCat ids ($RCAnonymousID:...) cannot map to a user.
  const ownerUserId: string | null = UUID_RE.test(appUserId) ? appUserId : null;

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  // --- 2. Idempotency + audit log ----------------------------------------
  // Log the raw event first. The unique (provider, external_event_id) index
  // makes this the idempotency guard: a duplicate insert => already processed.
  const { error: logError } = await admin
    .from("vinetrack_billing_events")
    .insert({
      owner_user_id: ownerUserId,
      provider: "revenuecat",
      event_type: eventType,
      external_event_id: eventId,
      payload: { event, environment, api_version: body?.api_version ?? null },
    });

  if (logError) {
    // 23505 = unique_violation => event already logged/processed. Idempotent.
    if ((logError as any).code === "23505") {
      console.log(`[revenuecat-webhook] duplicate event id=${eventId} type=${eventType} (ignored)`);
      return json({ status: "already_processed", eventId });
    }
    console.log(`[revenuecat-webhook] failed to log event id=${eventId}: ${logError.message}`);
    return json({ error: "Failed to log event" }, 500);
  }

  // Helper: on a processing failure, remove the log row so RevenueCat retries
  // can reprocess (otherwise the idempotency guard would skip them forever).
  async function rollbackLog(reason: string): Promise<Response> {
    await admin
      .from("vinetrack_billing_events")
      .delete()
      .eq("provider", "revenuecat")
      .eq("external_event_id", eventId);
    console.log(`[revenuecat-webhook] processing failed id=${eventId}: ${reason}`);
    return json({ error: "Processing failed", detail: reason }, 500);
  }

  // No mappable user => nothing to upsert, but the event is recorded.
  if (!ownerUserId) {
    console.log(
      `[revenuecat-webhook] id=${eventId} type=${eventType} no Supabase user (app_user_id not a UUID); logged only`,
    );
    return json({ status: "logged_no_user", eventId });
  }

  // --- 3. Map to a plan --------------------------------------------------
  const planCode = planForEvent(productId, entitlementIds);
  if (!planCode) {
    console.log(
      `[revenuecat-webhook] id=${eventId} type=${eventType} product=${productId ?? "-"} ` +
        `ent=[${entitlementIds.join(",")}] no plan mapping; logged only`,
    );
    return json({ status: "logged_no_plan", eventId });
  }

  // Only legacy/Solo plans are RevenueCat-driven. Guard against accidental
  // Team/Enterprise mappings (those are Stripe-managed).
  if (!["legacy_monthly", "legacy_yearly", "solo"].includes(planCode)) {
    console.log(`[revenuecat-webhook] id=${eventId} non-Apple plan ${planCode}; logged only`);
    return json({ status: "logged_non_apple_plan", eventId });
  }

  const { data: plan, error: planError } = await admin
    .from("vinetrack_plans")
    .select("id, code, billing_provider")
    .eq("code", planCode)
    .maybeSingle();

  if (planError) return rollbackLog(`plan lookup: ${planError.message}`);
  if (!plan) return rollbackLog(`plan '${planCode}' not found (run migration 01 first)`);

  // --- 4. Resolve status + period windows --------------------------------
  const { status, cancelAtPeriodEnd, revokeLicence } = resolveStatus(eventType, periodType);
  if (!status) {
    console.log(`[revenuecat-webhook] id=${eventId} type=${eventType} informational; logged only`);
    return json({ status: "logged_informational", eventId });
  }

  const purchasedAt = msToIso(event?.purchased_at_ms);
  const expirationAt = msToIso(event?.expiration_at_ms);
  const isTrial = periodType === "TRIAL" || periodType === "INTRO";
  const nowIso = new Date().toISOString();

  // --- 5. Upsert the subscription ----------------------------------------
  // No unique constraint exists on revenuecat_app_user_id, so locate the
  // existing Apple subscription for this user manually, then update/insert.
  const { data: existing, error: findError } = await admin
    .from("vinetrack_subscriptions")
    .select("id")
    .eq("revenuecat_app_user_id", appUserId)
    .eq("billing_provider", "apple")
    .is("deleted_at", null)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (findError) return rollbackLog(`subscription lookup: ${findError.message}`);

  const subFields = {
    owner_user_id: ownerUserId,
    plan_id: plan.id,
    billing_provider: "apple",
    status,
    cancel_at_period_end: cancelAtPeriodEnd,
    trial_start: isTrial ? purchasedAt : null,
    trial_end: isTrial ? expirationAt : null,
    current_period_start: purchasedAt,
    current_period_end: expirationAt,
    started_at: purchasedAt,
    canceled_at: status === "canceled" || status === "expired" ? nowIso : null,
    seats_included: 1,
    revenuecat_app_user_id: appUserId,
    revenuecat_entitlement: entitlementIds[0] ?? null,
  };

  let subscriptionId: string;
  if (existing?.id) {
    const { error: updErr } = await admin
      .from("vinetrack_subscriptions")
      .update(subFields)
      .eq("id", existing.id);
    if (updErr) return rollbackLog(`subscription update: ${updErr.message}`);
    subscriptionId = existing.id;
  } else {
    const { data: inserted, error: insErr } = await admin
      .from("vinetrack_subscriptions")
      .insert(subFields)
      .select("id")
      .single();
    if (insErr || !inserted) return rollbackLog(`subscription insert: ${insErr?.message ?? "no row"}`);
    subscriptionId = inserted.id;
  }

  // Link the audit row to the resolved subscription.
  await admin
    .from("vinetrack_billing_events")
    .update({ subscription_id: subscriptionId })
    .eq("provider", "revenuecat")
    .eq("external_event_id", eventId);

  // --- 6. Upsert the user's licence --------------------------------------
  const { data: licence, error: licFindErr } = await admin
    .from("vinetrack_user_licences")
    .select("id, status")
    .eq("subscription_id", subscriptionId)
    .eq("user_id", ownerUserId)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (licFindErr) return rollbackLog(`licence lookup: ${licFindErr.message}`);

  if (revokeLicence) {
    // Access ended (expired/paused): revoke any active licence.
    if (licence?.id && licence.status === "active") {
      const { error: revErr } = await admin
        .from("vinetrack_user_licences")
        .update({ status: "revoked", revoked_at: nowIso })
        .eq("id", licence.id);
      if (revErr) return rollbackLog(`licence revoke: ${revErr.message}`);
    }
  } else {
    // Active/trialing: ensure an active licence exists for the owner.
    if (licence?.id) {
      if (licence.status !== "active") {
        const { error: reErr } = await admin
          .from("vinetrack_user_licences")
          .update({ status: "active", revoked_at: null, assigned_at: nowIso })
          .eq("id", licence.id);
        if (reErr) return rollbackLog(`licence reactivate: ${reErr.message}`);
      }
    } else {
      const { error: licInsErr } = await admin
        .from("vinetrack_user_licences")
        .insert({
          subscription_id: subscriptionId,
          user_id: ownerUserId,
          status: "active",
        });
      if (licInsErr) return rollbackLog(`licence insert: ${licInsErr.message}`);
    }
  }

  console.log(
    `[revenuecat-webhook] id=${eventId} type=${eventType} env=${environment} ` +
      `user=${ownerUserId.slice(0, 8)}… plan=${planCode} status=${status} ` +
      `revoked=${revokeLicence} sub=${subscriptionId.slice(0, 8)}…`,
  );

  return json({
    status: "processed",
    eventId,
    eventType,
    planCode,
    subscriptionStatus: status,
    revokedLicence: revokeLicence,
  });
});
