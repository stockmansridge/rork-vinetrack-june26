// Supabase Edge Function: send-invitation-email
//
// Emails a vineyard team invitation to the invited address via the shared
// Resend email module (supabase/functions/_shared/email/). Used by iOS,
// Android and the Lovable portal — for both NEW invitations
// (create_invitation → here) and RESENDS (resend_invitation → here).
//
// The clients own the DURABLE path: they call the `create_invitation` /
// `resend_invitation` RPCs first (owner/manager enforced server-side), so the
// invitation row always exists before this function runs. This function only
// handles the best-effort email notification — the invitee can always accept
// in-app by signing in with the invited email, even if delivery fails. The
// invitation is NEVER modified or deleted here, so a failed email preserves
// the invitation.
//
// Request (POST JSON):
//   {
//     "invitation_id": "uuid",              // canonical
//     "source_platform"?: "ios" | "android" | "portal" | "portal_diagnostics",
//     "context"?: "new" | "resend"          // delivery-log context only
//   }
//   Legacy aliases still accepted: invitationId, sourcePlatform.
//   Invalid source_platform values are normalised to "unknown".
//   source_platform is ONLY recorded in email_delivery_events — it never
//   affects authorisation.
//
// Authorization: the caller must be authenticated AND owner/manager of the
// invitation's vineyard (checked via public.has_vineyard_role with the
// caller's JWT). Unknown invitation ids return 404; known-but-unauthorised
// return 403.
//
// HTTP 200 — invitation loaded, email accepted by Resend:
//   { success: true, email_sent: true, invitation_id, recipient_email,
//     provider: "resend", provider_message_id, email_event_id, submitted_at }
//
// HTTP 200 — invitation valid but delivery failed (invitation preserved):
//   { success: true, email_sent: false, invitation_id, recipient_email,
//     email_event_id, error_code: "email_send_failed",
//     message: "The invitation remains active, but the email could not be sent." }
//
// Function-level failures (non-200) use stable error codes:
//   401 unauthenticated · 403 permission_denied · 400/422 invalid_request ·
//   404 invitation_not_found · 409 invitation_not_pending ·
//   500 email_configuration_missing
//
// Raw Resend payloads are never returned. Legacy fields `emailStatus` and
// `providerId` are kept so existing mobile builds keep parsing correctly.
//
// Required secret: RESEND_API_KEY. Sender defaults come from the shared
// config (verified domain send.vinetrack.com.au) — there is NO fallback to
// onboarding@resend.dev.

