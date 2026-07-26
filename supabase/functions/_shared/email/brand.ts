// Central VineTrack email brand constants.
// This file is intentionally pure (no Deno APIs) so it can be imported by
// edge functions and local preview scripts.

/** Public, stable HTTPS logo asset shared by every VineTrack email header. */
export const VINETRACK_EMAIL_LOGO_URL =
  "https://r2-pub.rork.com/attachments/ydkvjrs2dh2whzj6dusqj.png";

/** Rendered logo width in px (the hosted asset is retina-sized). */
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
  primary: "#2E5339",
  primaryDark: "#24442F",
  heading: "#1E2821",
  body: "#465049",
  muted: "#6F7972",
  border: "#DDE3DD",
  pageBg: "#F3F5F2",
  panelGreen: "#EEF4EF",
  panelGreenBorder: "#CAD9CD",
  panelWarning: "#FFF8E8",
  panelWarningBorder: "#E5C56E",
  panelError: "#FDEEEE",
  panelErrorBorder: "#D88A8A",
  panelNeutral: "#F7F8F6",
  panelNeutralBorder: "#E1E5E1",
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
