// Shared sender / provider configuration for all VineTrack email.
//
// Verified Resend domain: send.vinetrack.com.au
// There is deliberately NO fallback to onboarding@resend.dev — if the
// provider key is missing, callers must return:
//   { success: false, email_sent: false, error_code: "email_configuration_missing" }
//
// Required secret (Supabase Edge Function secrets):
//   RESEND_API_KEY
// Optional overrides:
//   EMAIL_FROM_DEFAULT, EMAIL_FROM_INVITES, EMAIL_FROM_SUPPORT,
//   EMAIL_REPLY_TO, SUPPORT_TO_EMAIL, RESEND_WEBHOOK_SECRET

export const SENDER_DOMAIN = "send.vinetrack.com.au";

export const FROM_DEFAULT = Deno.env.get("EMAIL_FROM_DEFAULT") ??
  `VineTrack <notifications@${SENDER_DOMAIN}>`;

export const FROM_INVITES = Deno.env.get("EMAIL_FROM_INVITES") ??
  `VineTrack Invitations <invites@${SENDER_DOMAIN}>`;

export const FROM_SUPPORT = Deno.env.get("EMAIL_FROM_SUPPORT") ??
  `VineTrack Support <support@${SENDER_DOMAIN}>`;

export const REPLY_TO = Deno.env.get("EMAIL_REPLY_TO") ??
  "support@vinetrack.com.au";

/** VineTrack staff inbox for support notifications. */
export const SUPPORT_TO_EMAIL = Deno.env.get("SUPPORT_TO_EMAIL") ??
  "jonathan@stockmansridge.com.au";

/** Returns the Resend API key, or null when email is unconfigured. */
export function resendApiKey(): string | null {
  const key = (Deno.env.get("RESEND_API_KEY") ?? "").trim();
  return key.length > 0 ? key : null;
}

/** Standard "email is not configured" response body (HTTP 200 — the durable
 * DB write already succeeded; only delivery is unavailable). */
export function configurationMissingBody(): Record<string, unknown> {
  return {
    success: false,
    email_sent: false,
    error_code: "email_configuration_missing",
    // Legacy field kept so existing mobile builds keep parsing correctly.
    emailStatus: "unconfigured",
  };
}
