// Supabase Edge Function: send-invitation-email
//
// Emails a vineyard team invitation to the invited address via the shared
// Resend email module (supabase/functions/_shared/email/). Used by iOS,
// Android and the Lovable portal — for both NEW invitations
// (create_invitation → here) and RESENDS (resend_invitation → here).
//
// The apps are responsible for the DURABLE path: they call the
// `create_invitation` / `resend_invitation` RPCs first (owner/manager
// enforced server-side), so the invitation row always exists before this
// function runs. This function only handles the best-effort email
// notification — the invitee can always accept in-app by signing in with the
// invited email, even if delivery fails. The invitation is NEVER modified or
// deleted here, so a failed email preserves the invitation.
//
// Authorization: the caller's JWT is forwarded to PostgREST, so RLS decides
// whether the caller may see the invitation (owner/manager of the vineyard or
// the invitee). Unknown/foreign invitation ids return 404.
//
// Request (POST JSON):
//   {
//     "invitationId": string (uuid),
//     "sourcePlatform"?: "ios" | "android" | "portal",   // for delivery log
//     "context"?: "new" | "resend"                        // for delivery log
//   }
//
// Response 200 JSON:
//   {
//     success: boolean,          // invitation loaded + email accepted by provider
//     email_sent: boolean,
//     error_code?: string,       // e.g. "email_configuration_missing"
//     emailStatus: "sent" | "failed" | "unconfigured",  // legacy field
//     providerId?: string
//   }
//
// Errors return { error: string } with appropriate HTTP status.
//
// Required secret: RESEND_API_KEY. Sender defaults come from the shared
// config (verified domain send.vinetrack.com.au) — there is NO fallback to
// onboarding@resend.dev.

// deno-lint-ignore-file no-explicit-any

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { sendEmail } from "../_shared/email/client.ts";
import {
  configurationMissingBody,
  FROM_INVITES,
  REPLY_TO,
  resendApiKey,
} from "../_shared/email/config.ts";
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

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return json({ error: "Server is missing Supabase configuration" }, 500);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return json({ error: "Missing Authorization header" }, 401);
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const invitationId = typeof body?.invitationId === "string"
    ? body.invitationId.trim()
    : "";
  if (!invitationId) {
    return json({ error: "Missing invitationId" }, 400);
  }
  const sourcePlatform = typeof body?.sourcePlatform === "string" &&
      ["ios", "android", "portal"].includes(body.sourcePlatform)
    ? body.sourcePlatform
    : "unknown";
  const sendContext = body?.context === "resend" ? "resend" : "new";

  // Caller-scoped client: RLS decides whether this user may see the
  // invitation (vineyard owner/manager or the invitee themselves).
  const userClient = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false },
    global: { headers: { Authorization: authHeader } },
  });

  const { data: userData } = await userClient.auth.getUser();
  const actorUserId: string | null = userData?.user?.id ?? null;

  const { data: invitation, error: loadError } = await userClient
    .from("invitations")
    .select(
      "id, vineyard_id, email, role, status, expires_at, invited_by, vineyards(name)",
    )
    .eq("id", invitationId)
    .maybeSingle();

  if (loadError) {
    return json({ error: "Could not load invitation" }, 500);
  }
  if (!invitation) {
    return json({ error: "Invitation not found" }, 404);
  }
  if (invitation.status !== "pending") {
    return json({ error: "Invitation is no longer pending" }, 409);
  }

  const toEmail = String(invitation.email ?? "").trim().toLowerCase();
  if (!toEmail || !toEmail.includes("@")) {
    return json({ error: "Invitation has no valid email" }, 422);
  }

  // Service-role client for the inviter's display name (profiles RLS hides
  // other users' rows) and for delivery-event logging.
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  if (!resendApiKey()) {
    console.log(
      `[send-invitation-email] id=${invitationId} emailStatus=unconfigured (no RESEND_API_KEY)`,
    );
    return json(configurationMissingBody());
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
    // 200 because the invitation itself is safely stored; the client
    // surfaces the email status honestly.
    return json({
      success: false,
      email_sent: false,
      error_code: result.errorCode,
      emailStatus: result.errorCode === "email_configuration_missing"
        ? "unconfigured"
        : "failed",
    });
  }

  console.log(
    `[send-invitation-email] id=${invitationId} to=${toEmail} context=${sendContext} emailStatus=sent providerId=${result.providerId ?? "-"}`,
  );
  return json({
    success: true,
    email_sent: true,
    emailStatus: "sent",
    providerId: result.providerId,
  });
});
