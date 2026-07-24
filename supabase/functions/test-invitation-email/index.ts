// Supabase Edge Function: test-invitation-email (System Admin diagnostics)
//
// Sends the REAL production invitation template (with a clear TEST banner)
// to the given recipient. NO invitation row is created and NO access is
// granted — this only exercises the rendering + delivery pathway.
//
// Request (POST JSON):  { "recipient_email": "person@example.com" }
// Auth: authenticated caller + public.is_system_admin() must be true.
//
// Delivery event: email_type "invitation_test",
// source_platform "portal_diagnostics".

import { FROM_INVITES, REPLY_TO } from "../_shared/email/config.ts";
import {
  DIAGNOSTIC_CORS,
  prepareDiagnostic,
  sendDiagnosticEmail,
} from "../_shared/email/diagnostics.ts";
import {
  invitationTestSubject,
  renderInvitationTestEmail,
} from "../_shared/email/templates/invitation-test.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: DIAGNOSTIC_CORS });
  }

  const prepared = await prepareDiagnostic(req);
  if ("response" in prepared) return prepared.response;

  return await sendDiagnosticEmail({
    context: prepared,
    emailType: "invitation_test",
    templateName: "invitation",
    functionName: "test-invitation-email",
    from: FROM_INVITES,
    replyTo: REPLY_TO,
    subject: invitationTestSubject(),
    html: renderInvitationTestEmail({
      recipientEmail: prepared.recipientEmail,
      adminName: prepared.adminName,
    }),
  });
});