// deno-lint-ignore-file no-explicit-any

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { sendEmail } from "../_shared/email/client.ts";
import { FROM_INVITES, REPLY_TO, resendApiKey } from "../_shared/email/config.ts";
import { logSendOutcome, logSubmitted } from "../_shared/email/logging.ts";
import {
  invitationSubject,
  renderInvitationEmail,
} from "../_shared/email/templates/invitation.ts";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const ALLOWED_SOURCE_PLATFORMS = [
  "ios",
  "android",
  "portal",
  "portal_diagnostics",
] as const;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function failure(
  errorCode: string,
  message: string,
  status: number,
): Response {
  return json(
    {
      success: false,
      email_sent: false,
      error_code: errorCode,
      message,
      // Legacy field kept for existing mobile builds.
      emailStatus: errorCode === "email_configuration_missing"
        ? "unconfigured"
        : "failed",
      error: message,
    },
    status,
  );
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return failure("invalid_request", "Method not allowed", 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return failure(
      "invalid_request",
      "Server is missing Supabase configuration",
      500,
    );
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return failure("unauthenticated", "Missing Authorization header", 401);
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return failure("invalid_request", "Invalid JSON body", 400);
  }

  // Canonical snake_case with camelCase legacy alias.
  const invitationId =
    typeof body?.invitation_id === "string" && body.invitation_id.trim()
      ? body.invitation_id.trim()
      : typeof body?.invitationId === "string"
      ? body.invitationId.trim()
      : "";
  if (!invitationId) {
    return failure("invalid_request", "Missing invitation_id", 400);
  }

  const rawPlatform = typeof body?.source_platform === "string"
    ? body.source_platform
    : typeof body?.sourcePlatform === "string"
    ? body.sourcePlatform
    : "";
  const sourcePlatform = (ALLOWED_SOURCE_PLATFORMS as readonly string[])
      .includes(rawPlatform)
    ? rawPlatform
    : "unknown";
  const sendContext = body?.context === "resend" ? "resend" : "new";

  // Caller-scoped client — used for authentication and the explicit
  // owner/manager permission check (has_vineyard_role runs as the caller).
  const userClient = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false },
    global: { headers: { Authorization: authHeader } },
  });

  const { data: userData, error: userError } = await userClient.auth.getUser();
  const actorUserId: string | null = userData?.user?.id ?? null;
  if (userError || !actorUserId) {
    return failure("unauthenticated", "Invalid or expired session", 401);
  }

  // Service-role client: invitation lookup (so 404 vs 403 are distinct),
  // inviter display name, and delivery-event logging.
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  const { data: invitation, error: loadError } = await admin
    .from("invitations")
    .select(
      "id, vineyard_id, email, role, status, expires_at, invited_by, vineyards(name)",
    )
    .eq("id", invitationId)
    .maybeSingle();

  if (loadError) {
    return failure("invalid_request", "Could not load invitation", 500);
  }
  if (!invitation) {
    return failure("invitation_not_found", "Invitation not found", 404);
  }

  // Explicit permission check: caller must be owner or manager of the
  // invitation's vineyard. source_platform never affects this.
  const { data: canManage, error: roleError } = await userClient.rpc(
    "has_vineyard_role",
    {
      p_vineyard_id: invitation.vineyard_id,
      allowed_roles: ["owner", "manager"],
    },
  );
  if (roleError || canManage !== true) {
    return failure(
      "permission_denied",
      "You do not have permission to manage this vineyard's invitations",
      403,
    );
  }

  if (invitation.status !== "pending") {
    return failure(
      "invitation_not_pending",
      "Invitation is no longer pending",
      409,
    );
  }

  const toEmail = String(invitation.email ?? "").trim().toLowerCase();
  if (!toEmail || !toEmail.includes("@")) {
    return failure("invalid_request", "Invitation has no valid email", 422);
  }

  if (!resendApiKey()) {
    console.log(
      `[send-invitation-email] id=${invitationId} emailStatus=unconfigured (no RESEND_API_KEY)`,
    );
    return failure(
      "email_configuration_missing",
      "Email delivery is not configured",
      500,
    );
  }

  let inviterName = "A vineyard manager";
  if (invitation.invited_by) {
    const { data: inviter } = await admin
      .from("profiles")
      .select("full_name, email")
      .eq("id", invitation.invited_by)
      .maybeSingle();
    const name = String(inviter?.full_name ?? "").trim();
    const email = String(inviter?.email ?? "").trim();
    if (name) inviterName = name;
    else if (email) inviterName = email;
  }

  const vineyardName =
    String((invitation as any).vineyards?.name ?? "").trim() || "a vineyard";
  const role = String(invitation.role ?? "member");
  const roleLabel = role.charAt(0).toUpperCase() + role.slice(1);

  // Each send attempt (new or resend) gets its own delivery-event row.
  const eventId = await logSubmitted(admin, {
    emailType: "invitation",
    recipientEmail: toEmail,
    sourcePlatform,
    actorUserId,
    metadata: {
      invitation_id: invitationId,
      vineyard_id: invitation.vineyard_id,
      role,
      context: sendContext,
      template: "invitation",
    },
  });

  const result = await sendEmail({
    from: FROM_INVITES,
    to: toEmail,
    replyTo: REPLY_TO,
    subject: invitationSubject(vineyardName),
    html: renderInvitationEmail({
      inviterName,
      vineyardName,
      roleLabel,
      inviteeEmail: toEmail,
      expiresAt: invitation.expires_at ?? null,
    }),
    // One idempotency key per invitation + delivery event, so a network retry
    // of the SAME attempt cannot double-send, while explicit resends (new
    // event row) still go out.
    idempotencyKey: eventId ? `invitation/${invitationId}/${eventId}` : undefined,
  });

  await logSendOutcome(admin, eventId, result);

  if (!result.ok) {
    console.log(
      `[send-invitation-email] id=${invitationId} emailStatus=failed ${result.errorCode}: ${result.errorDetail}`,
    );
    // 200: the invitation itself is safely stored and remains active —
    // clients must preserve the successful invitation outcome.
    return json({
      success: true,
      email_sent: false,
      invitation_id: invitationId,
      recipient_email: toEmail,
      email_event_id: eventId,
      error_code: "email_send_failed",
      message: "The invitation remains active, but the email could not be sent.",
      // Legacy field kept for existing mobile builds.
      emailStatus: "failed",
    });
  }

  console.log(
    `[send-invitation-email] id=${invitationId} to=${toEmail} context=${sendContext} emailStatus=sent providerId=${result.providerId ?? "-"}`,
  );
  return json({
    success: true,
    email_sent: true,
    invitation_id: invitationId,
    recipient_email: toEmail,
    provider: "resend",
    provider_message_id: result.providerId,
    email_event_id: eventId,
    submitted_at: new Date().toISOString(),
    // Legacy fields kept for existing mobile builds.
    emailStatus: "sent",
    providerId: result.providerId,
  });
});
