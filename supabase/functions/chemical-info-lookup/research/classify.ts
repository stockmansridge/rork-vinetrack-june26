// Source classification — the server decides what a URL IS.
//
// The research model returns URLs and an opinion about each one. That
// opinion is a hint. This module re-derives the classification from the URL
// itself and from the jurisdiction's source registry, because the whole
// authority model collapses if a marketing page can talk its way into
// `registration.labelReference`.
//
// Two independent axes, deliberately not collapsed into one score:
//
//   TRUST TIER  — how much authority the HOST carries in this country.
//   DOCUMENT KIND — what the specific URL points at (label / SDS / page).
//
// A regulator host serving a search-results page is still not a label. A
// manufacturer host serving a real label PDF is label evidence. You need
// both axes to say either of those things.

/** Authority the HOST carries, for one specific country. */
export type SourceTrustTier =
  | "official_register" // the government register itself
  | "regulator" // another arm of the same government
  | "registrant" // the manufacturer/registrant's own domain
  | "viticulture_reference" // AWRI, NZW — credible, never regulatory
  | "reseller" // sells the product; discovery only
  | "search_engine" // never evidence, only a route to a source
  | "unknown";

/** What the URL points at. */
export type DocumentKind =
  | "label_document"
  | "safety_data_sheet"
  | "product_page"
  | "register_entry"
  | "search_results"
  | "category_page"
  | "other";

export interface ClassifiedUrl {
  url: string;
  domain: string;
  trust: SourceTrustTier;
  kind: DocumentKind;
  /** True only when host trust AND document kind both support a label. */
  isOfficialLabelCandidate: boolean;
  /** True only for a registrant-owned page about this product. */
  isProductPageCandidate: boolean;
  /** Why the classifier decided this — surfaced in debug output. */
  reason: string;
}

/** Register/regulator hosts by country. AU authority is never NZ authority. */
const REGULATOR_HOSTS: Record<string, { register: string[]; regulator: string[] }> = {
  AU: {
    register: ["apvma.gov.au", "elabels.apvma.gov.au", "portal.apvma.gov.au"],
    regulator: ["data.gov.au", "legislation.gov.au", "agriculture.gov.au"],
  },
  NZ: {
    register: ["acvm.mpi.govt.nz", "eatsafe.nzfsa.govt.nz", "mpi.govt.nz"],
    regulator: ["epa.govt.nz", "legislation.govt.nz", "nzfsa.govt.nz"],
  },
};

/** Credible viticulture references. Useful, never regulatory (registry §). */
const VITICULTURE_REFERENCE_HOSTS = [
  "awri.com.au",
  "nzwine.com",
  "wineaustralia.com",
];

const SEARCH_ENGINE_HOSTS = [
  "google.com",
  "google.com.au",
  "bing.com",
  "duckduckgo.com",
  "search.yahoo.com",
  "baidu.com",
  "ecosia.org",
  "startpage.com",
  "search.brave.com",
];

/**
 * Hosts that sell inputs. Genuinely useful for DISCOVERY ("who makes this?")
 * and structurally incapable of being registration evidence.
 */
const RESELLER_HOSTS = [
  "elders.com.au",
  "nutrien.com.au",
  "nutrienagsolutions.com.au",
  "landmark.com.au",
  "agworld.com",
  "farmtender.com.au",
  "amazon.com",
  "amazon.com.au",
  "ebay.com",
  "ebay.com.au",
  "alibaba.com",
  "made-in-china.com",
  "agrigem.co.uk",
  "farmgard.co.nz",
  "pggwrightson.co.nz",
  "horticentre.co.nz",
];

const RESELLER_HOST_PATTERNS = [
  /(^|\.)ruralco\./i,
  /(^|\.)agstore\./i,
  /(^|\.)farmsupplies?\./i,
  /(^|\.)cropcare(store|shop)\./i,
];

export function hostOf(url: string): string {
  try {
    return new URL(url).host.toLowerCase().replace(/^www\./, "");
  } catch {
    return "";
  }
}

