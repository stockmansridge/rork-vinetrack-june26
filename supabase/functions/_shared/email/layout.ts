// Branded HTML layout + escaping shared by every VineTrack template.
//
// Templates build a body fragment with escaped values, then wrap it with
// renderLayout(). No template may interpolate un-escaped client input.

export function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

export interface LayoutOptions {
  /** Heading shown under the VineTrack wordmark. Already-escaped plain text. */
  title: string;
  /** Pre-escaped HTML body fragment. */
  bodyHtml: string;
  /** Optional small grey footer note (pre-escaped HTML). */
  footerHtml?: string;
  /** Optional banner, e.g. for test emails. */
  testBanner?: boolean;
}

const BRAND_GREEN = "#2e5339";
const BRAND_BG = "#f4f4f0";

/** Wraps a body fragment in the shared VineTrack branded email shell. */
export function renderLayout(options: LayoutOptions): string {
  const banner = options.testBanner
    ? `<div style="background:#b45309;color:#ffffff;text-align:center;padding:8px 12px;font-size:13px;font-weight:600;border-radius:6px;margin-bottom:16px">
        TEST EMAIL — sent from VineTrack System Admin diagnostics. No action is required.
      </div>`
    : "";

  const footer = options.footerHtml
    ? `<p style="color:#888888;font-size:12px;line-height:1.5;margin:16px 0 0">${options.footerHtml}</p>`
    : "";

  return `<!doctype html>
<html>
  <body style="margin:0;padding:0;background:${BRAND_BG}">
    <div style="font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;max-width:560px;margin:0 auto;padding:24px 16px">
      <div style="background:#ffffff;border-radius:12px;padding:28px 24px;border:1px solid #e6e6df">
        ${banner}
        <div style="font-size:20px;font-weight:700;color:${BRAND_GREEN};letter-spacing:0.3px;margin-bottom:2px">VineTrack</div>
        <h2 style="color:#1a1a1a;font-size:17px;margin:12px 0 16px">${escapeHtml(options.title)}</h2>
        <div style="color:#333333;font-size:14px;line-height:1.6">
          ${options.bodyHtml}
        </div>
        <hr style="border:none;border-top:1px solid #eeeeee;margin:20px 0"/>
        ${footer}
        <p style="color:#aaaaaa;font-size:11px;margin:12px 0 0">
          VineTrack vineyard management · This is an automated message from VineTrack.
        </p>
      </div>
    </div>
  </body>
</html>`;
}
