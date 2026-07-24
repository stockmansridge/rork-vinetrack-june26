// Provider diagnostic email — confirms Resend configuration end-to-end
// (API key, sender domain, external recipient acceptance, provider id).

import { escapeHtml, renderLayout } from "../layout.ts";
import { FROM_DEFAULT, REPLY_TO } from "../config.ts";

export interface DiagnosticTemplateInput {
  adminName: string;
  requestedAt: string;
}

export function diagnosticSubject(): string {
  return "[TEST] VineTrack email provider diagnostic";
}

export function renderDiagnosticEmail(input: DiagnosticTemplateInput): string {
  const bodyHtml = `
    <p>This is a provider configuration test sent from the VineTrack System
      Admin diagnostics page.</p>
    <table style="border-collapse:collapse;width:100%;font-size:13px;margin:12px 0">
      <tr>
        <td style="padding:6px 8px;color:#888888;white-space:nowrap">Requested by</td>
        <td style="padding:6px 8px">${escapeHtml(input.adminName || "System Administrator")}</td>
      </tr>
      <tr>
        <td style="padding:6px 8px;color:#888888;white-space:nowrap">Requested at</td>
        <td style="padding:6px 8px">${escapeHtml(input.requestedAt)}</td>
      </tr>
      <tr>
        <td style="padding:6px 8px;color:#888888;white-space:nowrap">Sender</td>
        <td style="padding:6px 8px">${escapeHtml(FROM_DEFAULT)}</td>
      </tr>
      <tr>
        <td style="padding:6px 8px;color:#888888;white-space:nowrap">Reply-to</td>
        <td style="padding:6px 8px">${escapeHtml(REPLY_TO)}</td>
      </tr>
    </table>
    <p>If you received this email, the Resend API key, verified sender domain
      and external delivery are all working.</p>
  `;

  return renderLayout({
    title: "Email provider diagnostic",
    bodyHtml,
    testBanner: true,
    footerHtml: "No action is required. This message can be deleted.",
  });
}