function hostMatches(host: string, candidates: string[]): boolean {
  return candidates.some((c) => host === c || host.endsWith(`.${c}`));
}

/** Registrant domains for the manufacturers VineTrack actually meets. */
const REGISTRANT_HOSTS = [
  "basf.com",
  "agro.basf.com",
  "crop-solutions.basf.com.au",
  "syngenta.com",
  "syngenta.com.au",
  "syngenta.co.nz",
  "bayer.com",
  "cropscience.bayer.com.au",
  "corteva.com",
  "corteva.com.au",
  "adama.com",
  "nufarm.com",
  "nufarm.com.au",
  "upl-ltd.com",
  // UPL's corporate/product site, where the AU and NZ product pages live
  // (uplcorp.com/au/product-details/...). Same registrant, second domain —
  // completing the registry, NOT relaxing the rule: it still has to serve a
  // product page, and a reseller listing the same product still cannot.
  "uplcorp.com",
  "fmc.com",
  "sumitomo-chem.com.au",
  "agnova.com.au",
  "grochem.com",
  "grochem.co.nz",
  "sipcam.com.au",
  "campbellchemicals.com.au",
  "omnia.com.au",
  "stoller.com.au",
  "yara.com.au",
  "haifa-group.com",
  "valagro.com",
  "koppert.com",
  "biostart.co.nz",
  "zelam.com",
  "etec.co.nz",
  "nzagritrade.co.nz",
];

/** URL path/extension signals for a real label DOCUMENT. */
function looksLikeLabelPath(url: string): boolean {
  let path = "";
  let search = "";
  try {
    const u = new URL(url);
    path = u.pathname.toLowerCase();
    search = u.search.toLowerCase();
  } catch {
    return false;
  }
  const both = `${path}${search}`;
  if (/(^|[/_-])(sds|msds|safety[-_]?data)/.test(both)) return false;
  if (/\blabel\b|[/_-]label|label[/_-]|approved[-_]?label|viewlabel|getlabel/.test(both)) {
    return true;
  }
  return false;
}

function looksLikeSds(url: string): boolean {
  const lower = url.toLowerCase();
  return /(^|[/_.?&=-])(sds|msds)([/_.?&=-]|$)/.test(lower) ||
    /safety[-_\s]?data[-_\s]?sheet/.test(lower);
}

function isPdf(url: string): boolean {
  try {
    return new URL(url).pathname.toLowerCase().endsWith(".pdf");
  } catch {
    return false;
  }
}

function looksLikeSearchResults(url: string): boolean {
  try {
    const u = new URL(url);
    const path = u.pathname.toLowerCase();
    if (/\/(search|results|find|query)(\/|$)/.test(path)) return true;
    const keys = [...u.searchParams.keys()].map((k) => k.toLowerCase());
    return keys.includes("q") || keys.includes("query") || keys.includes("search");
  } catch {
    return false;
  }
}

function looksLikeCategoryPage(url: string): boolean {
  try {
    const path = new URL(url).pathname.toLowerCase();
    return /\/(category|categories|collections?|range|shop|catalogue|catalog|browse)(\/|$)/
      .test(path);
  } catch {
    return false;
  }
}

function looksLikeProductPage(url: string): boolean {
  try {
    const path = new URL(url).pathname.toLowerCase();
    if (path === "/" || path === "") return false;
    return /\/(products?|product-details?|crop-protection|solutions?|brands?|portfolio|our-products)(\/|$)/
      .test(path);
  } catch {
    return false;
  }
}

