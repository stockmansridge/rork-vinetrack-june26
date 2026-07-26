// Provider diagnostic email — confirms Resend configuration end-to-end.

import { escapeHtml, renderLayout } from "../layout.ts";
import { bodyText, smallText, summaryCard } from "../styles.ts";
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
    ${bodyText("This is a provider configuration test sent from the VineTrack System Admin diagnostics page.")}
    ${summaryCard([
      { label: "Requested by", valueHtml: escapeHtml(input.adminName || "System Administrator") },
      { label: "Requested at", valueHtml: escapeHtml(input.requestedAt) },
      { label: "Sender", valueHtml: escapeHtml(FROM_DEFAULT) },
      { label: "Reply-to", valueHtml: escapeHtml(REPLY_TO) },
    ], 20)}
    ${smallText("If you received this message, the Resend API key, verified sender domain and external delivery request are working.", 0)}
  `;

  return renderLayout({
    title: "Email provider diagnostic",
    preheader: "VineTrack Resend provider configuration test.",
    bodyHtml,
    testBanner: true,
  });
}
