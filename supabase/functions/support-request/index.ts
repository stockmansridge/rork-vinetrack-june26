// Supabase Edge Function: support-request
//
// Sends BOTH support emails for a persisted support request via the shared
// Resend email module (supabase/functions/_shared/email/):
//   1. Staff notification  → VineTrack support inbox (may include signed
//      attachment links — staff-only email).
//   2. Submitter receipt   → the person who submitted the request (never
//      includes internal notes or signed attachment URLs).
//
// The apps own the DURABLE path: they upload attachments and insert the
// public.support_requests row (RLS-protected) BEFORE calling this function.
// This function only handles best-effort email — the support request remains
// valid even if either email fails, and is never modified or deleted here
// beyond recording delivery status.
//
// Request (POST JSON):
//   {
//     "request_id": "uuid",                 // canonical (legacy: requestId)
//     "source_platform"?: "ios" | "android" | "portal" | "portal_diagnostics"
//   }
//
// Response 200 JSON (request found — durable record already stored):
//   {
//     success: true,
//     staff_email_sent: boolean,
//     receipt_email_sent: boolean,
//     staff_event_id: string | null,
//     receipt_event_id: string | null,
//     error_code?: "email_configuration_missing" | "email_send_failed",
//     emailStatus: "sent" | "failed" | "unconfigured",   // legacy (staff email)
//     providerId?: string                                 // legacy (staff email)
//   }
//
// Errors (non-200): { success:false, error_code, message } for
// invalid_request (400) and support request not found (404).
//
// Delivery logging: each attempt writes its own email_delivery_events row —
// email_type "support_staff" and "support_receipt". The legacy
// support_requests.email_status columns keep tracking the STAFF email so
// existing mobile builds behave unchanged.
//
// Required secret: RESEND_API_KEY. Senders come from the shared config
// (verified domain send.vinetrack.com.au) — the old fallback to
// onboarding@resend.dev has been removed.

