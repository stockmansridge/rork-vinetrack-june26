// Generic notification template — structured infrastructure for future alerts.
// Client input is escaped; arbitrary HTML is never accepted.

import { escapeHtml, renderLayout } from "../layout.ts";
import { bodyText, fallbackUrl, primaryButton, statusBadge } from "../styles.ts";
import type { NotificationClass } from "../types.ts";

export interface NotificationTemplateInput {
  title: string;
  summary: string;
  notificationType: NotificationClass;
  actionUrl?: string;
  actionLabel?: string;
  isTest?: boolean;
}

const CLASSES: Record<NotificationClass, { label: string; panel: "green" | "warning" | "error" | "neutral" }> = {
  information: { label: "Information", panel: "neutral" },
  reminder: { label: "Reminder", panel: "green" },
  warning: { label: "Warning", panel: "warning" },
  critical: { label: "Critical", panel: "error" },
};

export function isNotificationClass(value: string): value is NotificationClass {
  return value === "information" || value === "reminder" || value === "warning" || value === "critical";
}

export function notificationSubject(input: Pick<NotificationTemplateInput, "title" | "notificationType" | "isTest">): string {
  const prefix = input.notificationType === "critical" ? "[Critical] " : input.notificationType === "warning" ? "[Warning] " : "";
  return input.isTest ? `[TEST] ${prefix}${input.title} — VineTrack` : `${prefix}${input.title} — VineTrack`;
}

export function renderNotificationEmail(input: NotificationTemplateInput): string {
  const category = CLASSES[input.notificationType];
  const actionUrl = typeof input.actionUrl === "string" && /^https:\/\//i.test(input.actionUrl.trim()) ? input.actionUrl.trim() : null;
  const actionHtml = actionUrl ? `${primaryButton(escapeHtml(input.actionLabel?.trim() || "Open VineTrack"), escapeHtml(actionUrl))}${fallbackUrl(escapeHtml(actionUrl))}` : "";

  return renderLayout({
    title: input.title,
    preheader: input.summary,
    testBanner: input.isTest === true,
    aboveTitleHtml: statusBadge(category.label, category.panel),
    bodyHtml: `${bodyText(escapeHtml(input.summary).replace(/\n/g, "<br />"), actionUrl ? 0 : 0)}${actionHtml}`,
    footerHtml: "You received this notification from VineTrack. Notification preferences will be manageable in the app.",
  });
}
