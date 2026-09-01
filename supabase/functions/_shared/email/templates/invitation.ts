// Vineyard invitation email — the single production invitation template used
// by iOS, Android and the Lovable portal (all via send-invitation-email).

import { escapeHtml, renderLayout } from "../layout.ts";
import {
  bodyText,
  introText,
  orderedSteps,
  panel,
  primaryButton,
  sectionHeading,
  smallText,
  summaryCard,
} from "../styles.ts";
import { VINETRACK_WEBSITE_URL } from "../brand.ts";

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
  const vineyard = escapeHtml(input.vineyardName);
  const inviter = escapeHtml(input.inviterName);
  const role = escapeHtml(input.roleLabel);
  const email = escapeHtml(input.inviteeEmail);

  const expiresLabel = input.expiresAt
    ? escapeHtml(new Date(input.expiresAt).toDateString())
    : null;

  const summaryRows = [
    { label: "Vineyard", valueHtml: vineyard },
    { label: "Invited by", valueHtml: inviter },
    { label: "Role", valueHtml: role },
    { label: "Invited email", valueHtml: email },
    ...(expiresLabel ? [{ label: "Expires", valueHtml: expiresLabel }] : []),
  ];

  const bodyHtml = `
    ${introText(`<strong>${inviter}</strong> has invited you to join <strong>${vineyard}</strong> on VineTrack as <strong>${role}</strong>.`)}
    ${summaryCard(summaryRows)}
    ${sectionHeading("How to accept")}
    ${orderedSteps([
      `Download or open the <strong>VineTrack</strong> app on your phone.`,
      `If you&rsquo;re new to VineTrack, create an account using <strong>${email}</strong>. If you already have a VineTrack account using this email address, sign in as normal.`,
      `Your pending invitation for <strong>${vineyard}</strong> will appear &mdash; tap <strong>Accept</strong> to join the team.`,
    ])}
    ${primaryButton("Open VineTrack", VINETRACK_WEBSITE_URL)}
    ${panel(
      `<strong>Important:</strong> you must sign in using the same email address this invitation was sent to.`,
      "warning",
    )}
    ${smallText("Nothing is shared with you until you accept the invitation.", 0)}
  `;

  return renderLayout({
    title: `You\u2019ve been invited to join ${input.vineyardName}`,
    preheader:
      `${input.inviterName} invited you to join ${input.vineyardName} on VineTrack as ${input.roleLabel}.`,
    bodyHtml,
    testBanner: input.isTest === true,
    footerHtml:
      `You received this email because someone invited ${email} to a vineyard team on VineTrack. If you weren\u2019t expecting this, you can ignore this email &mdash; nothing is shared until you accept.`,
  });
}
