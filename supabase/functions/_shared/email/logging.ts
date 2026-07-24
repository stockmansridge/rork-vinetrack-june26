// Shared delivery-event logging into public.email_delivery_events.
//
// Only service-role clients may write here (the table has no client
// insert/update policies). Never log tokens, confirmation links, full HTML,
// or API keys — metadata is small structured context only.

// deno-lint-ignore-file no-explicit-any

import type { DeliveryLogContext, SendEmailResult } from "./types.ts";

/**
 * Inserts a `submitted` delivery event and returns its id (or null if the
 * insert fails — logging must never break email delivery).
 */
export async function logSubmitted(
  admin: any,
  context: DeliveryLogContext,
): Promise<string | null> {
  try {
    const { data, error } = await admin
      .from("email_delivery_events")
      .insert({
        email_type: context.emailType,
        recipient_email: context.recipientEmail.trim().toLowerCase(),
        source_platform: context.sourcePlatform || "unknown",
        actor_user_id: context.actorUserId,
        provider: "resend",
        status: "submitted",
        metadata: context.metadata ?? {},
      })
      .select("id")
      .single();
    if (error) {
      console.log(`[email-log] insert failed: ${error.message}`);
      return null;
    }
    return typeof data?.id === "string" ? data.id : null;
  } catch (err) {
    console.log(`[email-log] insert threw: ${String(err)}`);
    return null;
  }
}

/** Updates a delivery event with the provider send outcome. */
export async function logSendOutcome(
  admin: any,
  eventId: string | null,
  result: SendEmailResult,
): Promise<void> {
  if (!eventId) return;
  try {
    const { error } = await admin
      .from("email_delivery_events")
      .update({
        status: result.ok ? "sent" : "failed",
        provider_message_id: result.providerId,
        error_code: result.ok
          ? null
          : (result.errorCode ?? "provider_rejected"),
        sent_at: result.ok ? new Date().toISOString() : null,
      })
      .eq("id", eventId);
    if (error) {
      console.log(`[email-log] update failed: ${error.message}`);
    }
  } catch (err) {
    console.log(`[email-log] update threw: ${String(err)}`);
  }
}
