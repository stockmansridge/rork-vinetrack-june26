// Submitter receipt for a support request — confirms VineTrack received it.
// Deliberately excludes internal notes and signed attachment URLs.

import { escapeHtml, renderLayout } from "../layout.ts";
import { REPLY_TO } from "../config.ts";

export interface SupportReceiptTemplateInput {
  requestId: string;
  category: string;
  subject: string;
  /** Short summary of the message (first ~200 chars, truncated server-side). */
  summary: string;
  submittedAt: string;
  submitterName: string;
  isTest?: boolean;
}

export function supportReceiptSubject(isTest = false): string {
  const base = "We received your VineTrack support request";
  return isTest ? `[TEST] ${base}` : base;
}

/** Truncates the message body to a short summary for the receipt. */
export function summariseMessage(message: string): string {
  const trimmed = message.trim().replace(/\s+/g, " ");
  return trimmed.length > 200 ? `${trimmed.slice(0, 200)}…` : trimmed;
}

export function renderSupportReceiptEmail(
  input: SupportReceiptTemplateInput,
): string {
  const greeting = input.submitterName.trim()
    ? `Hi ${escapeHtml(input.submitterName.trim())},`
    : "Hi,";

  const submitted = new Date(input.submittedAt);
  const submittedLabel = isNaN(submitted.getTime())
    ? escapeHtml(input.submittedAt)
    : escapeHtml(submitted.toUTCString());

  const bodyHtml = `
    <p>${greeting}</p>
    <p>Thanks for contacting VineTrack — we've received your support request
      and our team will get back to you as soon as possible.</p>
    <table style="border-collapse:collapse;width:100%;font-size:13px;margin:12px 0">
      <tr>
        <td style="padding:6px 8px;color:#888888;white-space:nowrap">Reference</td>
        <td style="padding:6px 8px"><code>${escapeHtml(input.requestId)}</code></td>
      </tr>
      <tr>
        <td style="padding:6px 8px;color:#888888;white-space:nowrap">Submitted</td>
        <td style="padding:6px 8px">${submittedLabel}</td>
      </tr>
      <tr>
        <td style="padding:6px 8px;color:#888888;white-space:nowrap">Category</td>
        <td style="padding:6px 8px">${escapeHtml(input.category || "general")}</td>
      </tr>
      <tr>
        <td style="padding:6px 8px;color:#888888;white-space:nowrap">Subject</td>
        <td style="padding:6px 8px">${escapeHtml(input.subject)}</td>
      </tr>
      <tr>
        <td style="padding:6px 8px;color:#888888;white-space:nowrap;vertical-align:top">Summary</td>
        <td style="padding:6px 8px">${escapeHtml(input.summary)}</td>
      </tr>
    </table>
    <p>If you need to add anything, reply to this email or contact us at
      <a href="mailto:${escapeHtml(REPLY_TO)}">${escapeHtml(REPLY_TO)}</a>
      and quote the reference above.</p>
  `;

  return renderLayout({
    title: "Support request received",
    bodyHtml,
    testBanner: input.isTest === true,
    footerHtml:
      "You received this email because a support request was submitted from your VineTrack account. If that wasn't you, please contact us.",
  });
}
