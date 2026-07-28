// Supabase Edge Function: revenuecat-webhook   (Phase 2B — verified store sync)
//
// Verifies RevenueCat webhook events server-side and writes them into the
// shared VineTrack entitlement system, so Apple and Google purchases unlock
// iOS, Android and the portal for the same Supabase user via
// get_my_vinetrack_access() (SQL 135).
//
// Flow:
//   1. Authenticate the request (Authorization header shared secret,
//      constant-time comparison; fails closed when unconfigured).
//   2. Record the event in public.billing_provider_events (SQL 133).
//      UNIQUE (provider, provider_event_id) is the idempotency guard —
//      duplicate deliveries return 200 "already_processed" and can never
//      create duplicate subscriptions. Processing failures UPDATE the row
//      to status 'failed' so RevenueCat retries can safely reprocess.
//   3. Resolve the RevenueCat App User ID to a canonical Supabase user:
//      the app_user_id must be a Supabase auth UUID (both apps call
//      Purchases.logIn(<auth.users.id>)); otherwise the alias list is
//      inspected. No trusted match -> 'needs_review' (never attach a
//      purchase to a random user; never create an Auth user here).
//   4. Gate on entitlement 'pro'. Events carrying 'premium' WITHOUT 'pro'
//      are classified as a configuration mismatch ('needs_review') and do
//      not grant access.
//   5. Map the store product to a VineTrack plan via
//      public.billing_product_catalog (SQL 134). Unknown or inactive
//      products -> 'needs_review', no access.
//   6. Sandbox events are stored but NEVER grant production access
//      (status 'ignored'; the resolver also excludes environment='sandbox').
//   7. Upsert public.vinetrack_subscriptions keyed on
//      (billing_provider, external_subscription_id) with normalised status,
//      period/grace windows and provider linkage; upsert the user licence.
//      Out-of-order guard: an event older than the stored
//      last_provider_event_at is recorded but does not overwrite state.
//   8. Write store lifecycle audit events into
//      public.vinetrack_entitlement_audit (state changes only).
//
// Statuses written to vinetrack_subscriptions:
//   trialing | active | past_due (billing issue w/ grace) | expired
//   CANCELLATION keeps access until current_period_end
//   (cancel_at_period_end = true); EXPIRATION is the terminal event.
//
// Required environment:
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY   (auto-provided)
//   REVENUECAT_WEBHOOK_SECRET   shared secret; set the same value in the
//                               RevenueCat dashboard webhook Authorization
//                               header. Stored ONLY as a function secret.

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

/** Constant-time string comparison (defends the shared-secret check). */
function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const ab = enc.encode(a);
  const bb = enc.encode(b);
  if (ab.length !== bb.length) {
    // Still burn comparable time before rejecting.
    let x = 0;
    for (let i = 0; i < ab.length; i++) x |= ab[i] ^ (bb[i % Math.max(bb.length, 1)] ?? 0);
    return false;
  }
  let diff = 0;
  for (let i = 0; i < ab.length; i++) diff |= ab[i] ^ bb[i];
  return diff === 0;
}

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
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

/** Strip receipt/token-looking keys before persisting the raw payload. */
function sanitizePayload(event: any): any {
  const cleaned: Record<string, unknown> = {};
  const blocked = new Set([
    "receipt", "receipts", "token", "tokens", "purchase_token",
    "access_token", "refresh_token", "signed_transaction",
    "subscriber_attributes",
  ]);
  for (const [key, value] of Object.entries(event ?? {})) {
    if (blocked.has(key.toLowerCase())) continue;
    cleaned[key] = value;
  }
  return cleaned;
}

/** RevenueCat store -> (platform, billing_provider). */
function storeMapping(store: string | null): { platform: string; provider: string } | null {
  switch ((store ?? "").toUpperCase()) {
    case "APP_STORE":
    case "MAC_APP_STORE":
      return { platform: "ios", provider: "apple" };
    case "PLAY_STORE":
      return { platform: "android", provider: "google" };
    default:
      return null; // STRIPE / AMAZON / PROMOTIONAL / RC_BILLING -> needs_review
  }
}

type StatusResult = {
  status: string;              // trialing | active | past_due | expired | ''
  cancelAtPeriodEnd: boolean | null; // null = leave unchanged
  revokeLicence: boolean;
  auditEvent: string | null;   // store_* lifecycle audit event
};

