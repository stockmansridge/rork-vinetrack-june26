// Shared plumbing for the System Admin email diagnostic edge functions
// (test-resend-email, test-invitation-email, test-support-staff-email,
// test-support-receipt-email, test-notification-email).
//
// Every diagnostic function:
//   - requires an authenticated caller;
//   - validates public.is_system_admin() with the CALLER's JWT;
//   - sends through the shared Resend client using the REAL templates
//     (marked with a TEST banner);
//   - writes an email_delivery_events row (default source_platform
//     "portal_diagnostics");
//   - never creates invitations, memberships or support records;
//   - never exposes secrets or raw provider payloads.

// deno-lint-ignore-file no-explicit-any

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { sendEmail } from "./client.ts";
import { resendApiKey } from "./config.ts";
import { logSendOutcome, logSubmitted } from "./logging.ts";
import type { EmailType } from "./types.ts";

export const DIAGNOSTIC_CORS: Record<string, string> = {
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

export function diagnosticJson(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...DIAGNOSTIC_CORS, "Content-Type": "application/json" },
  });
}

export interface DiagnosticContext {
  admin: any;
  actorUserId: string;
  adminName: string;
  recipientEmail: string;
  sourcePlatform: string;
  body: any;
}

export interface DiagnosticFailure {
  response: Response;
}

/**
 * Authenticates the caller, enforces System Administrator, and parses the
 * common `{ recipient_email, source_platform? }` request body.
 *
 * Returns either a ready DiagnosticContext or a failure Response to return
 * as-is.
 */
export async function prepareDiagnostic(
  req: Request,
): Promise<DiagnosticContext | DiagnosticFailure> {
  const fail = (errorCode: string, message: string, status: number) => ({
    response: diagnosticJson(
      { success: false, email_sent: false, error_code: errorCode, message },
      status,
    ),
  });

  if (req.method !== "POST") {
    return fail("invalid_request", "Method not allowed", 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return fail("invalid_request", "Server is missing Supabase configuration", 500);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return fail("unauthenticated", "Missing Authorization header", 401);
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return fail("invalid_request", "Invalid JSON body", 400);
  }

  const recipientEmail = typeof body?.recipient_email === "string"
    ? body.recipient_email.trim().toLowerCase()
    : "";
  if (!recipientEmail || !recipientEmail.includes("@")) {
    return fail("invalid_request", "Missing or invalid recipient_email", 400);
  }

  const rawPlatform = typeof body?.source_platform === "string"
    ? body.source_platform
    : "";
  const sourcePlatform = (ALLOWED_SOURCE_PLATFORMS as readonly string[])
      .includes(rawPlatform)
    ? rawPlatform
    : "portal_diagnostics";

  const userClient = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false },
    global: { headers: { Authorization: authHeader } },
  });

  const { data: userData, error: userError } = await userClient.auth.getUser();
  const actorUserId: string | null = userData?.user?.id ?? null;
  if (userError || !actorUserId) {
    return fail("unauthenticated", "Invalid or expired session", 401);
  }

  // System Administrator check runs as the CALLER — non-admins are rejected.
  const { data: isAdmin, error: adminError } = await userClient.rpc(
    "is_system_admin",
  );
  if (adminError || isAdmin !== true) {
    return fail(
      "permission_denied",
      "System Administrator access is required",
      403,
    );
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  let adminName = "System Administrator";
  const { data: profile } = await admin
    .from("profiles")
    .select("full_name, email")
    .eq("id", actorUserId)
    .maybeSingle();
  const name = String(profile?.full_name ?? "").trim();
  const email = String(profile?.email ?? "").trim();
  if (name) adminName = name;
  else if (email) adminName = email;

  return { admin, actorUserId, adminName, recipientEmail, sourcePlatform, body };
}

export interface DiagnosticSendInput {
  context: DiagnosticContext;
  emailType: EmailType;
  templateName: string;
  functionName: string;
  from: string;
  replyTo: string;
  subject: string;
  html: string;
  extraMetadata?: Record<string, unknown>;
}

/**
 * Sends a diagnostic email through the shared client, logs the delivery
 * event, and returns the standard diagnostic response.
 */
export async function sendDiagnosticEmail(
  input: DiagnosticSendInput,
): Promise<Response> {
  const { context } = input;

  if (!resendApiKey()) {
    return diagnosticJson(
      {
        success: false,
        email_sent: false,
        error_code: "email_configuration_missing",
        message: "Email delivery is not configured",
      },
      500,
    );
  }

  const eventId = await logSubmitted(context.admin, {
    emailType: input.emailType,
    recipientEmail: context.recipientEmail,
    sourcePlatform: context.sourcePlatform,
    actorUserId: context.actorUserId,
    metadata: {
      template: input.templateName,
      test: true,
      ...(input.extraMetadata ?? {}),
    },
  });

  const result = await sendEmail({
    from: input.from,
    to: context.recipientEmail,
    replyTo: input.replyTo,
    subject: input.subject,
    html: input.html,
    idempotencyKey: eventId
      ? `${input.functionName}/${eventId}`
      : undefined,
  });

  await logSendOutcome(context.admin, eventId, result);

  if (!result.ok) {
    console.log(
      `[${input.functionName}] to=${context.recipientEmail} emailStatus=failed ${result.errorCode}: ${result.errorDetail}`,
    );
    return diagnosticJson({
      success: false,
      email_sent: false,
      recipient_email: context.recipientEmail,
      email_event_id: eventId,
      error_code: "email_send_failed",
      message: "The test email could not be sent.",
    });
  }

  console.log(
    `[${input.functionName}] to=${context.recipientEmail} emailStatus=sent providerId=${result.providerId ?? "-"}`,
  );
  return diagnosticJson({
    success: true,
    email_sent: true,
    recipient_email: context.recipientEmail,
    provider: "resend",
    provider_message_id: result.providerId,
    email_event_id: eventId,
    submitted_at: new Date().toISOString(),
  });
}
