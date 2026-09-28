import { classifyUrl, hostOf, manufacturerHostEligible } from "../research/classify.ts";
import { nameCorresponds, normaliseProductNameLoose } from "./matching.ts";
import type { InspectedPage } from "../research/page_inspector.ts";
import type { PdfTextItem } from "./contract.ts";

/** A container label explicitly defers its directions to a separate document. */
export function requiresAttachedDirections(text: string): boolean {
  return /\b(?:read|see|refer\s+to)\s+(?:the\s+)?(?:attached\s+)?(?:product\s+)?(?:leaflet|booklet)\b|\bdirections\s+for\s+use\s*[:–-]?\s*see\s+(?:the\s+)?(?:attached\s+)?(?:leaflet|booklet)\b/i.test(text);
}

/** Only the inspected product's own host may supply the one companion PDF. */
export function pageMatchesLockedProduct(product: string, pageName: string, registrant: string): boolean {
  if (nameCorresponds(product, pageName)) return true;
  const prefix = normaliseProductNameLoose(registrant).split(" ")[0];
  const tokens = normaliseProductNameLoose(product).split(" ");
  return prefix.length >= 4 && tokens[0] === prefix && nameCorresponds(tokens.slice(1).join(" "), pageName);
}

export function companionDirectionsUrl(page: InspectedPage | null, product: string, country: string,
  registrant: string, excluded: string): string | null {
  if (!page || !pageMatchesLockedProduct(product, page.pageProductName, registrant) ||
    !manufacturerHostEligible(page.finalUrl, country, registrant)) return null;
  const candidates = page.links.filter((link) => link.url !== excluded && link.sameHost &&
    manufacturerHostEligible(link.url, country, registrant) &&
    new URL(link.url).pathname.toLowerCase().endsWith(".pdf") &&
    /\b(?:leaflet|booklet|directions\s+for\s+use)\b/i.test(link.linkText) &&
    !/\b(?:sds|msds|safety\s+data|brochure|promo|technical\s+data)\b/i.test(link.linkText) &&
    classifyUrl(link.url, country).kind !== "safety_data_sheet" &&
    hostOf(link.url) === hostOf(page.finalUrl));
  return candidates.length === 1 ? candidates[0].url : null;
}

/** Recover an unambiguous printed grape row from a folded, multi-panel leaflet. */
export function companionGrapeDirection(items: PdfTextItem[]): Record<string, unknown> | null {
  const rows: Array<Record<string, unknown>> = [];
  for (const crop of items.filter((item) => /^grapes$/i.test(item.str.trim()))) {
    const nearby = items.filter((item) => item.page === crop.page && item.y <= crop.y + 3 &&
      item.y >= crop.y - 55 && item.x >= crop.x && item.x < crop.x + 450);
    const pests = nearby.filter((item) => item.x > crop.x + 25 && item.x < crop.x + 180 &&
      /^(downy mildew|bunch rot)$/i.test(item.str.trim()));
    const dose = nearby.filter((item) => item.x > crop.x + 110 && item.x < crop.x + 260 &&
      Math.abs(item.y - crop.y) < 3 && /^(\d+(?:\.\d+)?)\s*[–-]\s*(\d+(?:\.\d+)?)\s*kg\s*\/$/i.test(item.str.trim()));
    if (pests.length !== 2 || dose.length !== 1) continue;
    const unit = nearby.some((item) => item.x >= dose[0].x && item.x < dose[0].x + 65 &&
      item.y < dose[0].y && item.y >= dose[0].y - 16 && /^ha$/i.test(item.str.trim()));
    if (!unit) continue;
    const [, minimum, maximum] = dose[0].str.trim().match(/^(\d+(?:\.\d+)?)\s*[–-]\s*(\d+(?:\.\d+)?)\s*kg\s*\/$/i) ?? [];
    if (!(Number(minimum) > 0 && Number(maximum) >= Number(minimum))) continue;
    const whp = nearby.filter((item) => item.x > dose[0].x + 45 && item.x < dose[0].x + 115);
    const dessert = whp.some((item) => /^dessert$/i.test(item.str.trim())) &&
      whp.some((item) => /^7$/.test(item.str.trim()));
    const wine = whp.some((item) => /^wine$/i.test(item.str.trim())) &&
      whp.some((item) => /^14$/.test(item.str.trim()));
    const comments = nearby.filter((item) => item.x > dose[0].x + 100 && item.x < dose[0].x + 400)
      .sort((a, b) => b.y - a.y).map((item) => item.str.trim()).filter(Boolean).join(" ");
    rows.push({ crop: "Grapes", target_raw: "Downy mildew / Bunch rot",
      rates: [{ basis: "range_per_hectare", min_value: Number(minimum), max_value: Number(maximum),
        unit: "kg", raw_text: `${minimum} – ${maximum} kg/ha`, condition_ambiguous: false }],
      ...(dessert && wine ? { withholding_period_text: "Dessert grapes: 7 days; Wine grapes: 14 days" } : {}),
      ...(comments ? { restrictions: comments } : {}),
      provenance: { rates: "manufacturer_label" } });
  }
  return rows.length === 1 ? rows[0] : null;
}

/** A legal trading-as statement, not a similar-sounding brand, ties the company to this domain. */
/** One different label linked on the inspected page may replace a failed direct PDF. */
export function alternateManufacturerLabel(page: InspectedPage | null, product: string, country: string,
  registrant: string, failedUrl: string): string | null {
  if (!page || !pageMatchesLockedProduct(product, page.pageProductName, registrant) ||
      !manufacturerHostEligible(page.finalUrl, country, registrant)) return null;
  const candidate = page.links.find((link) => link.url !== failedUrl && link.sameHost &&
    manufacturerHostEligible(link.url, country, registrant) &&
    new URL(link.url).pathname.toLowerCase().endsWith(".pdf") &&
    /\blabel\b/i.test(link.linkText) &&
    !/\b(?:sds|msds|safety\s+data|brochure|promo|technical\s+data)\b/i.test(link.linkText));
  return candidate?.url ?? null;
}

/** The attached leaflet shares the locked registration and full product title with a previously verified container label. */
export function pairedDirectionsConfirmIdentity(text: string, product: string, registrant: string, number: string): boolean {
  if (!/^\d{4,7}$/.test(number) || !new RegExp(`(^|\\D)${number}(\\D|$)`).test(text.slice(0, 4000))) return false;
  const first = normaliseProductNameLoose(text.slice(0, 2500));
  const title = normaliseProductNameLoose(product);
  const brand = normaliseProductNameLoose(registrant).split(" ")[0];
  const titleWithoutBrand = title.startsWith(`${brand} `) ? title.slice(brand.length + 1) : title;
  const core = titleWithoutBrand.replace(/\s+(?:herbicide|fungicide|insecticide|miticide)$/, "");
  return core.length >= 12 && first.includes(core);
}

export function verifiesTradingAs(pageText: string, registrant: string): boolean {
  const legal = normaliseProductNameLoose(registrant).replace(/\b(?:pty|ltd|limited|australia)\b/g, " ").trim();
  if (legal.length < 6) return false;
  const escaped = legal.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/\s+/g, "\\s+");
  return new RegExp(`\\b${escaped}(?:\\s+(?:australia|pty|ltd|limited)){0,3}\\s+trading\\s+as\\s+[a-z0-9 ]{3,60}\\b`, "i")
    .test(normaliseProductNameLoose(pageText));
}
