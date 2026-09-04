// Manufacturer label promotion via a trusted product-page RELATIONSHIP.
//
// # The defect this closes
//
// `classifyUrl` decides what a URL is from the URL alone. That works for
// eLabels (`80160ELBL.pdf`) and for registrants who put "label" in the path.
// It fails for a registrant who does not:
//
//   https://www.omnia.com.au/files/2025/07/Sprayseal%205L_Digi.pdf
//
// `omnia.com.au` IS a registered registrant host, but the filename carries no
// label signature, so `kindFor` returns `other` ("PDF with no label
// signature"), `isOfficialLabelCandidate` is false, and the real manufacturer
// label — the one stating 30 mL/100 L and the re-entry condition — never
// becomes evidence.
//
// # Why the obvious fix is wrong
//
// "Treat every registrant PDF as a label" would promote brochures, technical
// data sheets, price lists and SDSs. A brochure's marketing rate would then
// arrive with the same authority as an approved label.
//
// # The mechanism
//
// A registrant PDF may be promoted to `manufacturer_label` ONLY when ALL of:
//
//   1. it was found ON a trusted registrant product page (not a search result,
//      not a reseller, not a bare URL the model recalled);
//   2. that page's product identity CORRESPONDS to the register-resolved
//      product (deterministic name matching — never fuzzy);
//   3. the PDF is on the SAME registrant host as the page — a third-party PDF
//      linked from a manufacturer page is still a third party;
//   4. the link text or its surrounding context explicitly identifies it as a
//      label ("Label", "Product Label", "Registered Label");
//   5. the link text does NOT identify it as an SDS, brochure or TDS.
//
// Search engines are discovery routes and can never satisfy (1).
//
// This ADDS complementary manufacturer evidence. The APVMA remains the
// authority for Australian registration identity — promotion here never
// touches the registration number, the registered name or the registrant.

import { hostOf } from "./classify.ts";
import { nameCorresponds, normaliseProductNameLoose } from "../ingestion/matching.ts";

/** How a linked document was identified, for provenance and debugging. */
export type LinkPromotionOutcome =
  | "promoted_manufacturer_label"
  | "rejected_untrusted_page"
  | "rejected_product_mismatch"
  | "rejected_catalogue_link_identity"
  | "rejected_cross_host"
  | "rejected_not_label_text"
  | "rejected_excluded_kind"
  | "rejected_not_pdf";

export interface LinkedDocument {
  url: string;
  /** The anchor text, plus any nearby heading/caption the crawler captured. */
  linkText: string;
}

export interface ProductPageContext {
  /** The page the links were found on. */
  pageUrl: string;
  /** The product name the PAGE is about, as stated by the page. */
  pageProductName: string;
}

export interface LinkPromotionInput {
  page: ProductPageContext;
  /** Whether `classifyUrl` judged the page safe to inspect for registrant evidence. */
  pageIsTrustedProductPage: boolean;
  /** Whether the host is positively recognised as the registrant/manufacturer. */
  pageIsVerifiedRegistrantDomain?: boolean;
  /** The register-resolved product name. Identity comes from the register. */
  registeredProductName: string;
  document: LinkedDocument;
}

export interface LinkPromotionResult {
  outcome: LinkPromotionOutcome;
  /** True only for `promoted_manufacturer_label`. */
  isManufacturerLabel: boolean;
  reason: string;
}

/**
 * Link wording that explicitly identifies an approved label.
 *
 * Whole-word matching. "Labelling information" is a page section, not a
 * document, so `label` must stand as its own word rather than a prefix.
 */
const LABEL_LINK_PATTERNS: RegExp[] = [
  /\blabels?\b/i,
  /\bproduct\s+labels?\b/i,
  /\bregistered\s+labels?\b/i,
  /\bapproved\s+labels?\b/i,
  /\bapvma\s+labels?\b/i,
];

/**
 * Wording that identifies a DIFFERENT kind of document.
 *
 * Checked first and wins outright. "Label & SDS" is a combined link and must
 * not be promoted: which document it resolves to is unknowable from the text,
 * and guessing would put an SDS's handling text where label rates belong.
 */
const SDS_LINK_PATTERN = /\bsds\b|\bmsds\b|safety\s*data\s*sheet/i;

