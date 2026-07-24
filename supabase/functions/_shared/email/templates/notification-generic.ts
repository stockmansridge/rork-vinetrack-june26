// Generic notification template — infrastructure for future email alerts
// (weather, disease-risk, spray reminders, task assignments, etc.).
//
// Accepts ONLY structured fields; clients can never inject arbitrary HTML.
// Nothing sends these automatically yet.

import { escapeHtml, renderLayout } from "../layout.ts";
import type { NotificationClass } from "../types.ts";

export interface NotificationTemplateInput {
  title: string;
  summary: string;
  notificationType: NotificationClass;
  actionUrl?: string;
  actionLabel?: string;
  isTest?: boolean;
}

const CLASS_STYLES: Record<NotificationClass, { label: string; color: string }> = {
  information: { label: "Information", color: "#2563eb" },
  reminder: { label: "Reminder", color: "#2e5339" },
  warning: { label: "Warning", color: "#b45309" },
  critical: { label: "Critical", color: "#b91c1c" },
};

export function isNotificationClass(value: string): value is NotificationClass {
  return value === "information" || value === "reminder" ||
    value === "warning" || value === "critical";
}

export function notificationSubject(
  input: Pick<NotificationTemplateInput, "title" | "notificationType" | "isTest">,
): string {
  const prefix = input.notificationType === "critical"
    ? "[Critical] "
    : input.notificationType === "warning"
    ? "[Warning] "
    : "";
  const base = `${prefix}${input.title} — VineTrack`;
  return input.isTest ? `[TEST] ${base}` : base;
}

export function renderNotificationEmail(
  input: NotificationTemplateInput,
): string {
  const style = CLASS_STYLES[input.notificationType];

  const isSafeActionUrl = typeof input.actionUrl === "string" &&
    /^https:\/\//i.test(input.actionUrl.trim());
  const actionHtml = isSafeActionUrl
    ? `<p style="margin:20px 0">
        <a href="${escapeHtml(input.actionUrl!.trim())}"
           style="background:${style.color};color:#ffffff;text-decoration:none;padding:10px 18px;border-radius:8px;font-weight:600;font-size:14px;display:inline-block">
          ${escapeHtml(input.actionLabel?.trim() || "Open VineTrack")}
        </a>
      </p>`
    : "";

  const bodyHtml = `
    <p style="margin:0 0 12px">
      <span style="background:${style.color}1a;color:${style.color};font-size:12px;font-weight:700;padding:3px 10px;border-radius:999px;letter-spacing:0.4px;text-transform:uppercase">
        ${escapeHtml(style.label)}
      </span>
    </p>
    <p style="white-space:pre-wrap">${escapeHtml(input.summary)}</p>
    ${actionHtml}
  `;

  return renderLayout({
    title: input.title,
    bodyHtml,
    testBanner: input.isTest === true,
    footerHtml:
      "You received this notification from VineTrack. Notification preferences will be manageable in the app.",
  });
}
