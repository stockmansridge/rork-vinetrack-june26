// Outlook-safe HTML building blocks shared by every VineTrack email.
//
// All helpers return pre-styled HTML fragments using ONLY inline CSS and
// table layout (no flexbox, no grid, no external stylesheets). Every text
// helper expects ALREADY-ESCAPED content unless noted otherwise.

import { COLORS, FONT_STACK, TYPE } from "./brand.ts";

function textStyle(
  size: number,
  line: number,
  color: string,
  weight = 400,
): string {
  return `font-family:${FONT_STACK};font-size:${size}px;line-height:${line}px;font-weight:${weight};color:${color};`;
}

/** 28px/36 bold page title. 16px gap to the intro below. */
export function emailTitle(escapedText: string): string {
  return `<h1 class="vt-title" style="margin:0 0 16px;${
    textStyle(TYPE.title.size, TYPE.title.line, COLORS.heading, 700)
  }">${escapedText}</h1>`;
}

/** 17px/27 introductory paragraph (pre-escaped HTML allowed). */
export function introText(html: string): string {
  return `<p style="margin:0 0 14px;${
    textStyle(TYPE.intro.size, TYPE.intro.line, COLORS.body)
  }">${html}</p>`;
}

/** 18px/26 bold section heading with 26px section gap above. */
export function sectionHeading(escapedText: string): string {
  return `<h2 style="margin:26px 0 10px;${
    textStyle(TYPE.sectionHeading.size, TYPE.sectionHeading.line, COLORS.heading, 700)
  }">${escapedText}</h2>`;
}

/** 16px/25 body paragraph (pre-escaped HTML allowed). */
export function bodyText(html: string, marginBottom = 14): string {
  return `<p style="margin:0 0 ${marginBottom}px;${
    textStyle(TYPE.body.size, TYPE.body.line, COLORS.body)
  }">${html}</p>`;
}

/** 14px/21 muted supporting text. */
export function smallText(html: string, marginBottom = 14): string {
  return `<p style="margin:0 0 ${marginBottom}px;${
    textStyle(TYPE.small.size, TYPE.small.line, COLORS.muted)
  }">${html}</p>`;
}

/** Inline mailto/product link in brand green. */
export function inlineLink(url: string, escapedLabel: string): string {
  return `<a href="${url}" style="color:${COLORS.primary};text-decoration:underline;">${escapedLabel}</a>`;
}

/**
 * Bulletproof table-based primary button.
 * Background #2E5339, white 16px/700 text, 14px 24px padding, 8px radius.
 * Goes full-width on mobile via the `vt-btn` media-query class.
 */
export function primaryButton(escapedLabel: string, url: string): string {
  return `<table role="presentation" cellpadding="0" cellspacing="0" border="0" class="vt-btn" style="margin:24px 0 20px;border-collapse:separate;">
  <tr>
    <td align="center" bgcolor="${COLORS.primary}" style="border-radius:8px;mso-padding-alt:14px 24px;">
      <a href="${url}" class="vt-btn-a" style="display:inline-block;background-color:${COLORS.primary};${
    textStyle(16, 20, COLORS.white, 700)
  }text-decoration:none;padding:14px 24px;border-radius:8px;">${escapedLabel}</a>
    </td>
  </tr>
</table>`;
}

/**
 * "Button not working?" helper + the raw URL wrapped in a light neutral
 * panel with word-break so Outlook never renders one long blue line.
 */
export function fallbackUrl(url: string): string {
  return `<p style="margin:0 0 8px;${
    textStyle(TYPE.small.size, TYPE.small.line, COLORS.muted)
  }"><strong style="color:${COLORS.body};">Button not working?</strong><br/>Copy and paste this address into your browser:</p>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:separate;margin:0 0 14px;">
  <tr>
    <td style="background-color:${COLORS.panelNeutral};border:1px solid ${COLORS.panelNeutralBorder};border-radius:8px;padding:12px;${
    textStyle(13, 19, COLORS.body)
  }word-break:break-all;">${url}</td>
  </tr>
</table>`;
}

type PanelKind = "neutral" | "green" | "warning" | "error";