// deno-lint-ignore-file no-explicit-any

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { sendEmail } from "../_shared/email/client.ts";
import {
  FROM_SUPPORT,
  REPLY_TO,
  resendApiKey,
  SUPPORT_TO_EMAIL,
} from "../_shared/email/config.ts";
import { logSendOutcome, logSubmitted } from "../_shared/email/logging.ts";
import {
  renderSupportStaffEmail,
  supportStaffSubject,
} from "../_shared/email/templates/support-staff.ts";
import {
  renderSupportReceiptEmail,
  summariseMessage,
  supportReceiptSubject,
} from "../_shared/email/templates/support-receipt.ts";

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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json(
      { success: false, error_code: "invalid_request", message: "Method not allowed", error: "Method not allowed" },
      405,
    );
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !serviceRoleKey) {
    return json(
      {
        success: false,
        error_code: "invalid_request",
        message: "Server is missing Supabase service configuration",
        error: "Server is missing Supabase service configuration",
      },
      500,
    );
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json(
      { success: false, error_code: "invalid_request", message: "Invalid JSON body", error: "Invalid JSON body" },
      400,
    );
  }

  const requestId =
    typeof body?.request_id === "string" && body.request_id.trim()
      ? body.request_id.trim()
      : typeof body?.requestId === "string"
      ? body.requestId.trim()
      : "";
  if (!requestId) {
    return json(
      { success: false, error_code: "invalid_request", message: "Missing request_id", error: "Missing requestId" },
      400,
    );
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

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  // Load the persisted support request.
  const { data: row, error: loadError } = await admin
    .from("support_requests")
    .select("*")
    .eq("id", requestId)
    .single();

  if (loadError || !row) {
    return json(
      {
        success: false,
        error_code: "invalid_request",
        message: "Support request not found",
        error: "Support request not found",
      },
      404,
    );
  }

  const actorUserId: string | null = typeof row.user_id === "string"
    ? row.user_id
    : null;

  // Legacy status columns on the support_requests row track the STAFF email.
  async function recordStatus(
    emailStatus: string,
    providerId: string | null,
    emailError: string | null,
  ) {
    await admin
      .from("support_requests")
      .update({
        email_status: emailStatus,
        email_provider_id: providerId,
        email_error: emailError,
        email_sent_at: emailStatus === "sent" ? new Date().toISOString() : null,
      })
      .eq("id", requestId);
  }

  // No provider configured — the request is still safely stored (200).
  if (!resendApiKey()) {
    await recordStatus("unconfigured", null, "RESEND_API_KEY not configured");
    console.log(
      `[support-request] id=${requestId} emailStatus=unconfigured (no RESEND_API_KEY)`,
    );
    return json({
      success: true,
      staff_email_sent: false,
      receipt_email_sent: false,
      staff_event_id: null,
      receipt_event_id: null,
      error_code: "email_configuration_missing",
      message:
        "The support request was received, but email delivery is not configured.",
      emailStatus: "unconfigured",
    });
  }

  // Signed URLs (7 days) for attachments — STAFF EMAIL ONLY.
  const attachmentPaths: string[] = Array.isArray(row.attachment_paths)
    ? row.attachment_paths
    : [];
  const attachmentLinks: string[] = [];
  for (const path of attachmentPaths) {
    try {
      const { data: signed } = await admin.storage
        .from("support-attachments")
        .createSignedUrl(path, 60 * 60 * 24 * 7);
      if (signed?.signedUrl) attachmentLinks.push(signed.signedUrl);
    } catch (_) {
      // Ignore individual signing failures — the path is still recorded.
    }
  }

  const category = String(row.category ?? "general");
  const subject = String(row.subject ?? "");
  const message = String(row.message ?? "");
  const submitterName = String(row.submitter_name ?? "");
  const submitterEmail = String(row.submitter_email ?? "").trim().toLowerCase();
  const submittedAt = String(row.created_at ?? new Date().toISOString());

  // ---------------------------------------------------------------------
  // 1. Staff notification
  // ---------------------------------------------------------------------
  const staffEventId = await logSubmitted(admin, {
    emailType: "support_staff",
    recipientEmail: SUPPORT_TO_EMAIL,
    sourcePlatform,
    actorUserId,
    metadata: {
      support_request_id: requestId,
      category,
      template: "support_staff",
    },
  });

  const staffResult = await sendEmail({
    from: FROM_SUPPORT,
    to: SUPPORT_TO_EMAIL,
    replyTo: submitterEmail || undefined,
    subject: supportStaffSubject(category, subject),
    html: renderSupportStaffEmail({
      requestId,
      category,
      subject,
      message,
      submitterName,
      submitterEmail,
      vineyardName: String(row.vineyard_name ?? ""),
      attachmentLinks,
      appPlatform: String(row.app_platform ?? ""),
      appVersion: String(row.app_version ?? ""),
      appBuild: String(row.app_build ?? ""),
      deviceModel: String(row.device_model ?? ""),
      osVersion: String(row.os_version ?? ""),
      userId: String(row.user_id ?? ""),
    }),
    idempotencyKey: staffEventId
      ? `support-staff/${requestId}/${staffEventId}`
      : undefined,
  });

  await logSendOutcome(admin, staffEventId, staffResult);
  await recordStatus(
    staffResult.ok ? "sent" : "failed",
    staffResult.providerId,
    staffResult.ok ? null : `${staffResult.errorCode}: ${staffResult.errorDetail}`,
  );

  // ---------------------------------------------------------------------
  // 2. Submitter receipt (no internal notes, no signed attachment links)
  // ---------------------------------------------------------------------
  let receiptEventId: string | null = null;
  let receiptSent = false;
  if (submitterEmail && submitterEmail.includes("@")) {
    receiptEventId = await logSubmitted(admin, {
      emailType: "support_receipt",
      recipientEmail: submitterEmail,
      sourcePlatform,
      actorUserId,
      metadata: {
        support_request_id: requestId,
        category,
        template: "support_receipt",
      },
    });

    const receiptResult = await sendEmail({
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
      idempotencyKey: receiptEventId
        ? `support-receipt/${requestId}/${receiptEventId}`
        : undefined,
    });

    await logSendOutcome(admin, receiptEventId, receiptResult);
    receiptSent = receiptResult.ok;
  }

  const anyFailed = !staffResult.ok ||
    (Boolean(submitterEmail) && !receiptSent);
  console.log(
    `[support-request] id=${requestId} staff=${staffResult.ok ? "sent" : "failed"} receipt=${receiptSent ? "sent" : submitterEmail ? "failed" : "skipped"} providerId=${staffResult.providerId ?? "-"}`,
  );

  // Always 200 — the durable support request exists regardless of email.
  return json({
    success: true,
    staff_email_sent: staffResult.ok,
    receipt_email_sent: receiptSent,
    staff_event_id: staffEventId,
    receipt_event_id: receiptEventId,
    ...(anyFailed ? { error_code: "email_send_failed" } : {}),
    ...(anyFailed
      ? {
        message:
          "The support request was received, but one or more emails could not be sent.",
      }
      : {}),
    // Legacy fields (staff email) kept for existing mobile builds.
    emailStatus: staffResult.ok ? "sent" : "failed",
    providerId: staffResult.providerId ?? undefined,
  });
});