function resolveStatus(eventType: string, periodType: string | null): StatusResult {
  const isTrial = periodType === "TRIAL" || periodType === "INTRO";
  switch (eventType) {
    case "INITIAL_PURCHASE":
      return { status: isTrial ? "trialing" : "active", cancelAtPeriodEnd: false, revokeLicence: false, auditEvent: "store_subscription_created" };
    case "RENEWAL":
      return { status: isTrial ? "trialing" : "active", cancelAtPeriodEnd: false, revokeLicence: false, auditEvent: "store_subscription_renewed" };
    case "PRODUCT_CHANGE":
      return { status: isTrial ? "trialing" : "active", cancelAtPeriodEnd: false, revokeLicence: false, auditEvent: "store_subscription_product_changed" };
    case "UNCANCELLATION":
      return { status: isTrial ? "trialing" : "active", cancelAtPeriodEnd: false, revokeLicence: false, auditEvent: "store_subscription_uncancelled" };
    case "SUBSCRIPTION_EXTENDED":
      return { status: "active", cancelAtPeriodEnd: null, revokeLicence: false, auditEvent: "store_subscription_renewed" };
    case "NON_RENEWING_PURCHASE":
      return { status: "active", cancelAtPeriodEnd: true, revokeLicence: false, auditEvent: "store_subscription_created" };
    case "CANCELLATION":
      // Auto-renew OFF; access continues until current_period_end.
      return { status: isTrial ? "trialing" : "active", cancelAtPeriodEnd: true, revokeLicence: false, auditEvent: "store_subscription_cancelled" };
    case "BILLING_ISSUE":
      return { status: "past_due", cancelAtPeriodEnd: null, revokeLicence: false, auditEvent: "store_subscription_billing_issue" };
    case "SUBSCRIPTION_PAUSED":
      return { status: "paused", cancelAtPeriodEnd: null, revokeLicence: true, auditEvent: "store_subscription_expired" };
    case "EXPIRATION":
      return { status: "expired", cancelAtPeriodEnd: true, revokeLicence: true, auditEvent: "store_subscription_expired" };
    default:
      return { status: "", cancelAtPeriodEnd: null, revokeLicence: false, auditEvent: null };
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  // --- 1. Authenticate (fail closed; constant-time) -----------------------
  const expectedSecret = Deno.env.get("REVENUECAT_WEBHOOK_SECRET") ?? "";
  if (!expectedSecret) {
    console.log("[revenuecat-webhook] REVENUECAT_WEBHOOK_SECRET not configured");
    return json({ error: "Webhook secret not configured" }, 500);
  }
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!timingSafeEqual(authHeader, expectedSecret)) {
    console.log("[revenuecat-webhook] rejected: invalid Authorization header");
    return json({ error: "Unauthorized" }, 401);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !serviceRoleKey) {
    return json({ error: "Server is missing Supabase service configuration" }, 500);
  }

  let rawBody: string;
  let body: any;
  try {
    rawBody = await req.text();
    body = JSON.parse(rawBody);
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const event: any = body?.event ?? {};
  const eventId: string = typeof event?.id === "string" ? event.id : "";
  const eventType: string = typeof event?.type === "string" ? event.type : "";
  if (!eventId || !eventType) {
    return json({ error: "Missing event id/type" }, 400);
  }

  // --- Parse / normalise ---------------------------------------------------
  const appUserId: string = typeof event?.app_user_id === "string" ? event.app_user_id.trim() : "";
  const originalAppUserId: string | null =
    typeof event?.original_app_user_id === "string" ? event.original_app_user_id.trim() : null;
  const aliases: string[] = Array.isArray(event?.aliases)
    ? event.aliases.filter((a: unknown): a is string => typeof a === "string")
    : [];
  const productId: string | null = typeof event?.product_id === "string" ? event.product_id : null;
  const entitlementIds: string[] = Array.isArray(event?.entitlement_ids)
    ? event.entitlement_ids.filter((e: unknown): e is string => typeof e === "string")
    : (typeof event?.entitlement_id === "string" ? [event.entitlement_id] : []);
  const periodType: string | null = typeof event?.period_type === "string" ? event.period_type : null;
  const environmentRaw: string = typeof event?.environment === "string" ? event.environment.toUpperCase() : "UNKNOWN";
  const isSandbox = environmentRaw === "SANDBOX";
  const store: string | null = typeof event?.store === "string" ? event.store : null;
  const eventTimestampIso = msToIso(event?.event_timestamp_ms) ?? new Date().toISOString();
  const purchasedAt = msToIso(event?.purchased_at_ms);
  const originalPurchaseAt = msToIso(event?.original_purchase_at_ms ?? event?.original_purchased_at_ms);
  const expirationAt = msToIso(event?.expiration_at_ms);
  const gracePeriodEnd = msToIso(event?.grace_period_expiration_at_ms);
  const transactionId: string | null = typeof event?.transaction_id === "string" ? event.transaction_id : null;
  const originalTransactionId: string | null =
    typeof event?.original_transaction_id === "string" ? event.original_transaction_id : null;
  const nowIso = new Date().toISOString();

  const mapping = storeMapping(store);
  const payloadHash = await sha256Hex(rawBody);

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  // Candidate canonical user: the App User ID itself, then original id,
  // then any alias that parses as a Supabase UUID.
  const uuidCandidates = [appUserId, originalAppUserId ?? "", ...aliases]
    .filter((v) => UUID_RE.test(v));
  const candidateUserId: string | null = uuidCandidates[0] ?? null;

  // --- 2. Idempotent event record ------------------------------------------
  const { data: insertedEvent, error: logError } = await admin
    .from("billing_provider_events")
    .insert({
      provider: "revenuecat",
      provider_event_id: eventId,
      event_type: eventType,
      environment: environmentRaw,
      app_user_id: appUserId || null,
      original_app_user_id: originalAppUserId,
      aliases: aliases.length > 0 ? aliases : null,
      platform: mapping?.platform ?? "unknown",
      store,
      product_id: productId,
      entitlement_ids: entitlementIds.length > 0 ? entitlementIds : null,
      external_subscription_id: originalTransactionId,
      external_transaction_id: transactionId,
      provider_created_at: eventTimestampIso,
      processing_status: "received",
      payload_hash: payloadHash,
      raw_payload: { event: sanitizePayload(event), api_version: body?.api_version ?? null },
    })
    .select("id")
    .single();

  if (logError || !insertedEvent) {
    if ((logError as any)?.code === "23505") {
      console.log(`[revenuecat-webhook] duplicate event id=${eventId} type=${eventType} (idempotent skip)`);
      return json({ status: "already_processed", eventId });
    }
    console.log(`[revenuecat-webhook] failed to record event id=${eventId}: ${logError?.message}`);
    return json({ error: "Failed to record event" }, 500);
  }
  const eventRowId: string = insertedEvent.id;

  /** Finalise the event row and answer. failed => 500 so RevenueCat retries. */
  async function finalize(
    status: "processed" | "ignored" | "failed" | "needs_review",
    detail: { code?: string; message?: string; resolvedUserId?: string | null; extra?: Record<string, unknown> } = {},
  ): Promise<Response> {
    await admin
      .from("billing_provider_events")
      .update({
        processing_status: status,
        processed_at: new Date().toISOString(),
        processing_error_code: detail.code ?? null,
        processing_error_message: detail.message ?? null,
        resolved_user_id: detail.resolvedUserId ?? null,
      })
      .eq("id", eventRowId);
    console.log(
      `[revenuecat-webhook] id=${eventId} type=${eventType} env=${environmentRaw} -> ${status}` +
        (detail.code ? ` (${detail.code})` : ""),
    );
    if (status === "failed") {
      // Reset to 'received' semantics are unnecessary — retried deliveries
      // hit the duplicate guard; support can re-drive failed rows manually.
      return json({ error: "Processing failed", code: detail.code ?? null }, 500);
    }
    return json({ status, eventId, eventType, ...(detail.extra ?? {}) });
  }

  /** Store lifecycle audit (state changes only; guarded). */
  async function audit(
    userId: string,
    auditEvent: string,
    previous: Record<string, unknown> | null,
    next: Record<string, unknown>,
  ): Promise<void> {
    try {
      await admin.from("vinetrack_entitlement_audit").insert({
        user_id: userId,
        event_type: auditEvent,
        previous_state: previous,
        new_state: { ...next, provider_event_id: eventId },
        platform: "server",
      });
    } catch (_) {
      // Audit must never block webhook processing.
    }
  }

  // --- Informational / non-state events ------------------------------------
  if (eventType === "TEST") {
    return finalize("ignored", { code: "test_event", resolvedUserId: candidateUserId });
  }
  if (eventType === "SUBSCRIBER_ALIAS") {
    // Alias linkage is retained on the event row for audit/recovery; it never
    // changes canonical ownership or duplicates entitlements by itself.
    if (candidateUserId) {
      await audit(candidateUserId, "store_subscription_alias_linked", null, {
        aliases_count: aliases.length,
      });
    }
    return finalize("processed", { code: "alias_recorded", resolvedUserId: candidateUserId });
  }

  // --- 3. Resolve the canonical Supabase user -------------------------------
  if (!candidateUserId) {
    return finalize("needs_review", {
      code: "unresolved_app_user_id",
      message: "No Supabase UUID in app_user_id/original_app_user_id/aliases",
    });
  }
  const { data: userLookup, error: userErr } = await admin.auth.admin.getUserById(candidateUserId);
  if (userErr || !userLookup?.user) {
    return finalize("needs_review", {
      code: "user_not_found",
      message: "App User ID parses as a UUID but no auth.users row exists",
    });
  }
  const resolvedUserId = userLookup.user.id;

  // --- TRANSFER (high-risk; handled after user resolution) ------------------
  if (eventType === "TRANSFER") {
    const from: string[] = Array.isArray(event?.transferred_from)
      ? event.transferred_from.filter((v: unknown): v is string => typeof v === "string" && UUID_RE.test(v as string))
      : [];
    const to: string[] = Array.isArray(event?.transferred_to)
      ? event.transferred_to.filter((v: unknown): v is string => typeof v === "string" && UUID_RE.test(v as string))
      : [];
    if (from.length !== 1 || to.length !== 1) {
      return finalize("needs_review", {
        code: "ambiguous_transfer",
        message: `transferred_from=${from.length} transferred_to=${to.length} resolvable Supabase UUIDs`,
        resolvedUserId,
      });
    }
    // Move ownership of the provider subscription rows; never leave both
    // accounts holding the same purchase.
    const { data: moved, error: moveErr } = await admin
      .from("vinetrack_subscriptions")
      .update({ owner_user_id: to[0], revenuecat_app_user_id: to[0], last_provider_event: "TRANSFER", last_provider_event_at: eventTimestampIso, last_verified_at: nowIso })
      .eq("owner_user_id", from[0])
      .in("billing_provider", ["apple", "google"])
      .is("deleted_at", null)
      .select("id");
    if (moveErr) {
      return finalize("failed", { code: "transfer_update_failed", message: moveErr.message, resolvedUserId });
    }
    // Revoke the old owner's licences under the moved subscriptions and grant the new owner.
    for (const row of moved ?? []) {
      await admin.from("vinetrack_user_licences")
        .update({ status: "revoked", revoked_at: nowIso })
        .eq("subscription_id", row.id)
        .eq("user_id", from[0])
        .eq("status", "active");
      const { data: existingLic } = await admin.from("vinetrack_user_licences")
        .select("id, status").eq("subscription_id", row.id).eq("user_id", to[0])
        .order("created_at", { ascending: false }).limit(1).maybeSingle();
      if (existingLic?.id) {
        if (existingLic.status !== "active") {
          await admin.from("vinetrack_user_licences")
            .update({ status: "active", revoked_at: null, assigned_at: nowIso })
            .eq("id", existingLic.id);
        }
      } else {
        await admin.from("vinetrack_user_licences")
          .insert({ subscription_id: row.id, user_id: to[0], status: "active" });
      }
    }
    await audit(to[0], "store_subscription_transferred", { from_user: from[0] }, {
      to_user: to[0],
      moved_subscriptions: (moved ?? []).length,
    });
    return finalize("processed", { code: "transfer_applied", resolvedUserId: to[0], extra: { moved: (moved ?? []).length } });
  }

  // --- 4. Entitlement gate: production entitlement is exactly 'pro' ---------
  const hasPro = entitlementIds.includes("pro");
  const hasPremiumOnly = !hasPro && entitlementIds.includes("premium");
  if (hasPremiumOnly) {
    await audit(resolvedUserId, "store_subscription_sync_mismatch", null, {
      code: "entitlement_premium_without_pro",
      entitlement_ids: entitlementIds,
      product_id: productId,
    });
    return finalize("needs_review", {
      code: "entitlement_mismatch",
      message: "Event carries entitlement 'premium' but not 'pro' — configuration mismatch, no access granted",
      resolvedUserId,
    });
  }
  if (!hasPro && entitlementIds.length > 0) {
    return finalize("needs_review", {
      code: "unexpected_entitlement",
      message: `Entitlements [${entitlementIds.join(",")}] do not include 'pro'`,
      resolvedUserId,
    });
  }
  // Some lifecycle events (e.g. EXPIRATION) may omit entitlement_ids; the
  // product-catalogue check below still requires a 'pro'-mapped product.

  // --- 5. Store / product mapping -------------------------------------------
  if (!mapping) {
    return finalize("needs_review", {
      code: "unsupported_store",
      message: `Store '${store ?? "unknown"}' is not an Apple/Google store (promotional and web stores are classified deliberately, not treated as paid subscriptions)`,
      resolvedUserId,
    });
  }
  if (!productId) {
    return finalize("needs_review", { code: "missing_product_id", resolvedUserId });
  }

  const { data: catalogRows, error: catErr } = await admin
    .from("billing_product_catalog")
    .select("plan_code, entitlement_id, is_active, environment, platform")
    .eq("provider", "revenuecat")
    .eq("external_product_id", productId)
    .in("platform", [mapping.platform, "any"]);
  if (catErr) {
    return finalize("failed", { code: "catalog_lookup_failed", message: catErr.message, resolvedUserId });
  }
  const envKey = isSandbox ? "sandbox" : "production";
  const catalog = (catalogRows ?? []).find(
    (r: any) => r.is_active && (r.environment === envKey || r.environment === "any"),
  );
  if (!catalog) {
    return finalize("needs_review", {
      code: (catalogRows ?? []).length > 0 ? "inactive_product" : "unknown_product",
      message: `Product '${productId}' has no active ${envKey} mapping in billing_product_catalog — no access granted`,
      resolvedUserId,
    });
  }
  if (catalog.entitlement_id !== "pro") {
    return finalize("needs_review", {
      code: "catalog_entitlement_mismatch",
      message: `Catalogue maps product to entitlement '${catalog.entitlement_id}', expected 'pro'`,
      resolvedUserId,
    });
  }

  // --- 6. Sandbox: store, never grant production access ---------------------
  if (isSandbox) {
    return finalize("ignored", {
      code: "sandbox_not_processed",
      message: "Sandbox events are recorded but never grant production access",
      resolvedUserId,
    });
  }

  // --- 7. Lifecycle + upsert -------------------------------------------------
  const { status, cancelAtPeriodEnd, revokeLicence, auditEvent } = resolveStatus(eventType, periodType);
  if (!status) {
    return finalize("ignored", { code: "informational_event", resolvedUserId });
  }
  if (status === "paused") {
    // SUBSCRIPTION_PAUSED (Play): access ends until resumed.
  }

  const { data: plan, error: planErr } = await admin
    .from("vinetrack_plans")
    .select("id, code")
    .eq("code", catalog.plan_code)
    .maybeSingle();
  if (planErr || !plan) {
    return finalize("failed", {
      code: "plan_lookup_failed",
      message: planErr?.message ?? `plan '${catalog.plan_code}' not found`,
      resolvedUserId,
    });
  }

  // Locate the existing row for THIS provider subscription (original
  // transaction id), falling back to the user's row for this provider.
  let existing: { id: string; owner_user_id: string; last_provider_event_at: string | null; status: string; plan_id: string } | null = null;
  if (originalTransactionId) {
    const { data } = await admin
      .from("vinetrack_subscriptions")
      .select("id, owner_user_id, last_provider_event_at, status, plan_id")
      .eq("billing_provider", mapping.provider)
      .eq("external_subscription_id", originalTransactionId)
      .is("deleted_at", null)
      .maybeSingle();
    existing = data ?? null;
  }
  if (!existing) {
    const { data } = await admin
      .from("vinetrack_subscriptions")
      .select("id, owner_user_id, last_provider_event_at, status, plan_id")
      .eq("owner_user_id", resolvedUserId)
      .eq("billing_provider", mapping.provider)
      .is("deleted_at", null)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    existing = data ?? null;
  }

  // Out-of-order guard: a delayed older event must not overwrite newer state
  // (e.g. an old RENEWAL after an EXPIRATION).
  if (existing?.last_provider_event_at &&
      new Date(eventTimestampIso).getTime() < new Date(existing.last_provider_event_at).getTime()) {
    return finalize("ignored", {
      code: "stale_event",
      message: "Event older than the last processed provider event for this subscription",
      resolvedUserId,
    });
  }

  // One store transaction must not silently attach to an unrelated account.
  if (existing && existing.owner_user_id !== resolvedUserId && originalTransactionId) {
    await audit(resolvedUserId, "store_subscription_sync_mismatch", { owner_user_id: existing.owner_user_id }, {
      code: "ownership_conflict",
      attempted_user: resolvedUserId,
    });
    return finalize("needs_review", {
      code: "ownership_conflict",
      message: "Provider subscription already belongs to a different Supabase user (transfer must arrive via a TRANSFER event)",
      resolvedUserId,
    });
  }

  const isTrial = periodType === "TRIAL" || periodType === "INTRO";
  const subFields: Record<string, unknown> = {
    owner_user_id: resolvedUserId,
    plan_id: plan.id,
    billing_provider: mapping.provider,
    platform: mapping.platform,
    environment: "production",
    status,
    trial_start: isTrial ? purchasedAt : undefined,
    trial_end: isTrial ? expirationAt : undefined,
    current_period_start: purchasedAt ?? undefined,
    current_period_end: expirationAt ?? undefined,
    grace_period_end: eventType === "BILLING_ISSUE" ? gracePeriodEnd : (status === "active" || status === "trialing" ? null : undefined),
    started_at: originalPurchaseAt ?? purchasedAt ?? undefined,
    canceled_at: eventType === "CANCELLATION" ? nowIso : (eventType === "UNCANCELLATION" ? null : undefined),
    expired_at: status === "expired" ? (expirationAt ?? nowIso) : null,
    seats_included: 1,
    revenuecat_app_user_id: appUserId || resolvedUserId,
    revenuecat_entitlement: "pro",
    external_subscription_id: originalTransactionId ?? undefined,
    external_transaction_id: transactionId ?? undefined,
    last_provider_event: eventType,
    last_provider_event_at: eventTimestampIso,
    last_verified_at: nowIso,
  };
  if (cancelAtPeriodEnd !== null) subFields.cancel_at_period_end = cancelAtPeriodEnd;
  // Remove undefined keys (leave existing values untouched on update).
  for (const key of Object.keys(subFields)) {
    if (subFields[key] === undefined) delete subFields[key];
  }

  let subscriptionId: string;
  const previousStatus = existing?.status ?? null;
  if (existing?.id) {
    const { error: updErr } = await admin
      .from("vinetrack_subscriptions")
      .update(subFields)
      .eq("id", existing.id);
    if (updErr) return finalize("failed", { code: "subscription_update_failed", message: updErr.message, resolvedUserId });
    subscriptionId = existing.id;
  } else {
    const { data: created, error: insErr } = await admin
      .from("vinetrack_subscriptions")
      .insert(subFields)
      .select("id")
      .single();
    if (insErr || !created) {
      return finalize("failed", { code: "subscription_insert_failed", message: insErr?.message ?? "no row", resolvedUserId });
    }
    subscriptionId = created.id;
  }

  // --- Licence upsert / revoke ----------------------------------------------
  const { data: licence, error: licErr } = await admin
    .from("vinetrack_user_licences")
    .select("id, status")
    .eq("subscription_id", subscriptionId)
    .eq("user_id", resolvedUserId)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (licErr) return finalize("failed", { code: "licence_lookup_failed", message: licErr.message, resolvedUserId });

  if (revokeLicence) {
    if (licence?.id && licence.status === "active") {
      const { error } = await admin
        .from("vinetrack_user_licences")
        .update({ status: "revoked", revoked_at: nowIso })
        .eq("id", licence.id);
      if (error) return finalize("failed", { code: "licence_revoke_failed", message: error.message, resolvedUserId });
    }
  } else {
    if (licence?.id) {
      if (licence.status !== "active") {
        const { error } = await admin
          .from("vinetrack_user_licences")
          .update({ status: "active", revoked_at: null, assigned_at: nowIso })
          .eq("id", licence.id);
        if (error) return finalize("failed", { code: "licence_reactivate_failed", message: error.message, resolvedUserId });
      }
    } else {
      const { error } = await admin
        .from("vinetrack_user_licences")
        .insert({ subscription_id: subscriptionId, user_id: resolvedUserId, status: "active" });
      if (error) return finalize("failed", { code: "licence_insert_failed", message: error.message, resolvedUserId });
    }
  }

  // --- 8. Audit on state change ----------------------------------------------
  if (auditEvent && previousStatus !== status) {
    await audit(resolvedUserId, auditEvent,
      previousStatus ? { status: previousStatus } : null,
      { status, plan_code: plan.code, provider: mapping.provider, platform: mapping.platform, event_type: eventType });
  }

  return finalize("processed", {
    resolvedUserId,
    extra: { planCode: plan.code, subscriptionStatus: status, provider: mapping.provider },
  });
});
