// Staff notification for a new support request — sent to the VineTrack
// support inbox. May include signed attachment links (staff-only email).

import { escapeHtml, renderLayout } from "../layout.ts";

export interface SupportStaffTemplateInput {
  requestId: string;
  category: string;
  subject: string;
  message: string;
  submitterName: string;
  submitterEmail: string;
  vineyardName: string;
  attachmentLinks: string[];
  appPlatform: string;
  appVersion: string;
  appBuild: string;
  deviceModel: string;
  osVersion: string;
  userId: string;
  isTest?: boolean;
}

export function supportStaffSubject(
  category: string,
  subject: string,
  isTest = false,
): string {
  const base = `VineTrack support — ${category || "general"}: ${subject}`;
  return isTest ? `[TEST] ${base}` : base;
}

export function renderSupportStaffEmail(
  input: SupportStaffTemplateInput,
): string {
  const attachmentHtml = input.attachmentLinks.length
    ? `<p><strong>Attachments (${input.attachmentLinks.length}):</strong></p><ul>${
      input.attachmentLinks
        .map((u, i) =>
          `<li><a href="${escapeHtml(u)}">Attachment ${i + 1}</a></li>`
        )
        .join("")
    }</ul>`
    : "<p><em>No attachments.</em></p>";

  const bodyHtml = `
    <p><strong>Category:</strong> ${escapeHtml(input.category || "general")}</p>
    <p><strong>Subject:</strong> ${escapeHtml(input.subject)}</p>
    <p><strong>From:</strong> ${escapeHtml(input.submitterName || "—")} &lt;${
    escapeHtml(input.submitterEmail || "—")
  }&gt;</p>
    <p><strong>Vineyard:</strong> ${escapeHtml(input.vineyardName || "—")}</p>
    <hr style="border:none;border-top:1px solid #eeeeee"/>
    <p style="white-space:pre-wrap">${escapeHtml(input.message)}</p>
    <hr style="border:none;border-top:1px solid #eeeeee"/>
    ${attachmentHtml}
  `;

  return renderLayout({
    title: "New support request",
    bodyHtml,
    testBanner: input.isTest === true,
    footerHtml: `Platform: ${escapeHtml(input.appPlatform || "—")} · App: ${
      escapeHtml(input.appVersion || "—")
    } (${escapeHtml(input.appBuild || "—")}) · Device: ${
      escapeHtml(input.deviceModel || "—")
    } · OS: ${escapeHtml(input.osVersion || "—")}<br/>Request ID: ${
      escapeHtml(input.requestId)
    } · User ID: ${escapeHtml(input.userId || "—")}`,
  });
}
