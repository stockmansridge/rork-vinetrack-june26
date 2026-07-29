// Supabase Edge Function: stripe-webhook   (Phase 2E — Owner portal billing)
//
// Receives Stripe webhook events, verifies the Stripe signature, and keeps
// VineTrack's trusted billing records in sync:
//   * vinetrack_subscriptions  — Stripe subscription lifecycle (status,
//     period windows, cancel-at-period-end). Subscription state remains the
//     entitlement source; invoice existence NEVER grants access.
//   * vinetrack_invoice_records — invoice metadata upserted by Stripe
//     invoice ID (integer minor units / cents). Hosted/PDF URLs are NOT
//     stored for customer use — the portal mints fresh links on demand via
//     get-stripe-invoice-link.
//   * billing_provider_events   — idempotent inbox (provider='stripe',
//     UNIQUE (provider, provider_event_id)). Duplicate deliveries return
//     200 "already_processed"; failures mark the row 'failed' so Stripe
//     retries reprocess safely; unmatched customers go to 'needs_review'
//     (Billing Review) and raise a billing_admin_alerts row.
//
// Access rules encoded here:
//   * payment_failed does NOT revoke access (subscription.updated carries
//     past_due; grace handling stays in the resolver).
//   * cancel_at_period_end keeps access until current_period_end.
//   * refunds / voids / credit notes update invoice records accurately but
//     never delete billing evidence.
//   * out-of-order events (older than the stored last event timestamp) are
//     recorded but do not overwrite newer subscription state.
//
// Required environment (Supabase function secrets):
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY  (auto-provided)
//   STRIPE_WEBHOOK_SECRET   signing secret of the Stripe webhook endpoint
//
// Deploy with: supabase functions deploy stripe-webhook --no-verify-jwt
// (Stripe cannot send a Supabase JWT; the Stripe signature is the auth.)

// deno-lint-ignore-file no-explicit-any

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

const SIGNATURE_TOLERANCE_SECONDS = 5 * 60;

/** Constant-time hex comparison. */
function timingSafeEqualHex(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** Verify a Stripe-Signature header against the raw body. */
async function verifyStripeSignature(
  rawBody: string,
  header: string | null,
  secret: string,
): Promise<{ ok: boolean; reason?: string }> {
  if (!header) return { ok: false, reason: "missing_signature" };
  const parts = new Map<string, string[]>();
  for (const piece of header.split(",")) {
    const idx = piece.indexOf("=");
    if (idx <= 0) continue;
    const k = piece.slice(0, idx).trim();
    const v = piece.slice(idx + 1).trim();
    const arr = parts.get(k) ?? [];
    arr.push(v);
    parts.set(k, arr);
  }
  const t = parts.get("t")?.[0];
  const v1s = parts.get("v1") ?? [];
  if (!t || v1s.length === 0) return { ok: false, reason: "malformed_signature" };

  const ts = Number(t);
  if (!Number.isFinite(ts)) return { ok: false, reason: "malformed_timestamp" };
  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - ts) > SIGNATURE_TOLERANCE_SECONDS) {
    return { ok: false, reason: "timestamp_out_of_tolerance" };
  }

  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(`${t}.${rawBody}`));
  const expected = Array.from(new Uint8Array(mac))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  for (const v1 of v1s) {
    if (timingSafeEqualHex(expected, v1.toLowerCase())) return { ok: true };
  }
  return { ok: false, reason: "signature_mismatch" };
}

function toIso(unixSeconds: unknown): string | null {
  const n = Number(unixSeconds);
  if (!Number.isFinite(n) || n <= 0) return null;
  return new Date(n * 1000).toISOString();
}

/** Map a Stripe subscription status onto vinetrack_subscriptions.status. */
function mapSubscriptionStatus(stripeStatus: string): string {
  switch (stripeStatus) {
    case "active": return "active";
    case "trialing": return "trialing";
    case "past_due":
    case "unpaid": return "past_due";
    case "canceled": return "canceled";
    case "paused": return "paused";
    case "incomplete":
    case "incomplete_expired": return "expired";
    default: return "expired";
  }
}

/** Map a Stripe invoice status onto vinetrack_invoice_records.status. */
function mapInvoiceStatus(stripeStatus: string | null | undefined): string {
  switch (stripeStatus) {
    case "draft": return "draft";
    case "open": return "open";
    case "paid": return "paid";
    case "void": return "void";
    case "uncollectible": return "uncollectible";
    default: return "open";
  }
}