function trustFor(host: string, countryCode: string): { trust: SourceTrustTier; reason: string } {
  if (!host) return { trust: "unknown", reason: "URL could not be parsed" };

  const code = countryCode.trim().toUpperCase();
  const local = REGULATOR_HOSTS[code];
  if (local && hostMatches(host, local.register)) {
    return { trust: "official_register", reason: `${code} register host` };
  }
  if (local && hostMatches(host, local.regulator)) {
    return { trust: "regulator", reason: `${code} government host` };
  }

  // A FOREIGN regulator is explicitly not an authority here. Country is a
  // hard identity boundary (task §12): APVMA can never speak for NZ.
  for (const [otherCode, hosts] of Object.entries(REGULATOR_HOSTS)) {
    if (otherCode === code) continue;
    if (hostMatches(host, hosts.register) || hostMatches(host, hosts.regulator)) {
      return {
        trust: "unknown",
        reason: `${otherCode} regulator host carries no authority for ${code || "this country"}`,
      };
    }
  }

  if (hostMatches(host, SEARCH_ENGINE_HOSTS)) {
    return { trust: "search_engine", reason: "search engine — a route to evidence, not evidence" };
  }
  if (hostMatches(host, VITICULTURE_REFERENCE_HOSTS)) {
    return { trust: "viticulture_reference", reason: "viticulture reference source" };
  }
  if (
    hostMatches(host, RESELLER_HOSTS) ||
    RESELLER_HOST_PATTERNS.some((re) => re.test(host))
  ) {
    return { trust: "reseller", reason: "reseller/marketplace host" };
  }
  if (hostMatches(host, REGISTRANT_HOSTS)) {
    return { trust: "registrant", reason: "registrant/manufacturer host" };
  }
  return { trust: "unknown", reason: "unrecognised host" };
}

function kindFor(url: string): { kind: DocumentKind; reason: string } {
  if (looksLikeSds(url)) return { kind: "safety_data_sheet", reason: "SDS URL signature" };
  if (looksLikeSearchResults(url)) {
    return { kind: "search_results", reason: "search-results URL" };
  }
  if (looksLikeLabelPath(url)) return { kind: "label_document", reason: "label URL signature" };
  if (looksLikeCategoryPage(url)) return { kind: "category_page", reason: "category/listing URL" };
  if (looksLikeProductPage(url)) return { kind: "product_page", reason: "product page URL" };
  if (isPdf(url)) return { kind: "other", reason: "PDF with no label signature" };
  return { kind: "other", reason: "no recognised document signature" };
}

/**
 * Classify one researched URL against one jurisdiction.
 *
 * An Official Label candidate requires BOTH:
 *   * a host that is the register, another regulator arm, or the registrant, AND
 *   * a URL that looks like a label document (or a PDF on the register host).
 *
 * An SDS is never a label. A search-results page is never evidence. A
 * reseller is never authority, whatever it is serving.
 */
export function classifyUrl(
  url: string,
  countryCode: string,
  hint?: { declaredKind?: DocumentKind | null },
): ClassifiedUrl {
  const domain = hostOf(url);
  const { trust, reason: trustReason } = trustFor(domain, countryCode);
  const { kind, reason: kindReason } = kindFor(url);

  // A PDF sitting on the register host is a label even without the word
  // "label" in the path — that is how eLabels serves approved documents.
  const registerPdf = trust === "official_register" && isPdf(url) && kind !== "safety_data_sheet";
  const effectiveKind: DocumentKind = registerPdf ? "label_document" : kind;

  const hostCanCarryLabel = trust === "official_register" || trust === "regulator" ||
    trust === "registrant";
  const isOfficialLabelCandidate = hostCanCarryLabel &&
    effectiveKind === "label_document";

  const isProductPageCandidate = trust === "registrant" &&
    (effectiveKind === "product_page" ||
      (effectiveKind === "other" && !isPdf(url)));

  const parts = [trustReason, registerPdf ? "PDF on register host" : kindReason];
  if (hint?.declaredKind && hint.declaredKind !== effectiveKind) {
    parts.push(`model claimed ${hint.declaredKind}, server classified ${effectiveKind}`);
  }

  return {
    url,
    domain,
    trust,
    kind: effectiveKind,
    isOfficialLabelCandidate,
    isProductPageCandidate,
    reason: parts.join("; "),
  };
}

/** Domains the research model should PREFER, by country (task §11/§12). */
export function preferredResearchDomains(countryCode: string): string[] {
  const code = countryCode.trim().toUpperCase();
  const local = REGULATOR_HOSTS[code];
  if (!local) return [];
  return [...local.register, ...local.regulator];
}
