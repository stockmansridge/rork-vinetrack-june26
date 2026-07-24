// Supabase Edge Function: test-resend-email (System Admin diagnostics)
//
// Provider configuration test — confirms the Resend API key, verified sender
// domain, external recipient acceptance, and provider message id, end to end.
//
// Request (POST JSON):  { "recipient_email": "person@example.com" }
// Auth: authenticated caller + public.is_system_admin() must be true.
//
// Sends the shared diagnostic template. No database records other than the
// email_delivery_events row (email_type "diagnostic",
// source_platform "portal_diagnostics") are created.

import { FROM_DEFAULT, REPLY_TO } from "../_shared/email/config.ts";
import {
  DIAGNOSTIC_CORS,
  prepareDiagnostic,
  sendDiagnosticEmail,
} from "../_shared/email/diagnostics.ts";
import {
  diagnosticSubject,
  renderDiagnosticEmail,
} from "../_shared/email/templates/diagnostic.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: DIAGNOSTIC_CORS });
  }

  const prepared = await prepareDiagnostic(req);
  if ("response" in prepared) return prepared.response;

  return await sendDiagnosticEmail({
    context: prepared,
    emailType: "diagnostic",
    templateName: "diagnostic",
    functionName: "test-resend-email",
    from: FROM_DEFAULT,
    replyTo: REPLY_TO,
    subject: diagnosticSubject(),
    html: renderDiagnosticEmail({
      adminName: prepared.adminName,
      requestedAt: new Date().toUTCString(),
    }),
  });
});
