// Shared Resend API client with consistent error parsing.
//
// This is the ONLY place VineTrack talks to the Resend HTTP API for
// application email. No iOS / Android / portal frontend may call Resend
// directly, and no other edge function should fetch api.resend.com itself.

import { resendApiKey } from "./config.ts";
import type { SendEmailRequest, SendEmailResult } from "./types.ts";

const RESEND_ENDPOINT = "https://api.resend.com/emails";

/**
 * Sends one email through Resend.
 *
 * Never throws — always resolves to a SendEmailResult so callers can record
 * an honest delivery status. `providerId` is the Resend message id used to
 * correlate webhook delivery events later.
 */
export async function sendEmail(
  request: SendEmailRequest,
): Promise<SendEmailResult> {
  const apiKey = resendApiKey();
  if (!apiKey) {
    return {
      ok: false,
      providerId: null,
      errorCode: "email_configuration_missing",
      errorDetail: "RESEND_API_KEY is not configured",
    };
  }

  const to = request.to.trim().toLowerCase();
  if (!to.includes("@")) {
    return {
      ok: false,
      providerId: null,
      errorCode: "invalid_recipient",
      errorDetail: "Recipient is not a valid email address",
    };
  }

  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    "Authorization": `Bearer ${apiKey}`,
  };
  if (request.idempotencyKey) {
    headers["Idempotency-Key"] = request.idempotencyKey;
  }

  try {
    const res = await fetch(RESEND_ENDPOINT, {
      method: "POST",
      headers,
      body: JSON.stringify({
        from: request.from,
        to: [to],
        reply_to: request.replyTo || undefined,
        subject: request.subject,
        html: request.html,
      }),
    });

    if (!res.ok) {
      const text = await res.text();
      return {
        ok: false,
        providerId: null,
        errorCode: "provider_rejected",
        errorDetail: `Resend HTTP ${res.status}: ${text.slice(0, 300)}`,
      };
    }

    // deno-lint-ignore no-explicit-any
    const data: any = await res.json();
    const providerId = typeof data?.id === "string" ? data.id : null;
    return { ok: true, providerId, errorCode: null, errorDetail: null };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return {
      ok: false,
      providerId: null,
      errorCode: "provider_unreachable",
      errorDetail: message.slice(0, 300),
    };
  }
}
