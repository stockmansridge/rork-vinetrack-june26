// Shared Outlook-safe VineTrack email shell. Every email renderer supplies only
// its escaped content fragment; this module owns page, card, logo and footer.

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
    .replace(/\"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

export interface LayoutOptions {
  title: string;
  /** Pre-escaped, table-safe content supplied by a template. */
  bodyHtml: string;
  /** Pre-escaped optional note above the consistent footer. */
  footerHtml?: string;
  /** Shows the restrained System Admin diagnostic notice. */
  testBanner?: boolean;
  /** Pre-escaped status accent rendered above the title. */
  aboveTitleHtml?: string;
  preheader?: string;
}

function headerLogoHtml(): string {
  return `<img src="${VINETRACK_EMAIL_LOGO_URL}" alt="VineTrack" width="${LOGO_MAX_WIDTH}" style="display:block;width:${LOGO_MAX_WIDTH}px;max-width:100%;height:auto;border:0;outline:none;text-decoration:none;" />`;
}

function testBannerHtml(): string {
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;border-collapse:separate;margin:0 0 20px;">
  <tr><td style="background-color:${COLORS.panelWarning};border:1px solid ${COLORS.panelWarningBorder};border-radius:8px;padding:12px 16px;font-family:${FONT_STACK};font-size:14px;line-height:21px;font-weight:400;color:#6B5417;">Test email &mdash; generated from VineTrack System Admin diagnostics. No action is required.</td></tr>
</table>`;
}

/** Wraps all application email content in the single approved 640px layout. */
export function renderLayout(options: LayoutOptions): string {
  const preheader = options.preheader
    ? `<div style="display:none;max-height:0;overflow:hidden;mso-hide:all;font-size:1px;line-height:1px;color:${COLORS.pageBg};">${escapeHtml(options.preheader)}</div>`
    : "";
  const footerNote = options.footerHtml
    ? `<p style="margin:0 0 12px;font-family:${FONT_STACK};font-size:${TYPE.footer.size}px;line-height:${TYPE.footer.line}px;font-weight:400;color:${COLORS.muted};">${options.footerHtml}</p>`
    : "";

  return `<!doctype html>
<html lang="en" xmlns="http://www.w3.org/1999/xhtml" xmlns:o="urn:schemas-microsoft-com:office:office">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta http-equiv="X-UA-Compatible" content="IE=edge" />
  <meta name="color-scheme" content="light" />
  <meta name="supported-color-schemes" content="light" />
  <!--[if mso]><noscript><xml><o:OfficeDocumentSettings><o:PixelsPerInch>96</o:PixelsPerInch></o:OfficeDocumentSettings></xml></noscript><![endif]-->
  <style>
    body,table,td,a{-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%;}
    table{mso-table-lspace:0pt;mso-table-rspace:0pt;}
    img{-ms-interpolation-mode:bicubic;}
    @media only screen and (max-width:680px){
      .vt-outer{padding:12px !important;}
      .vt-header{padding:20px 22px !important;}
      .vt-content{padding:22px 20px !important;}
      .vt-footer{padding:20px 22px !important;}
      .vt-title{font-size:25px !important;line-height:33px !important;}
      .vt-button{width:100% !important;}
      .vt-button a{display:block !important;text-align:center !important;}
    }
  </style>
</head>
<body style="margin:0;padding:0;background:#F3F5F2;">
  ${preheader}
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;background:#F3F5F2;border-collapse:collapse;">
    <tr>
      <td align="center" class="vt-outer" style="padding:24px 12px;">
        <!--[if mso]><table role="presentation" width="640" align="center" cellpadding="0" cellspacing="0" border="0"><tr><td><![endif]-->
        <table role="presentation" width="640" cellpadding="0" cellspacing="0" border="0" style="width:100%;max-width:640px;background:#FFFFFF;border:1px solid #DDE3DD;border-radius:12px;border-collapse:separate;">
          <tr>
            <td class="vt-header" style="background:#FFFFFF;padding:24px 28px;border-bottom:1px solid #E2E7E2;border-radius:12px 12px 0 0;">${headerLogoHtml()}</td>
          </tr>
          <tr>
            <td class="vt-content" style="background:#FFFFFF;padding:32px;">
              ${options.testBanner ? testBannerHtml() : ""}
              ${options.aboveTitleHtml ?? ""}
              <h1 class="vt-title" style="margin:0 0 16px;font-family:${FONT_STACK};font-size:28px;line-height:36px;font-weight:700;color:#1E2821;">${escapeHtml(options.title)}</h1>
              ${options.bodyHtml}
            </td>
          </tr>
          <tr>
            <td class="vt-footer" style="background:#F7F8F6;border-top:1px solid #E1E5E1;border-radius:0 0 12px 12px;padding:22px 32px;">
              ${footerNote}
              <p style="margin:0 0 12px;font-family:${FONT_STACK};font-size:13px;line-height:20px;font-weight:400;color:#6F7972;"><strong style="color:#465049;">VineTrack</strong><br />Built by viticulturists, for viticulturists.</p>
              <p style="margin:0 0 12px;font-family:${FONT_STACK};font-size:13px;line-height:20px;font-weight:400;color:#6F7972;">Need help? <a href="mailto:${SUPPORT_CONTACT_EMAIL}" style="color:#2E5339;text-decoration:underline;">${SUPPORT_CONTACT_EMAIL}</a></p>
              <p style="margin:0;font-family:${FONT_STACK};font-size:13px;line-height:20px;font-weight:400;color:#6F7972;">This is an automated message from VineTrack.</p>
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