const PANEL_STYLES: Record<PanelKind, { bg: string; border: string }> = {
  neutral: { bg: COLORS.panelNeutral, border: COLORS.panelNeutralBorder },
  green: { bg: COLORS.panelGreen, border: COLORS.panelGreenBorder },
  warning: { bg: COLORS.panelWarning, border: COLORS.panelWarningBorder },
  error: { bg: COLORS.panelError, border: COLORS.panelErrorBorder },
};

/**
 * Reserved-use panel for important actions, warnings or summaries.
 * NOT for ordinary paragraphs.
 */
export function panel(
  innerHtml: string,
  kind: PanelKind = "neutral",
  marginBottom = 14,
): string {
  const s = PANEL_STYLES[kind];
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:separate;margin:0 0 ${marginBottom}px;">
  <tr>
    <td style="background-color:${s.bg};border:1px solid ${s.border};border-radius:10px;padding:14px 16px;${
    textStyle(TYPE.small.size, TYPE.small.line, COLORS.body)
  }">${innerHtml}</td>
  </tr>
</table>`;
}

/** Prominent contained six-digit recovery code with its label. */
export function codePanel(codeHtml: string): string {
  return `<p style="margin:0 0 8px;${
    textStyle(TYPE.small.size, TYPE.small.line, COLORS.body, 700)
  }">Your six-digit recovery code</p>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:separate;margin:0 0 14px;">
  <tr>
    <td align="center" style="background-color:${COLORS.panelGreen};border:1px solid ${COLORS.panelGreenBorder};border-radius:10px;padding:20px;font-family:${FONT_STACK};font-size:32px;line-height:40px;font-weight:700;letter-spacing:6px;color:${COLORS.primary};text-align:center;">${codeHtml}</td>
  </tr>
</table>`;
}

export interface SummaryRow {
  /** Already-escaped label. */
  label: string;
  /** Pre-escaped HTML value. */
  valueHtml: string;
}

/**
 * Structured summary card (#F7F8F6, 1px #DDE3DD, 18px padding) used for
 * invitation details, support references, email-change summaries etc.
 */
export function summaryCard(rows: SummaryRow[], marginBottom = 14): string {
  const rowsHtml = rows
    .map((row, index) => `<tr>
      <td valign="top" style="padding:${index === 0 ? 0 : 7}px 14px 0 0;${
      textStyle(TYPE.small.size, TYPE.small.line, COLORS.muted)
    }white-space:nowrap;">${row.label}</td>
      <td valign="top" style="padding:${index === 0 ? 0 : 7}px 0 0;${
      textStyle(TYPE.small.size, TYPE.small.line, COLORS.body, 600)
    }">${row.valueHtml}</td>
    </tr>`)
    .join("");

  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:separate;margin:0 0 ${marginBottom}px;">
  <tr>
    <td style="background-color:${COLORS.panelNeutral};border:1px solid ${COLORS.border};border-radius:10px;padding:18px;">
      <table role="presentation" cellpadding="0" cellspacing="0" border="0">${rowsHtml}</table>
    </td>
  </tr>
</table>`;
}

/** Compact status label used at the top of notification emails. */
export function statusBadge(
  escapedLabel: string,
  kind: PanelKind,
): string {
  const s = PANEL_STYLES[kind];
  const color = kind === "error"
    ? "#9C3A3A"
    : kind === "warning"
    ? "#7A5A17"
    : COLORS.primary;
  return `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="border-collapse:separate;margin:0 0 14px;">
  <tr>
    <td style="background-color:${s.bg};border:1px solid ${s.border};border-radius:999px;padding:4px 12px;${
    textStyle(12, 16, color, 700)
  }letter-spacing:0.6px;text-transform:uppercase;">${escapedLabel}</td>
  </tr>
</table>`;
}

/** Styled ordered list for step-by-step instructions. */
export function orderedSteps(escapedItemsHtml: string[]): string {
  const items = escapedItemsHtml
    .map((item) =>
      `<li style="margin:0 0 8px;${
        textStyle(TYPE.body.size, TYPE.body.line, COLORS.body)
      }">${item}</li>`
    )
    .join("");
  return `<ol style="margin:0 0 14px;padding:0 0 0 22px;">${items}</ol>`;
}
