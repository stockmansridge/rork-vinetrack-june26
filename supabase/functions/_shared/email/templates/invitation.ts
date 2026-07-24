// Vineyard invitation email — the single production invitation template used
// by iOS, Android and the Lovable portal (all via send-invitation-email).

import { escapeHtml, renderLayout } from "../layout.ts";

export interface InvitationTemplateInput {
  inviterName: string;
  vineyardName: string;
  roleLabel: string;
  inviteeEmail: string;
  expiresAt: string | null;
  /** True when rendered for a diagnostics test (adds a banner, no access). */
  isTest?: boolean;
}

export function invitationSubject(vineyardName: string, isTest = false): string {
  const base = `You're invited to join ${vineyardName} on VineTrack`;
  return isTest ? `[TEST] ${base}` : base;
}

export function renderInvitationEmail(input: InvitationTemplateInput): string {
  const expiryLine = input.expiresAt
    ? `<p style="color:#888888">This invitation expires on ${
      escapeHtml(new Date(input.expiresAt).toDateString())
    }.</p>`
    : "";

  const bodyHtml = `
    <p><strong>${escapeHtml(input.inviterName)}</strong> has invited you to join
      <strong>${escapeHtml(input.vineyardName)}</strong> on VineTrack as
      <strong>${escapeHtml(input.roleLabel)}</strong>.</p>
    <p>To accept the invitation:</p>
    <ol style="padding-left:20px">
      <li>Download or open the <strong>VineTrack</strong> app on your phone.</li>
      <li>Sign in (or create an account) using <strong>this email address</strong>: ${
    escapeHtml(input.inviteeEmail)
  }</li>
      <li>Your pending invitation for ${
    escapeHtml(input.vineyardName)
  } will appear — tap <strong>Accept</strong> to join the team.</li>
    </ol>
    ${expiryLine}
  `;

  return renderLayout({
    title: "Vineyard team invitation",
    bodyHtml,
    testBanner: input.isTest === true,
    footerHtml: `You received this email because someone invited ${
      escapeHtml(input.inviteeEmail)
    } to a vineyard team on VineTrack. If you weren't expecting this, you can ignore this email — nothing is shared until you accept.`,
  });
}
