// Supabase Edge Function: send-invitation-email
//
// Emails a vineyard team invitation to the invited address via Resend.
//
// The apps are responsible for the DURABLE path: they call the
// `create_invitation` RPC first (owner/manager enforced server-side), so the
// invitation row always exists before this function runs. This function only
// handles the best-effort email notification — the invitee can always accept
// in-app by signing in with the invited email, even if delivery fails.
//
// Authorization: the caller's JWT is forwarded to PostgREST, so RLS decides
// whether the caller may see the invitation (owner/manager of the vineyard or
// the invitee). Unknown/foreign invitation ids return 404.
//
// Request (POST JSON):
//   { "invitationId": string (uuid) }
//
// Response 200 JSON:
//   { emailStatus: "sent" | "failed" | "unconfigured", providerId?: string }
//
// Errors return { error: string } with appropriate HTTP status.
//
// Required secrets:
//   RESEND_API_KEY     — Resend API key (same one used by support-request)
//   INVITE_FROM_EMAIL  — optional verified sender, e.g. "VineTrack <invites@yourdomain.com>"

// deno-lint-ignore-file no-explicit-any

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Resend requires a verified domain; fall back to their shared test sender so
// delivery still works before a custom domain is configured.
const INVITE_FROM_EMAIL = Deno.env.get("INVITE_FROM_EMAIL") ??
  "VineTrack <onboarding@resend.dev>";

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

  // Caller-scoped client: RLS decides whether this user may see the
  // invitation (vineyard owner/manager or the invitee themselves).
  const userClient = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false },
    global: { headers: { Authorization: authHeader } },
  });

  const { data: invitation, error: loadError } = await userClient
    .from("invitations")
    .select("id, vineyard_id, email, role, status, expires_at, invited_by, vineyards(name)")
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

  // Service-role client only for the inviter's display name (profiles RLS
  // hides other users' rows from the caller).
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

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

  const apiKey = Deno.env.get("RESEND_API_KEY") ?? "";
  if (!apiKey) {
    console.log(
      `[send-invitation-email] id=${invitationId} emailStatus=unconfigured (no RESEND_API_KEY)`,
    );
    return json({ emailStatus: "unconfigured" });
  }

  const expiryLine = invitation.expires_at
    ? `<p style="color:#888">This invitation expires on ${
      escapeHtml(new Date(invitation.expires_at).toDateString())
    }.</p>`
    : "";

  const subject = `You're invited to join ${vineyardName} on VineTrack`;
  const html = `
    <div style="font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;max-width:560px;margin:0 auto;padding:24px">
      <h2 style="color:#2e5339;margin-bottom:4px">VineTrack invitation</h2>
      <p><strong>${escapeHtml(inviterName)}</strong> has invited you to join
        <strong>${escapeHtml(vineyardName)}</strong> on VineTrack as
        <strong>${escapeHtml(roleLabel)}</strong>.</p>
      <p>To accept the invitation:</p>
      <ol>
        <li>Download or open the <strong>VineTrack</strong> app on your phone.</li>
        <li>Sign in (or create an account) using <strong>this email address</strong>: ${escapeHtml(toEmail)}</li>
        <li>Your pending invitation for ${escapeHtml(vineyardName)} will appear — tap <strong>Accept</strong> to join the team.</li>
      </ol>
      ${expiryLine}
      <hr style="border:none;border-top:1px solid #eee;margin:20px 0"/>
      <p style="color:#888;font-size:12px">
        You received this email because someone invited ${escapeHtml(toEmail)}
        to a vineyard team on VineTrack. If you weren't expecting this, you can
        ignore this email — nothing is shared until you accept.
      </p>
    </div>
  `;

  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        from: INVITE_FROM_EMAIL,
        to: [toEmail],
        subject,
        html,
      }),
    });

    if (!res.ok) {
      const text = await res.text();
      console.log(
        `[send-invitation-email] id=${invitationId} emailStatus=failed Resend HTTP ${res.status}: ${text.slice(0, 300)}`,
      );
      // 200 because the invitation itself is safely stored; the client
      // surfaces the email status honestly.
      return json({ emailStatus: "failed" });
    }

    const data: any = await res.json();
    const providerId: string | null = typeof data?.id === "string"
      ? data.id
      : null;
    console.log(
      `[send-invitation-email] id=${invitationId} to=${toEmail} emailStatus=sent providerId=${providerId ?? "-"}`,
    );
    return json({ emailStatus: "sent", providerId });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.log(
      `[send-invitation-email] id=${invitationId} emailStatus=failed ${message}`,
    );
    return json({ emailStatus: "failed" });
  }
});