/** Slim, receipt-free payload summary for the audit inbox. */
function slimPayload(event: any): Record<string, unknown> {
  const obj = event?.data?.object ?? {};
  return {
    event_type: event?.type ?? null,
    livemode: event?.livemode ?? null,
    object: obj?.object ?? null,
    id: obj?.id ?? null,
    customer: obj?.customer ?? null,
    subscription: obj?.subscription ?? obj?.id ?? null,
    status: obj?.status ?? null,
    amounts: {
      subtotal: obj?.subtotal ?? null,
      tax: obj?.tax ?? null,
      total: obj?.total ?? null,
      amount_paid: obj?.amount_paid ?? null,
      amount_due: obj?.amount_due ?? null,
      amount_refunded: obj?.amount_refunded ?? null,
    },
  };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";
  if (!supabaseUrl || !serviceRoleKey) return json({ error: "server_misconfigured" }, 500);
  // Fail closed: never process unsigned events.
  if (!webhookSecret) {
    console.error("stripe-webhook: STRIPE_WEBHOOK_SECRET not configured — rejecting");
    return json({ error: "webhook_not_configured" }, 500);
  }

  const rawBody = await req.text();
  const sig = await verifyStripeSignature(rawBody, req.headers.get("Stripe-Signature"), webhookSecret);
  if (!sig.ok) {
    console.error(`stripe-webhook: signature rejected (${sig.reason})`);
    return json({ error: "invalid_signature" }, 401);
  }

  let event: any;
  try {
    event = JSON.parse(rawBody);
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const eventId: string | undefined = event?.id;
  const eventType: string | undefined = event?.type;
  if (!eventId || !eventType) return json({ error: "invalid_event" }, 400);

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const environment = event?.livemode === true ? "PRODUCTION" : "SANDBOX";
  const obj: any = event?.data?.object ?? {};

  // ---- 1. Idempotent inbox insert (UNIQUE provider+event id). -------------
  const { data: inserted, error: insertErr } = await admin
    .from("billing_provider_events")
    .insert({
      provider: "stripe",
      provider_event_id: eventId,
      event_type: eventType,
      environment,
      external_subscription_id:
        typeof obj?.subscription === "string" ? obj.subscription
        : obj?.object === "subscription" ? obj?.id ?? null
        : null,
      provider_created_at: toIso(event?.created),
      processing_status: "received",
      raw_payload: slimPayload(event),
    })
    .select("id")
    .single();

  if (insertErr) {
    if ((insertErr as any).code === "23505") {
      return json({ status: "already_processed", event_id: eventId }, 200);
    }
    console.error("stripe-webhook: inbox insert failed", insertErr.message);
    return json({ error: "inbox_insert_failed" }, 500);
  }
  const inboxId = inserted.id as string;

  async function finish(status: string, code?: string, message?: string) {
    await admin
      .from("billing_provider_events")
      .update({
        processing_status: status,
        processed_at: new Date().toISOString(),
        processing_error_code: code ?? null,
        processing_error_message: message ? message.slice(0, 500) : null,
      })
      .eq("id", inboxId);
  }

  async function raiseReviewAlert(detail: string) {
    // UNIQUE (alert_type, provider_event_id) makes this spam-proof.
    await admin
      .from("billing_admin_alerts")
      .upsert(
        {
          alert_type: "event_needs_review",
          severity: "warning",
          provider: "stripe",
          provider_event_id: eventId,
          event_type: eventType,
          detail: detail.slice(0, 500),
        },
        { onConflict: "alert_type,provider_event_id", ignoreDuplicates: true },
      );
  }

  /** Find our subscription row by Stripe subscription id, then customer id. */
  async function findSubscription(stripeSubId: string | null, stripeCustomerId: string | null) {
    if (stripeSubId) {
      const { data } = await admin
        .from("vinetrack_subscriptions")
        .select("id, owner_user_id, primary_vineyard_id, status, stripe_customer_id, metadata")
        .eq("billing_provider", "stripe")
        .eq("stripe_subscription_id", stripeSubId)
        .is("deleted_at", null)
        .maybeSingle();
      if (data) return data;
    }
    if (stripeCustomerId) {
      const { data } = await admin
        .from("vinetrack_subscriptions")
        .select("id, owner_user_id, primary_vineyard_id, status, stripe_customer_id, metadata")
        .eq("billing_provider", "stripe")
        .eq("stripe_customer_id", stripeCustomerId)
        .is("deleted_at", null)
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle();
      if (data) return data;
    }
    return null;
  }

  try {
    // ---- 2. Customer bookkeeping (log only — no auto-linking by email). ---
    if (eventType === "customer.created" || eventType === "customer.updated") {
      await finish("processed");
      return json({ status: "processed", event_id: eventId }, 200);
    }

    // ---- 3. Subscription lifecycle. ---------------------------------------
    if (
      eventType === "customer.subscription.created" ||
      eventType === "customer.subscription.updated" ||
      eventType === "customer.subscription.deleted"
    ) {
      const stripeSubId: string | null = obj?.id ?? null;
      const stripeCustomerId: string | null =
        typeof obj?.customer === "string" ? obj.customer : null;

      const sub = await findSubscription(stripeSubId, stripeCustomerId);
      if (!sub) {
        // Never create subscriptions (and therefore access) from a webhook
        // alone — creation happens in the checkout flow / admin actions.
        await raiseReviewAlert(
          `Stripe ${eventType} for unmatched subscription ${stripeSubId ?? "?"} / customer ${stripeCustomerId ?? "?"}`,
        );
        await finish("needs_review", "unmatched_subscription");
        return json({ status: "needs_review", event_id: eventId }, 200);
      }

      // Out-of-order guard (kept in metadata to stay schema-additive).
      const lastTs = Number((sub.metadata as any)?.stripe_last_event_ts ?? 0);
      const thisTs = Number(event?.created ?? 0);
      if (Number.isFinite(lastTs) && lastTs > 0 && thisTs > 0 && thisTs < lastTs) {
        await finish("ignored", "stale_event");
        return json({ status: "ignored_stale", event_id: eventId }, 200);
      }

      const item = obj?.items?.data?.[0] ?? null;
      const mappedStatus =
        eventType === "customer.subscription.deleted"
          ? "canceled"
          : mapSubscriptionStatus(String(obj?.status ?? ""));

      const update: Record<string, unknown> = {
        status: mappedStatus,
        stripe_subscription_id: stripeSubId ?? undefined,
        stripe_customer_id: stripeCustomerId ?? sub.stripe_customer_id ?? undefined,
        current_period_start:
          toIso(obj?.current_period_start ?? item?.current_period_start) ?? undefined,
        current_period_end:
          toIso(obj?.current_period_end ?? item?.current_period_end) ?? undefined,
        cancel_at_period_end: Boolean(obj?.cancel_at_period_end ?? false),
        canceled_at: toIso(obj?.canceled_at),
        trial_end: toIso(obj?.trial_end) ?? undefined,
        last_provider_event: eventType,
        last_provider_event_at: toIso(event?.created),
        last_verified_at: new Date().toISOString(),
        metadata: { ...(sub.metadata as any ?? {}), stripe_last_event_ts: thisTs },
      };
      // Strip undefined keys so we never null-out existing values.
      for (const k of Object.keys(update)) {
        if (update[k] === undefined) delete update[k];
      }

      const { error: updErr } = await admin
        .from("vinetrack_subscriptions")
        .update(update)
        .eq("id", sub.id);
      if (updErr) throw new Error(`subscription update failed: ${updErr.message}`);

      await finish("processed");
      return json({ status: "processed", event_id: eventId }, 200);
    }

    // ---- 4. Invoice lifecycle (upsert by Stripe invoice id). --------------
    if (
      eventType === "invoice.created" ||
      eventType === "invoice.finalized" ||
      eventType === "invoice.paid" ||
      eventType === "invoice.payment_failed" ||
      eventType === "invoice.voided" ||
      eventType === "invoice.marked_uncollectible"
    ) {
      const invoiceId: string | null = obj?.id ?? null;
      if (!invoiceId) {
        await finish("failed", "missing_invoice_id");
        return json({ error: "missing_invoice_id" }, 400);
      }
      const stripeCustomerId: string | null =
        typeof obj?.customer === "string" ? obj.customer : null;
      const stripeSubId: string | null =
        typeof obj?.subscription === "string" ? obj.subscription
        : typeof obj?.parent?.subscription_details?.subscription === "string"
          ? obj.parent.subscription_details.subscription
          : null;

      const sub = await findSubscription(stripeSubId, stripeCustomerId);

      const line = obj?.lines?.data?.[0] ?? null;
      const record: Record<string, unknown> = {
        provider: "stripe",
        external_invoice_id: invoiceId,
        external_customer_id: stripeCustomerId,
        external_subscription_id: stripeSubId,
        subscription_id: sub?.id ?? null,
        owner_user_id: sub?.owner_user_id ?? null,
        vineyard_id: sub?.primary_vineyard_id ?? null,
        invoice_number: obj?.number ?? null,
        status: mapInvoiceStatus(obj?.status),
        currency: String(obj?.currency ?? "aud").toUpperCase(),
        subtotal_cents: Number.isFinite(Number(obj?.subtotal)) ? Number(obj.subtotal) : null,
        tax_cents: Number.isFinite(Number(obj?.tax)) ? Number(obj.tax) : null,
        total_cents: Number.isFinite(Number(obj?.total)) ? Number(obj.total) : null,
        amount_paid_cents: Number.isFinite(Number(obj?.amount_paid)) ? Number(obj.amount_paid) : null,
        amount_due_cents: Number.isFinite(Number(obj?.amount_due)) ? Number(obj.amount_due) : null,
        period_start: toIso(line?.period?.start ?? obj?.period_start),
        period_end: toIso(line?.period?.end ?? obj?.period_end),
        issued_at: toIso(obj?.created),
        due_at: toIso(obj?.due_date),
        paid_at: toIso(obj?.status_transitions?.paid_at),
        voided_at: toIso(obj?.status_transitions?.voided_at),
        description: obj?.description ?? line?.description ?? null,
        last_synced_at: new Date().toISOString(),
      };

      // Manual select-then-write (the unique index on
      // (provider, external_invoice_id) is partial, so PostgREST upsert
      // conflict inference cannot be used).
      const { data: existing } = await admin
        .from("vinetrack_invoice_records")
        .select("id")
        .eq("provider", "stripe")
        .eq("external_invoice_id", invoiceId)
        .maybeSingle();

      if (existing) {
        const { error: updErr } = await admin
          .from("vinetrack_invoice_records")
          .update(record)
          .eq("id", existing.id);
        if (updErr) throw new Error(`invoice update failed: ${updErr.message}`);
      } else {
        const { error: insErr } = await admin
          .from("vinetrack_invoice_records")
          .insert(record);
        if (insErr && (insErr as any).code === "23505") {
          const { error: retryErr } = await admin
            .from("vinetrack_invoice_records")
            .update(record)
            .eq("provider", "stripe")
            .eq("external_invoice_id", invoiceId);
          if (retryErr) throw new Error(`invoice upsert retry failed: ${retryErr.message}`);
        } else if (insErr) {
          throw new Error(`invoice insert failed: ${insErr.message}`);
        }
      }

      if (!sub) {
        // Invoice stored as evidence but unlinked — needs review. Invoice
        // existence never grants access, so this is safe.
        await raiseReviewAlert(
          `Stripe ${eventType} for unmatched customer ${stripeCustomerId ?? "?"} (invoice ${invoiceId})`,
        );
        await finish("needs_review", "unmatched_customer");
        return json({ status: "needs_review", event_id: eventId }, 200);
      }

      // payment_failed: record only. Access changes arrive via
      // customer.subscription.updated (past_due) and the resolver's grace
      // rules — never revoke prematurely here.
      await finish("processed");
      return json({ status: "processed", event_id: eventId }, 200);
    }

    // ---- 5. Refunds. -------------------------------------------------------
    if (eventType === "charge.refunded") {
      const invoiceId: string | null =
        typeof obj?.invoice === "string" ? obj.invoice : null;
      if (!invoiceId) {
        await finish("ignored", "charge_without_invoice");
        return json({ status: "ignored", event_id: eventId }, 200);
      }
      const refunded = Number(obj?.amount_refunded ?? 0);
      const captured = Number(obj?.amount_captured ?? obj?.amount ?? 0);
      const fully = captured > 0 && refunded >= captured;

      const patch: Record<string, unknown> = {
        refunded_at: new Date().toISOString(),
        last_synced_at: new Date().toISOString(),
        metadata_safe: { refunded_cents: refunded, fully_refunded: fully },
      };
      if (fully) patch.status = "refunded";

      const { error: refErr } = await admin
        .from("vinetrack_invoice_records")
        .update(patch)
        .eq("provider", "stripe")
        .eq("external_invoice_id", invoiceId);
      if (refErr) throw new Error(`refund update failed: ${refErr.message}`);

      await finish("processed");
      return json({ status: "processed", event_id: eventId }, 200);
    }

    // ---- 6. Credit notes. ---------------------------------------------------
    if (eventType === "credit_note.created") {
      const invoiceId: string | null =
        typeof obj?.invoice === "string" ? obj.invoice : null;
      if (!invoiceId) {
        await finish("ignored", "credit_note_without_invoice");
        return json({ status: "ignored", event_id: eventId }, 200);
      }
      const { error: cnErr } = await admin
        .from("vinetrack_invoice_records")
        .update({
          metadata_safe: {
            credit_note_id: obj?.id ?? null,
            credit_note_total_cents: Number(obj?.total ?? 0),
            credit_note_reason: obj?.reason ?? null,
          },
          refunded_at: new Date().toISOString(),
          last_synced_at: new Date().toISOString(),
        })
        .eq("provider", "stripe")
        .eq("external_invoice_id", invoiceId);
      if (cnErr) throw new Error(`credit note update failed: ${cnErr.message}`);

      await finish("processed");
      return json({ status: "processed", event_id: eventId }, 200);
    }

    // ---- 7. Everything else: stored, ignored. ------------------------------
    await finish("ignored", "unhandled_event_type");
    return json({ status: "ignored", event_id: eventId }, 200);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("stripe-webhook: processing failed", message);
    await finish("failed", "processing_error", message);
    // 500 → Stripe retries; the inbox row lets the retry reprocess safely.
    return json({ error: "processing_failed", event_id: eventId }, 500);
  }
});
