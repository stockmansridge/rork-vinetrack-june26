// Submitter receipt for a support request — deliberately excludes internal notes
// and signed attachment URLs.

import { escapeHtml, renderLayout } from "../layout.ts";
import { bodyText, inlineLink, smallText, summaryCard } from "../styles.ts";
import { REPLY_TO } from "../config.ts";

export interface SupportReceiptTemplateInput {
  requestId: string;
  category: string;
  subject: string;
  summary: string;
  submittedAt: string;
  submitterName: string;
  isTest?: boolean;
}

export function supportReceiptSubject(isTest = false): string {
  const base = "We received your VineTrack support request";
  return isTest ? `[TEST] ${base}` : base;
}

export function summariseMessage(message: string): string {
  const trimmed = message.trim().replace(/\s+/g, " ");
  return trimmed.length > 200 ? `${trimmed.slice(0, 200)}…` : trimmed;
}

export function renderSupportReceiptEmail(input: SupportReceiptTemplateInput): string {
  const greeting = input.submitterName.trim() ? `Hi ${escapeHtml(input.submitterName.trim())},` : "Hi,";
  const date = new Date(input.submittedAt);
  const submittedAt = Number.isNaN(date.getTime()) ? input.submittedAt : date.toUTCString();
  const reference = input.isTest ? "Sample request" : input.requestId;

  const bodyHtml = `
    ${bodyText(greeting)}
    ${bodyText("We’ve received your support request. Our team will review it and get back to you as soon as possible.")}
    ${summaryCard([
      { label: "Reference", valueHtml: escapeHtml(reference) },
      { label: "Submitted", valueHtml: escapeHtml(submittedAt) },
      { label: "Category", valueHtml: escapeHtml(input.category || "General") },
      { label: "Subject", valueHtml: escapeHtml(input.subject || "No subject") },
      { label: "Summary", valueHtml: escapeHtml(input.summary || "No message summary available") },
    ], 20)}
    ${bodyText(`If you need to add anything, reply to this email or contact ${inlineLink(`mailto:${REPLY_TO}`, escapeHtml(REPLY_TO))} and quote the reference above.`)}
    ${smallText("Your request is safely recorded even if you do not receive a further email from us.", 0)}
  `;

  return renderLayout({
    title: "We’ve received your support request",
    preheader: "Your VineTrack support request has been received.",
    bodyHtml,
    testBanner: input.isTest === true,
  });
}
