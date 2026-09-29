import { classifyUrl, hostOf, manufacturerHostEligible } from "../research/classify.ts";
import { nameCorresponds, normaliseProductNameLoose } from "./matching.ts";
import type { InspectedPage } from "../research/page_inspector.ts";
import type { PdfTextItem } from "./contract.ts";
import { parseRateCell } from "./label_extract.ts";

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

/** Read only rows bound to one grape block of a paired leaflet's own DFU table. */
export function companionGrapeDirections(items: PdfTextItem[], productName: string): Record<string, unknown>[] | null {
  // This reader recognises a disease table, not an adjacent insect/weed panel.
  if (!/\bfungicide\b/i.test(productName)) return null;
  const blocks: Record<string, unknown>[][] = [];
  for (const crop of items.filter((item) => /^grapes$/i.test(item.str.trim()))) {
    const onPage = items.filter((item) => item.page === crop.page);
    // A printed table must state its crop, disease, rate and WHP columns on one heading row.
    const heading = onPage.filter((item) => item.y > crop.y && item.y < crop.y + 50);
    const cropHeading = heading.find((item) => Math.abs(item.x - crop.x) < 8 && /^(situation|crop|crops)$/i.test(item.str.trim()));
    const disease = heading.find((item) => item.x > crop.x + 30 && item.x < crop.x + 140 && /^disease$/i.test(item.str.trim()));
    const rateHeading = heading.find((item) => item.x > (disease?.x ?? Infinity) && item.x < crop.x + 210 && /^rate$/i.test(item.str.trim()));
    const whpHeading = heading.find((item) => item.x > (rateHeading?.x ?? Infinity) && item.x < crop.x + 270 && /^whp$/i.test(item.str.trim()));
    if (!cropHeading || !disease || !rateHeading || !whpHeading) continue;
    const nextCrop = onPage.filter((item) => item.y < crop.y - 10 && Math.abs(item.x - crop.x) < 8 &&
      /^(?!note\b)[a-z][a-z\s,-]{2,50}$/i.test(item.str.trim()) &&
      onPage.some((rate) => Math.abs(rate.y - item.y) < 3 && rate.x >= rateHeading.x - 15 &&
        rate.x < whpHeading.x - 14 && /\d/.test(rate.str)))
      .sort((a, b) => b.y - a.y)[0];
    const bottom = nextCrop?.y ?? crop.y - 220;
    const firstTarget = onPage.filter((item) => Math.abs(item.y - crop.y) < 3 &&
      item.x > crop.x + 20 && item.x < disease.x + 10 && /^[a-z][a-z\s-]+$/i.test(item.str.trim()));
    if (firstTarget.length !== 1) continue;
    const targetColumn = onPage.filter((item) => item.y <= crop.y + 2 && item.y > bottom &&
      Math.abs(item.x - firstTarget[0].x) < 1.5 && /^[a-z][a-z\s(-]+$/i.test(item.str.trim()))
      .sort((a, b) => b.y - a.y);
    const starts = targetColumn.filter((item) => onPage.some((rate) => Math.abs(rate.y - item.y) < 3 &&
      rate.x >= rateHeading.x - 15 && rate.x < whpHeading.x - 14 && /\d/.test(rate.str)));
    if (targetColumn.some((target) => !starts.some((start) => start.y >= target.y && start.y - target.y < 35))) continue;
    const whp = onPage.filter((item) => item.y <= crop.y + 3 && item.y > bottom &&
      item.x >= whpHeading.x - 8 && item.x < whpHeading.x + 30);
    const dessert = whp.find((item) => /^dessert$/i.test(item.str.trim()));
    const wine = whp.find((item) => /^wine$/i.test(item.str.trim()));
    const period = (type: PdfTextItem | undefined): string | null => {
      if (!type) return null;
      const days = whp.filter((item) => /^\d+$/.test(item.str.trim()) && item.y < type.y && item.y > type.y - 16);
      return days.length === 1 ? days[0].str.trim() : null;
    };
    const dessertDays = period(dessert);
    const wineDays = period(wine);
    if (!dessertDays || !wineDays) continue;
    // Establish the comments' left edge from the FIRST rate row, never from all
    // text to its right: adjacent folded panels can print another product there.
    const firstComments = onPage.filter((item) => Math.abs(item.y - crop.y) < 3 &&
      item.x > whpHeading.x + 20 && item.x < whpHeading.x + 95 && /[a-z]{4}/i.test(item.str));
    if (firstComments.length !== 1) continue;
    const commentX = firstComments[0].x;
    const coreName = normaliseProductNameLoose(productName).replace(/\s+fungicide$/, "");
    const generalRestraints = onPage.filter((item) => /\bDO NOT exceed\b/i.test(item.str) &&
      normaliseProductNameLoose(item.str).includes(coreName)).map((item) => item.str.trim());
    const shared = [...onPage.filter((item) => item.y > crop.y && item.y < crop.y + 60 &&
      Math.abs(item.x - commentX) < 5 && /[a-z]{4}/i.test(item.str))
      .sort((a, b) => b.y - a.y).map((item) => item.str.trim()), ...generalRestraints].join(" ");
    const rows: Record<string, unknown>[] = [];
    for (let n = 0; n < starts.length; n++) {
      const start = starts[n];
      const end = starts[n + 1]?.y ?? bottom;
      const targets = targetColumn.filter((item) => item.y <= start.y + 2 && item.y > end + 2)
        .map((item) => item.str.trim().replace(/\s*\(.*/, ""));
      const dose = onPage.filter((item) => item.y <= start.y + 2 && item.y > start.y - 16 &&
        item.x >= rateHeading.x - 15 && item.x < whpHeading.x - 14 &&
        (/\d/.test(item.str) || /^(?:ha|100\s*L)$/i.test(item.str.trim())))
        .sort((a, b) => b.y - a.y).map((item) => item.str.trim()).join("");
      const parsed = parseRateCell(dose).filter((rate) => rate.basis !== "other" && !rate.condition_ambiguous);
      if (!targets.length || parsed.length !== 1) return null;
      const comments = onPage.filter((item) => item.y <= start.y + 2 && item.y > end + 2 &&
        Math.abs(item.x - commentX) < 5 && /[a-z]{4}/i.test(item.str))
        .sort((a, b) => b.y - a.y).map((item) => item.str.trim()).join(" ");
      if (!comments) return null;
      rows.push({ crop: "Grapes", target_raw: targets.join(" / "),
        rates: [{ ...parsed[0], raw_text: dose }],
        withholding_statement: `Dessert grapes: ${dessertDays} days; Wine grapes: ${wineDays} days`,
        restrictions: [shared, comments].filter(Boolean).join(" "),
        provenance: { rates: "manufacturer_label" } });
    }
    const rateStarts = onPage.filter((item) => item.y <= crop.y + 2 && item.y > bottom &&
      item.x >= rateHeading.x - 15 && item.x < whpHeading.x - 14 && /\d/.test(item.str) &&
      !/^ha$/i.test(item.str.trim()));
    if (rows.length && rateStarts.length === rows.length) blocks.push(rows);
  }
  return blocks.length === 1 ? blocks[0] : null;
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
