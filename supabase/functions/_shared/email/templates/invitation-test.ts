// Diagnostics wrapper around the REAL invitation renderer. Produces the
// production invitation HTML with a clear TEST banner. No invitation row is
// created and no access is granted by sending this email.

import {
  invitationSubject,
  renderInvitationEmail,
} from "./invitation.ts";

export interface InvitationTestInput {
  recipientEmail: string;
  adminName: string;
}

export function invitationTestSubject(): string {
  return invitationSubject("Example Vineyard", true);
}

export function renderInvitationTestEmail(input: InvitationTestInput): string {
  return renderInvitationEmail({
    inviterName: input.adminName || "A vineyard manager",
    vineyardName: "Example Vineyard",
    roleLabel: "Operator",
    inviteeEmail: input.recipientEmail,
    expiresAt: new Date(Date.now() + 14 * 24 * 60 * 60 * 1000).toISOString(),
    isTest: true,
  });
}