const EXCLUDED_LINK_PATTERNS: { pattern: RegExp; kind: string }[] = [
  { pattern: SDS_LINK_PATTERN, kind: "SDS" },
  { pattern: /\bbrochures?\b/i, kind: "brochure" },
  { pattern: /\bflyers?\b/i, kind: "flyer" },
  { pattern: /\btds\b|technical\s*data\s*sheet/i, kind: "TDS" },
  { pattern: /\bspec(ification)?\s*sheets?\b/i, kind: "specification sheet" },
  { pattern: /\bprice\s*lists?\b/i, kind: "price list" },
  { pattern: /\bcatalogues?\b|\bcatalogs?\b/i, kind: "catalogue" },
  { pattern: /\btrial\s*(data|results?)\b/i, kind: "trial data" },
  { pattern: /\bcase\s*stud(y|ies)\b/i, kind: "case study" },
];

function catalogueLinkNamesRegisteredProduct(registeredName: string, linkText: string): boolean {
  const documentWords = new Set([
    "label",
    "labels",
    "product",
    "approved",
    "registered",
    "apvma",
    "download",
  ]);
  const identityTokens = (value: string): string[] =>
    normaliseProductNameLoose(value)
      .split(" ")
      .filter((token) => token.length > 0 && !documentWords.has(token));
  const registered = identityTokens(registeredName);
  const linked = identityTokens(linkText);
  if (linked.join("").length < 8) return false;
  if (registered.join("") === linked.join("")) return true;

  // Registrant catalogues commonly omit the company/house-brand prefix from
  // each anchor ("Greenshield … Label" on a product registered as
  // "CropSure Greenshield … Fungicide"). On a positively verified registrant
  // catalogue, allow exactly that ONE leading token to be absent. Every
  // product, strength, formulation and variant token must otherwise remain in
  // order and match exactly; the fetched PDF must still confirm identity from
  // its own bytes before it can become evidence.
  return registered.length === linked.length + 1 &&
    registered.slice(1).every((token, index) => token === linked[index]);
}

function isGenericCatalogueHeading(value: string): boolean {
  const normalised = normaliseProductNameLoose(value);
  return /^(fungicides?|herbicides?|insecticides?|adjuvants?|products?|catalog(?:ue)?)$/.test(normalised);
}

function isPdfUrl(url: string): boolean {
  try {
    return new URL(url).pathname.toLowerCase().endsWith(".pdf");
  } catch {
    return false;
  }
}

/** Registrable domain comparison, so `www.` and sub-hosts still match. */
function sameRegistrantHost(a: string, b: string): boolean {
  const ha = hostOf(a);
  const hb = hostOf(b);
  if (!ha || !hb) return false;
  if (ha === hb) return true;
  return ha.endsWith(`.${hb}`) || hb.endsWith(`.${ha}`);
}

/**
 * Decide whether one linked PDF may become manufacturer label evidence.
 *
 * Every rejection is NAMED. A silent "no" here is indistinguishable from a
 * crawler that found nothing, and this is exactly the code path a future
 * "why is the label missing?" investigation will start from.
 */
export function evaluateLinkedDocument(
  input: LinkPromotionInput,
): LinkPromotionResult {
  const { page, document, registeredProductName } = input;
  const text = (document.linkText ?? "").trim();

  if (!input.pageIsTrustedProductPage) {
    return {
      outcome: "rejected_untrusted_page",
      isManufacturerLabel: false,
      reason:
        "the linking page is not a trusted registrant product page — search " +
        "engines and resellers are discovery routes, never evidence",
    };
  }

  // Product pages normally establish identity through their own H1/title.
  // A registrant catalogue may use a generic heading (for example
  // "Fungicide"); that narrower path is available only on a positively
  // verified registrant domain and only when the link wording itself names
  // the complete registered product. All document-kind checks below still
  // apply, and the PDF must subsequently prove identity from its own bytes.
  const pageCorresponds = nameCorresponds(registeredProductName, page.pageProductName);
  const cataloguePage = input.pageIsVerifiedRegistrantDomain === true &&
    isGenericCatalogueHeading(page.pageProductName);
  const catalogueLinkCorresponds = cataloguePage &&
    catalogueLinkNamesRegisteredProduct(registeredProductName, text);
  if (!pageCorresponds && !catalogueLinkCorresponds) {
    return {
      outcome: cataloguePage
        ? "rejected_catalogue_link_identity"
        : "rejected_product_mismatch",
      isManufacturerLabel: false,
      reason: cataloguePage
        ? `the catalogue page is generic and link text "${text}" does not correspond to ` +
          `the registered product "${registeredProductName}"`
        : `the page is about "${page.pageProductName}", which does not ` +
          `correspond to the registered product "${registeredProductName}"`,
    };
  }

  if (!sameRegistrantHost(document.url, page.pageUrl)) {
    return {
      outcome: "rejected_cross_host",
      isManufacturerLabel: false,
      reason:
        "the PDF is hosted off the registrant's domain — a third-party " +
        "document linked from a manufacturer page is still a third party",
    };
  }

  if (!isPdfUrl(document.url)) {
    return {
      outcome: "rejected_not_pdf",
      isManufacturerLabel: false,
      reason: "only a document file can be a label; this link is not a PDF",
    };
  }

  // Excluded kinds win over label wording, so "Label & SDS" is refused rather
  // than resolved by guesswork.
  for (const { pattern, kind } of EXCLUDED_LINK_PATTERNS) {
    if (pattern.test(text)) {
      return {
        outcome: "rejected_excluded_kind",
        isManufacturerLabel: false,
        reason: `link text identifies this as a ${kind}, not an approved label`,
      };
    }
  }

  if (!LABEL_LINK_PATTERNS.some((p) => p.test(text))) {
    return {
      outcome: "rejected_not_label_text",
      isManufacturerLabel: false,
      reason: text
        ? `link text "${text}" does not explicitly identify a label`
        : "the link carried no text identifying it as a label",
    };
  }

  return {
    outcome: "promoted_manufacturer_label",
    isManufacturerLabel: true,
    reason:
      `identified as the manufacturer label by the link text "${text}" on the ` +
      `registrant's own ${pageCorresponds ? "product page" : "catalogue page"} for ` +
      `"${registeredProductName}"`,
  };
}

