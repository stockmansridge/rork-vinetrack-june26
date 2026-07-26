// Supabase Edge Function: support-request
//
// Sends the two production support emails for an already-persisted support
// request. The client owns the durable flow: upload attachments, insert
// public.support_requests, then invoke this function. A mail failure never
// deletes, rolls back, or otherwise invalidates the saved request.
//
// Canonical request:
// { "request_id": "uuid", "source_platform": "ios" | "android" | "portal" | "unknown" }
// `requestId` and `sourcePlatform` remain accepted for older app releases.

// deno-lint-ignore-file no-explicit-any

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { sendEmail } from "../_shared/email/client.ts";
import { FROM_SUPPORT, REPLY_TO, SUPPORT_TO_EMAIL } from "../_shared/email/config.ts";
import { logSendOutcome, logSubmitted } from "../_shared/email/logging.ts";
import { renderSupportStaffEmail, supportStaffSubject } from "../_shared/email/templates/support-staff.ts";
import { renderSupportReceiptEmail, summariseMessage, supportReceiptSubject } from "../_shared/email/templates/support-receipt.ts";
import type { SendEmailResult } from "../_shared/email/types.ts";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const ALLOWED_SOURCE_PLATFORMS = ["ios", "android", "portal", "unknown"] as const;
const ATTACHMENTS_BUCKET = "support-attachments";
const ATTACHMENT_LINK_TTL_SECONDS = 60 * 60 * 24;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function failedResult(errorCode: SendEmailResult["errorCode"], errorDetail: string): SendEmailResult {
  return { ok: false, providerId: null, errorCode, errorDetail };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") {
    return json({ success: false, error_code: "invalid_request", message: "Method not allowed" }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return json({ success: false, error_code: "server_configuration_missing", message: "Support email is temporarily unavailable." }, 500);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return json({ success: false, error_code: "unauthenticated", message: "Sign in is required." }, 401);
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ success: false, error_code: "invalid_request", message: "Invalid request." }, 400);
  }

  const requestId = typeof body?.request_id === "string" && body.request_id.trim()
    ? body.request_id.trim()
    : typeof body?.requestId === "string" && body.requestId.trim()
    ? body.requestId.trim()
    : "";
  if (!requestId) {
    return json({ success: false, error_code: "invalid_request", message: "Missing request_id." }, 400);
  }

  const rawPlatform = typeof body?.source_platform === "string"
    ? body.source_platform
    : typeof body?.sourcePlatform === "string"
    ? body.sourcePlatform
    : "unknown";
  const sourcePlatform = (ALLOWED_SOURCE_PLATFORMS as readonly string[]).includes(rawPlatform)
    ? rawPlatform
    : "unknown";

  // Authenticate with the caller JWT before loading through the service role.
  // Possessing a support-request UUID is never enough to trigger an email.
  const userClient = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false },
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  const actorUserId = userData?.user?.id ?? null;
  if (userError || !actorUserId) {
    return json({ success: false, error_code: "unauthenticated", message: "Your session has expired. Please sign in again." }, 401);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });
  const { data: row, error: loadError } = await admin
    .from("support_requests")
    .select("*")
    .eq("id", requestId)
    .maybeSingle();
  if (loadError || !row) {
    return json({ success: false, error_code: "not_found", message: "Support request not found." }, 404);
  }
  if (row.user_id !== actorUserId) {
    return json({ success: false, error_code: "permission_denied", message: "You are not allowed to send email for this support request." }, 403);
  }

  const category = String(row.category ?? "general");
  const subject = String(row.subject ?? "");
  const message = String(row.message ?? "");
  const submitterName = String(row.submitter_name ?? "");
  const submitterEmail = String(row.submitter_email ?? "").trim().toLowerCase();
  const receiptRecipientIsValid = submitterEmail.includes("@");
  const submittedAt = String(row.created_at ?? new Date().toISOString());

  const attachmentPaths = Array.isArray(row.attachment_paths) ? row.attachment_paths : [];
  const safeAttachmentPrefix = `${actorUserId}/${requestId}/`;
  const attachmentLinks: string[] = [];
  for (const path of attachmentPaths) {
    if (typeof path !== "string" || !path.startsWith(safeAttachmentPrefix)) continue;
    const { data: signed } = await admin.storage
      .from(ATTACHMENTS_BUCKET)
      .createSignedUrl(path, ATTACHMENT_LINK_TTL_SECONDS);
    if (signed?.signedUrl) attachmentLinks.push(signed.signedUrl);
  }

  // Create separate event rows before attempting either send. These logs only
  // contain safe provenance — never HTML, tokens, or private attachment URLs.
  const staffEventId = await logSubmitted(admin, {
    emailType: "support_staff",
    recipientEmail: SUPPORT_TO_EMAIL,
    sourcePlatform,
    actorUserId,
    metadata: { support_request_id: requestId, template: "support-staff" },
  });
  const receiptEventId = receiptRecipientIsValid
    ? await logSubmitted(admin, {
      emailType: "support_receipt",
      recipientEmail: submitterEmail,
      sourcePlatform,
      actorUserId,
      metadata: { support_request_id: requestId, template: "support-receipt" },
    })
    : null;

  const staffResult = await sendEmail({
    from: FROM_SUPPORT,
    to: SUPPORT_TO_EMAIL,
    replyTo: receiptRecipientIsValid ? submitterEmail : undefined,
    subject: supportStaffSubject(category, subject),
    html: renderSupportStaffEmail({
      requestId,
      category,
      subject,
      message,
      submitterName,
      submitterEmail,
      vineyardName: String(row.vineyard_name ?? ""),
      submittedAt,
      attachmentLinks,
      appPlatform: String(row.app_platform ?? ""),
      appVersion: String(row.app_version ?? ""),
      appBuild: String(row.app_build ?? ""),
      deviceModel: String(row.device_model ?? ""),
      osVersion: String(row.os_version ?? ""),
      userId: actorUserId,
    }),
    idempotencyKey: `support-staff/${requestId}`,
  });
  await logSendOutcome(admin, staffEventId, staffResult);

  const receiptResult = receiptRecipientIsValid
    ? await sendEmail({
      from: FROM_SUPPORT,
      to: submitterEmail,
      replyTo: REPLY_TO,
      subject: supportReceiptSubject(),
      html: renderSupportReceiptEmail({
        requestId,
        category,
        subject,
        summary: summariseMessage(message),
        submittedAt,
        submitterName,
      }),
      idempotencyKey: `support-receipt/${requestId}`,
    })
    : failedResult("invalid_recipient", "Support request has no valid submitter email");
  await logSendOutcome(admin, receiptEventId, receiptResult);

  // Maintain legacy staff-delivery fields without making the request itself
  // contingent on email success.
  await admin.from("support_requests").update({
    email_status: staffResult.ok ? "sent" : "failed",
    email_provider_id: staffResult.providerId,
    email_error: staffResult.ok ? null : `${staffResult.errorCode ?? "provider_rejected"}: ${staffResult.errorDetail ?? "Unknown error"}`,
    email_sent_at: staffResult.ok ? new Date().toISOString() : null,
  }).eq("id", requestId);

  const staffSent = staffResult.ok;
  const receiptSent = receiptResult.ok;
  const bothFailed = !staffSent && !receiptSent;
  const partialFailure = !bothFailed && (!staffSent || !receiptSent);
  console.log(`[support-request] id=${requestId} staff=${staffSent ? "sent" : "failed"} receipt=${receiptSent ? "sent" : "failed"}`);

  return json({
    success: true,
    request_saved: true,
    staff_email_sent: staffSent,
    receipt_email_sent: receiptSent,
    staff_event_id: staffEventId,
    receipt_event_id: receiptEventId,
    ...(bothFailed ? {
      error_code: "email_send_failed",
      message: "The support request was received, but the notification emails could not be sent.",
    } : partialFailure ? {
      error_code: "partial_email_failure",
      message: "The support request was received, but one confirmation email could not be sent.",
    } : {}),
    // Compatibility fields for older mobile builds.
    emailStatus: staffSent ? "sent" : "failed",
    providerId: staffResult.providerId ?? undefined,
  });
});
