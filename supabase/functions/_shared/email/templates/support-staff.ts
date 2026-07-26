// Staff notification for a new support request. The same renderer is used by
// support-request in production and test-support-staff-email diagnostics.

import { escapeHtml, renderLayout } from "../layout.ts";
import { bodyText, panel, sectionHeading, smallText, summaryCard } from "../styles.ts";

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

export function supportStaffSubject(category: string, subject: string, isTest = false): string {
  const base = `VineTrack support — ${category || "general"}: ${subject}`;
  return isTest ? `[TEST] ${base}` : base;
}

function labelValue(value: string, fallback: string): string {
  return escapeHtml(value.trim() || fallback);
}

export function renderSupportStaffEmail(input: SupportStaffTemplateInput): string {
  const isTest = input.isTest === true;
  const reference = isTest ? "Sample request" : input.requestId;
  const userReference = isTest ? "Sample user" : (input.userId || "Not available");
  const submittedAt = new Date().toUTCString();
  const sender = input.submitterName.trim()
    ? `${escapeHtml(input.submitterName.trim())} &lt;${escapeHtml(input.submitterEmail || "Not available")}&gt;`
    : escapeHtml(input.submitterEmail || "Not available");

  const attachmentHtml = input.attachmentLinks.length > 0
    ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;border-collapse:separate;margin:0 0 14px;"><tr><td style="background:#F7F8F6;border:1px solid #DDE3DD;border-radius:10px;padding:18px;"><p style="margin:0 0 8px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,Helvetica,sans-serif;font-size:16px;line-height:25px;font-weight:700;color:#1E2821;">Attachments</p>${input.attachmentLinks.map((link, index) => `<p style="margin:${index === 0 ? 0 : 8}px 0 0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;"><a href="${escapeHtml(link)}" style="color:#2E5339;text-decoration:underline;">Open attachment ${index + 1}</a></p>`).join("")}</td></tr></table>`
    : "";

  const metadataRows = [
    ["Platform", labelValue(input.appPlatform, "Not available")],
    ["App version", labelValue(input.appVersion, "Not available") + (input.appBuild ? ` (${escapeHtml(input.appBuild)})` : "")],
    ["Device", labelValue(input.deviceModel, "Not available")],
    ["OS", labelValue(input.osVersion, "Not available")],
    ["Request ID", escapeHtml(reference)],
    ["User ID", escapeHtml(userReference)],
  ];
  const metadataHtml = metadataRows.map(([label, value]) => `<tr><td valign="top" style="padding:0 12px 6px 0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,Helvetica,sans-serif;font-size:13px;line-height:20px;color:#6F7972;white-space:nowrap;">${label}</td><td valign="top" style="padding:0 0 6px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,Helvetica,sans-serif;font-size:13px;line-height:20px;color:#6F7972;word-break:break-word;">${value}</td></tr>`).join("");

  const bodyHtml = `
    ${bodyText("A new support request has been submitted and is ready for review.")}
    ${summaryCard([
      { label: "Category", valueHtml: labelValue(input.category, "General") },
      { label: "Subject", valueHtml: labelValue(input.subject, "No subject") },
      { label: "From", valueHtml: sender },
      { label: "Vineyard", valueHtml: labelValue(input.vineyardName, "Not specified") },
      { label: "Submitted", valueHtml: escapeHtml(submittedAt) },
      { label: "Reference", valueHtml: escapeHtml(reference) },
    ], 20)}
    ${sectionHeading("Message")}
    ${panel(`<div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,Helvetica,sans-serif;font-size:16px;line-height:25px;font-weight:400;color:#465049;white-space:pre-wrap;">${escapeHtml(input.message || "No message supplied.")}</div>`, "neutral", 20)}
    ${attachmentHtml}
    ${sectionHeading("Technical details")}
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;border-collapse:separate;margin:0;"><tr><td style="background:#F7F8F6;border:1px solid #E1E5E1;border-radius:8px;padding:14px 16px;"><table role="presentation" cellpadding="0" cellspacing="0" border="0">${metadataHtml}</table></td></tr></table>
  `;

  return renderLayout({
    title: "New support request",
    preheader: `New ${input.category || "general"} support request from ${input.submitterName || input.submitterEmail}.`,
    bodyHtml,
    testBanner: isTest,
  });
}