/**
 * Pick the manufacturer's SDS from the documents linked on a product page.
 *
 * A SEPARATE identity, deliberately. The SDS is genuinely useful to an
 * operator and genuinely worthless as label evidence, so it gets its own
 * field and its own selector rather than being squeezed through the label
 * path and filtered out later.
 *
 * The trust requirements are identical to the label's — trusted page,
 * corresponding product, same host, a real PDF — because an SDS attributed to
 * the wrong product is its own hazard. The wording test is inverted: the link
 * must say SDS, and a combined "Label & SDS" link is refused here too, for the
 * same reason it is refused as a label. Which document it resolves to is
 * unknowable from the text.
 */
export function selectManufacturerSds(input: {
  page: ProductPageContext;
  pageIsTrustedProductPage: boolean;
  pageIsVerifiedRegistrantDomain?: boolean;
  registeredProductName: string;
  documents: LinkedDocument[];
}): { sds: LinkedDocument | null; reason: string } {
  if (!input.pageIsTrustedProductPage) {
    return { sds: null, reason: "the linking page is not a trusted registrant product page" };
  }
  if (!nameCorresponds(input.registeredProductName, input.page.pageProductName)) {
    return {
      sds: null,
      reason:
        `the page is about "${input.page.pageProductName}", which does not ` +
        `correspond to the registered product "${input.registeredProductName}"`,
    };
  }

  for (const document of input.documents ?? []) {
    const text = (document.linkText ?? "").trim();
    if (!SDS_LINK_PATTERN.test(text)) continue;
    // Ambiguous combined link: refused rather than resolved by guesswork.
    if (LABEL_LINK_PATTERNS.some((p) => p.test(text))) continue;
    if (!sameRegistrantHost(document.url, input.page.pageUrl)) continue;
    if (!isPdfUrl(document.url)) continue;
    return {
      sds: document,
      reason:
        `identified as the safety data sheet by the link text "${text}" on the ` +
        `registrant's own product page`,
    };
  }
  return { sds: null, reason: "no linked document qualified as an SDS" };
}

/**
 * Pick the manufacturer label from the documents linked on a product page.
 *
 * Returns the first promotable link in page order, plus every rejection so a
 * support conversation can see what was considered and why it was refused.
 */
export function selectManufacturerLabel(input: {
  page: ProductPageContext;
  pageIsTrustedProductPage: boolean;
  pageIsVerifiedRegistrantDomain?: boolean;
  registeredProductName: string;
  documents: LinkedDocument[];
}): {
  label: LinkedDocument | null;
  reason: string;
  rejected: { url: string; outcome: LinkPromotionOutcome; reason: string }[];
} {
  const rejected: { url: string; outcome: LinkPromotionOutcome; reason: string }[] = [];
  for (const document of input.documents ?? []) {
    const result = evaluateLinkedDocument({
      page: input.page,
      pageIsTrustedProductPage: input.pageIsTrustedProductPage,
      pageIsVerifiedRegistrantDomain: input.pageIsVerifiedRegistrantDomain,
      registeredProductName: input.registeredProductName,
      document,
    });
    if (result.isManufacturerLabel) {
      return { label: document, reason: result.reason, rejected };
    }
    rejected.push({
      url: document.url,
      outcome: result.outcome,
      reason: result.reason,
    });
  }
  return { label: null, reason: "no linked document qualified", rejected };
}
