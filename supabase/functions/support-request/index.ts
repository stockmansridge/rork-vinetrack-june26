// Supabase Edge Function: support-request
//
// Sends the email notification for an in-app support / feedback / feature
// request to the VineTrack support inbox, and records delivery status back
// onto the public.support_requests row.
//
// The iOS app is responsible for the DURABLE path: it uploads any attachments
// to the `support-attachments` storage bucket and inserts the support_requests
// row (RLS-protected) BEFORE calling this function. This function only handles
// the best-effort email notification, so a request is never lost even if email
// delivery is unavailable.
//
// Request (POST JSON):
//   { "requestId": string (uuid) }
//
// Response 200 JSON:
//   { emailStatus: "sent" | "failed" | "unconfigured", providerId?: string }
//
// Errors return { error: string } with appropriate HTTP status.

// deno-lint-ignore-file no-explicit-any

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const SUPPORT_TO_EMAIL = Deno.env.get("SUPPORT_TO_EMAIL") ??
  "jonathan@stockmansridge.com.au";
// Resend requires a verified domain; fall back to their shared test sender so
// delivery still works before a custom domain is configured.
const SUPPORT_FROM_EMAIL = Deno.env.get("SUPPORT_FROM_EMAIL") ??
  "VineTrack Support <onboarding@resend.dev>";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !serviceRoleKey) {
    return json({ error: "Server is missing Supabase service configuration" }, 500);
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const requestId = typeof body?.requestId === "string"
    ? body.requestId.trim()
    : "";
  if (!requestId) {
    return json({ error: "Missing requestId" }, 400);
  }

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
    return json({ error: "Support request not found" }, 404);
  }

  // Build signed URLs (7 days) for any attachments so support can view them.
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

  const apiKey = Deno.env.get("RESEND_API_KEY") ?? "";

  // Helper to persist the email outcome onto the row.
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

  // No provider configured yet — the request is still safely stored.
  if (!apiKey) {
    await recordStatus("unconfigured", null, "RESEND_API_KEY not configured");
    console.log(
      `[support-request] id=${requestId} emailStatus=unconfigured (no RESEND_API_KEY)`,
    );
    return json({ emailStatus: "unconfigured" });
  }

  const subject = `VineTrack support — ${row.category ?? "general"}: ${row.subject ?? ""}`;
  const attachmentHtml = attachmentLinks.length
    ? `<p><strong>Attachments (${attachmentLinks.length}):</strong></p><ul>${
      attachmentLinks
        .map((u, i) => `<li><a href="${u}">Attachment ${i + 1}</a></li>`)
        .join("")
    }</ul>`
    : "<p><em>No attachments.</em></p>";

  const html = `
    <h2>New VineTrack support request</h2>
    <p><strong>Category:</strong> ${escapeHtml(String(row.category ?? "general"))}</p>
    <p><strong>Subject:</strong> ${escapeHtml(String(row.subject ?? ""))}</p>
    <p><strong>From:</strong> ${escapeHtml(String(row.submitter_name ?? "—"))} &lt;${escapeHtml(String(row.submitter_email ?? "—"))}&gt;</p>
    <p><strong>Vineyard:</strong> ${escapeHtml(String(row.vineyard_name ?? "—"))}</p>
    <hr/>
    <p style="white-space:pre-wrap">${escapeHtml(String(row.message ?? ""))}</p>
    <hr/>
    ${attachmentHtml}
    <p style="color:#888;font-size:12px">
      Platform: ${escapeHtml(String(row.app_platform ?? "—"))} ·
      App: ${escapeHtml(String(row.app_version ?? "—"))} (${escapeHtml(String(row.app_build ?? "—"))}) ·
      Device: ${escapeHtml(String(row.device_model ?? "—"))} ·
      OS: ${escapeHtml(String(row.os_version ?? "—"))}<br/>
      Request ID: ${escapeHtml(requestId)} · User ID: ${escapeHtml(String(row.user_id ?? "—"))}
    </p>
  `;

  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        from: SUPPORT_FROM_EMAIL,
        to: [SUPPORT_TO_EMAIL],
        reply_to: row.submitter_email || undefined,
        subject,
        html,
      }),
    });

    if (!res.ok) {
      const text = await res.text();
      const msg = `Resend HTTP ${res.status}: ${text.slice(0, 300)}`;
      await recordStatus("failed", null, msg);
      console.log(`[support-request] id=${requestId} emailStatus=failed ${msg}`);
      // 200 because the request itself is safely stored; the client surfaces
      // the email status honestly.
      return json({ emailStatus: "failed" });
    }

    const data: any = await res.json();
    const providerId: string | null = typeof data?.id === "string"
      ? data.id
      : null;
    await recordStatus("sent", providerId, null);
    console.log(
      `[support-request] id=${requestId} emailStatus=sent providerId=${providerId ?? "-"}`,
    );
    return json({ emailStatus: "sent", providerId });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await recordStatus("failed", null, message);
    console.log(`[support-request] id=${requestId} emailStatus=failed ${message}`);
    return json({ emailStatus: "failed" });
  }
});
