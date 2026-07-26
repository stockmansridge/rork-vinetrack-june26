// Shared branded email shell used by EVERY VineTrack email.
//
// Outlook-safe by construction:
//   - table-based layout, inline CSS only;
//   - fixed 640px max-width card (mso conditional keeps Outlook at 640);
//   - explicit background/text colours for forced-dark-mode readability;
//   - media query narrows padding + full-width buttons below 680px.
//
// Templates build a body fragment with escaped values, then wrap it with
// renderLayout(). No template may interpolate un-escaped client input.

import {
  COLORS,
  FONT_STACK,
  LOGO_MAX_WIDTH,
  SUPPORT_CONTACT_EMAIL,
  TYPE,
  VINETRACK_EMAIL_LOGO_URL,
} from "./brand.ts";

export function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

export interface LayoutOptions {
  /** Email title rendered as the 28px heading. Plain text (escaped here). */
  title: string;
  /** Pre-escaped HTML body fragment. */
  bodyHtml: string;
  /** Optional small muted footer note (pre-escaped HTML), shown above the standard footer lines. */
  footerHtml?: string;
  /** Optional banner for diagnostics/test emails. */
  testBanner?: boolean;
  /** Optional pre-escaped HTML rendered ABOVE the title (e.g. a status badge). */
  aboveTitleHtml?: string;
  /** Optional hidden preview text for inbox list views. Plain text. */
  preheader?: string;
}

/**
 * Header logo. Uses the hosted VineTrack logo when a real https URL is
 * configured in brand.ts; otherwise falls back to a styled wordmark so no
 * email ever ships a broken image.
 */
function headerLogoHtml(): string {
  if (/^https:\/\//i.test(VINETRACK_EMAIL_LOGO_URL)) {
    return `<img src="${VINETRACK_EMAIL_LOGO_URL}" alt="VineTrack" width="${LOGO_MAX_WIDTH}" style="display:block;max-width:${LOGO_MAX_WIDTH}px;width:${LOGO_MAX_WIDTH}px;height:auto;border:0;outline:none;text-decoration:none;" />`;
  }
  return `<span style="font-family:${FONT_STACK};font-size:24px;line-height:30px;font-weight:800;letter-spacing:0.4px;color:${COLORS.primary};">VineTrack</span>`;
}

function testBannerHtml(): string {
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:separate;margin:0 0 20px;">
  <tr>
    <td style="background-color:${COLORS.panelWarning};border:1px solid ${COLORS.panelWarningBorder};border-radius:10px;padding:12px 16px;font-family:${FONT_STACK};font-size:14px;line-height:21px;font-weight:700;color:#7A5A17;">TEST EMAIL &mdash; sent from VineTrack System Admin diagnostics. No action is required.</td>
  </tr>
</table>`;
}

/** Wraps a body fragment in the shared VineTrack branded email shell. */
export function renderLayout(options: LayoutOptions): string {
  const banner = options.testBanner === true ? testBannerHtml() : "";
  const aboveTitle = options.aboveTitleHtml ?? "";

  const preheader = options.preheader
    ? `<div style="display:none;max-height:0;overflow:hidden;mso-hide:all;font-size:1px;line-height:1px;color:${COLORS.pageBg};">${
      escapeHtml(options.preheader)
    }</div>`
    : "";

  const footerNote = options.footerHtml
    ? `<p style="margin:0 0 12px;font-family:${FONT_STACK};font-size:${TYPE.footer.size}px;line-height:${TYPE.footer.line}px;color:${COLORS.muted};">${options.footerHtml}</p>`
    : "";

  const footerText =
    `font-family:${FONT_STACK};font-size:${TYPE.footer.size}px;line-height:${TYPE.footer.line}px;color:${COLORS.muted};`;

  const title =
    `<h1 class="vt-title" style="margin:0 0 16px;font-family:${FONT_STACK};font-size:${TYPE.title.size}px;line-height:${TYPE.title.line}px;font-weight:700;color:${COLORS.heading};">${
      escapeHtml(options.title)
    }</h1>`;

  return `<!doctype html>
<html lang="en" xmlns="http://www.w3.org/1999/xhtml" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <meta http-equiv="X-UA-Compatible" content="IE=edge"/>
  <meta name="color-scheme" content="light"/>
  <meta name="supported-color-schemes" content="light"/>
  <!--[if mso]>
  <noscript><xml><o:OfficeDocumentSettings><o:PixelsPerInch>96</o:PixelsPerInch></o:OfficeDocumentSettings></xml></noscript>
  <![endif]-->
  <style>
    body, table, td, a { -webkit-text-size-adjust: 100%; -ms-text-size-adjust: 100%; }
    img { -ms-interpolation-mode: bicubic; }
    @media only screen and (max-width: 680px) {
      .vt-outer-pad { padding: 12px !important; }
      .vt-header { padding: 20px 22px !important; }
      .vt-content { padding: 22px !important; }
      .vt-footer { padding: 20px 22px !important; }
      .vt-title { font-size: 25px !important; line-height: 33px !important; }
      .vt-btn { width: 100% !important; }
      .vt-btn td { display: block !important; }
      .vt-btn a { display: block !important; text-align: center !important; }
    }
  </style>
</head>
<body style="margin:0;padding:0;background-color:${COLORS.pageBg};">
  ${preheader}
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:${COLORS.pageBg};">
    <tr>
      <td align="center" class="vt-outer-pad" style="padding:24px;">
        <!--[if mso]><table role="presentation" width="640" cellpadding="0" cellspacing="0" border="0" align="center"><tr><td><![endif]-->
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:640px;background-color:${COLORS.white};border:1px solid ${COLORS.border};border-radius:12px;border-collapse:separate;">
          <tr>
            <td class="vt-header" style="background-color:${COLORS.white};padding:24px 28px;border-bottom:1px solid ${COLORS.headerBorder};border-radius:12px 12px 0 0;">
              ${headerLogoHtml()}
            </td>
          </tr>
          <tr>
            <td class="vt-content" style="background-color:${COLORS.white};padding:32px;">
              ${banner}${aboveTitle}${title}
              ${options.bodyHtml}
            </td>
          </tr>
          <tr>
            <td class="vt-footer" style="background-color:${COLORS.panelNeutral};border-top:1px solid ${COLORS.panelNeutralBorder};border-radius:0 0 12px 12px;padding:22px 32px;">
              ${footerNote}<p style="margin:0 0 12px;${footerText}"><strong style="color:${COLORS.body};">VineTrack</strong><br/>Built by viticulturists, for viticulturists.</p>
              <p style="margin:0 0 12px;${footerText}">Need help? Contact <a href="mailto:${SUPPORT_CONTACT_EMAIL}" style="color:${COLORS.primary};text-decoration:underline;">${SUPPORT_CONTACT_EMAIL}</a></p>
              <p style="margin:0;${footerText}">This is an automated message from VineTrack.</p>
            </td>
          </tr>
        </table>
        <!--[if mso]></td></tr></table><![endif]-->
      </td>
    </tr>
  </table>
</body>
</html>`;
}
