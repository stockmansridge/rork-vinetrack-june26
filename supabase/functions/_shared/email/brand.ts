// Central VineTrack email brand constants.
//
// This file is intentionally pure (no Deno APIs) so it can be imported by
// edge functions AND by local preview/generator scripts.

/**
 * Public HTTPS URL of the VineTrack logo used in every email header.
 *
 * Requirements for the final asset:
 *   - transparent PNG, dark green wordmark;
 *   - ~600px wide source, tightly cropped;
 *   - hosted at a stable public HTTPS URL.
 *
 * Until the final URL is supplied this stays a placeholder — the shared
 * layout automatically falls back to a styled "VineTrack" wordmark whenever
 * this is not a valid https:// URL, so no email ever ships a broken image.
 */
export const VINETRACK_EMAIL_LOGO_URL = "PUBLIC_HTTPS_LOGO_URL";

/** Rendered logo width in px (source should be ~2x for retina). */
export const LOGO_MAX_WIDTH = 170;

/** Public VineTrack website — used for generic "Open VineTrack" buttons. */
export const VINETRACK_WEBSITE_URL = "https://vinetrack.com.au";

/** Human support address shown (and linked) in every footer. */
export const SUPPORT_CONTACT_EMAIL = "support@vinetrack.com.au";

/** Email-safe font stack used for ALL text in every template. */
export const FONT_STACK =
  `-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,Helvetica,sans-serif`;

/** VineTrack email palette. Do not add ad-hoc greys/beiges in templates. */
export const COLORS = {
  /** Primary green — buttons, links, brand accents. */
  primary: "#2E5339",
  /** Hover / fallback darker green. */
  primaryDark: "#24442F",
  /** Dark heading text. */
  heading: "#1E2821",
  /** Body text. */
  body: "#465049",
  /** Muted / secondary text. */
  muted: "#6F7972",
  /** Card + summary borders. */
  border: "#DDE3DD",
  /** Page background behind the card. */
  pageBg: "#F3F5F2",
  /** Soft green panel (recovery code, positive highlights). */
  panelGreen: "#EEF4EF",
  panelGreenBorder: "#CAD9CD",
  /** Soft warning panel. */
  panelWarning: "#FFF8E8",
  panelWarningBorder: "#E5C56E",
  /** Error / critical panel. */
  panelError: "#FDEEEE",
  panelErrorBorder: "#D88A8A",
  /** Neutral panel (fallback URLs, summary cards, footer). */
  panelNeutral: "#F7F8F6",
  panelNeutralBorder: "#E1E5E1",
  /** Header bottom border. */
  headerBorder: "#E2E7E2",
  white: "#FFFFFF",
} as const;

/** Typography scale (px sizes / line-heights) shared by every template. */
export const TYPE = {
  title: { size: 28, line: 36, weight: 700 },
  intro: { size: 17, line: 27, weight: 400 },
  sectionHeading: { size: 18, line: 26, weight: 700 },
  body: { size: 16, line: 25, weight: 400 },
  small: { size: 14, line: 21, weight: 400 },
  footer: { size: 13, line: 20, weight: 400 },
} as const;
