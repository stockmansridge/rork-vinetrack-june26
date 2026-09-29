import type { AdapterDeps } from "./contract.ts";
import { enrichFromManufacturerLabel } from "./manufacturer_enrichment.ts";
import type { ReviewedVisualDeclaration } from "./reviewed_visual_evidence.ts";
import type { WireActiveIngredient } from "./contract.ts";
import { classifyUrl, manufacturerHostEligible } from "../research/classify.ts";

/** Observed Download Label link on the locked Nufarm product page; this is a fetch lead, not verified evidence. */
export const WEEDMASTER_LABEL_LEAD = "https://cdn.nufarm.com/wp-content/uploads/sites/22/2018/05/13085258/0533-Nufarm-Weedmaster-DUO-Herbicide.pdf";
export const WEEDMASTER_PRODUCT_PAGE = "https://nufarm.com/au/product/weedmaster-duo/";

type Rejection = "not_https_pdf" | "host_not_verified" | "excluded_document_kind" |
  "document_kind_unrecognised" | "product_relationship_unverified";

/** An exact, locked Master identity may supply this observed pair as a lead, never as verified evidence. */
export function documentedWeedmasterLead(input: {
  registrationIdentityKey?: string | null;
  country: string;
  registrationNumber: string | null;
  registeredProductName: string;
  registrant: string;
}): string | null {
  return input.registrationIdentityKey === "AU:apvma:53576" && input.country === "AU" &&
    input.registrationNumber === "53576" &&
    input.registeredProductName === "Nufarm Weedmaster DUO Herbicide" &&
    input.registrant === "NUFARM AUSTRALIA LIMITED" ? WEEDMASTER_LABEL_LEAD : null;
}

function leadEligibility(url: string, country: string, registrant: string,
  documented: boolean, productPageUrl: string | null, storedPdf = false): Rejection | null {
  if (!url.startsWith("https://")) return "not_https_pdf";
  if ((documented || storedPdf) && !new URL(url).pathname.toLowerCase().endsWith(".pdf")) return "not_https_pdf";
  if (!manufacturerHostEligible(url, country, registrant)) return "host_not_verified";
  const kind = classifyUrl(url, country).kind;
  if (kind === "safety_data_sheet" || /(?:^|[/_.-])(?:sds|msds|brochure|technical[-_ ]?data|tds)(?:[/_.-]|$)/i.test(new URL(url).pathname))
    return "excluded_document_kind";
  if (documented) {
    if (url !== WEEDMASTER_LABEL_LEAD || productPageUrl !== WEEDMASTER_PRODUCT_PAGE ||
      !manufacturerHostEligible(productPageUrl, country, registrant)) return "product_relationship_unverified";
    return null; // The observed link text, not the filename, identifies this document as a label lead.
  }
  if (storedPdf) return null;
  if (classifyUrl(url, country).trust !== "registrant") return "host_not_verified";
  return kind === "label_document" ? null : "document_kind_unrecognised";
}

/** The same selection and enrichment route is used by the live lookup and mocked regression. */
export async function selectAndFetchManufacturerLead(input: {
  deps: AdapterDeps;
  country: string;
  registrant: string;
  registeredProductName: string;
  registrationNumber: string | null;
  activeNames?: string[];
  lockedActives?: WireActiveIngredient[];
  lockedFormType?: string | null;
  reviewedVisualDeclaration?: ReviewedVisualDeclaration | null;
  productPageUrl: string | null;
  documentedProductPageUrl?: string | null;
  inspectedPageUrl?: string | null;
  linkedLabel: string | null;
  directCandidate: string | null;
  storedLabelUrls: string[];
  documentedLead: string | null;
  regulatorUses: Record<string, unknown>[];
}) {
  const { country, registrant, productPageUrl } = input;
  const documentedRejection = input.documentedLead
    ? leadEligibility(input.documentedLead, country, registrant, true,
      input.documentedProductPageUrl ?? productPageUrl) : null;
  const candidate = input.directCandidate;
  const stored = !!candidate && input.storedLabelUrls.includes(candidate);
  const candidateRejection = candidate
    ? leadEligibility(candidate, country, registrant, false, productPageUrl,
      stored && candidate.startsWith("https://") && new URL(candidate).pathname.toLowerCase().endsWith(".pdf"))
    : null;
  const directLabel = candidate && !candidateRejection ? candidate :
    input.documentedLead && !documentedRejection ? input.documentedLead : null;
  const manufacturerLabel = input.linkedLabel ?? directLabel;
  const labelSource = input.linkedLabel ? input.inspectedPageUrl ?? productPageUrl : directLabel === input.documentedLead
    ? input.documentedProductPageUrl ?? productPageUrl : directLabel === candidate && productPageUrl ? productPageUrl : directLabel;
  const enrichment = manufacturerLabel && labelSource ? await enrichFromManufacturerLabel({
    deps: input.deps, manufacturerLabelUrl: manufacturerLabel, sourcePageUrl: labelSource,
    regulatorUses: input.regulatorUses, registeredProductName: input.registeredProductName,
    activeNames: input.activeNames, lockedActives: input.lockedActives,
    lockedFormType: input.lockedFormType,
    reviewedVisualDeclaration: input.reviewedVisualDeclaration,
    ...(input.registrationNumber ? { product: { country, scheme: "apvma", registration_number: input.registrationNumber } } : {}),
  }) : null;
  return { directLabel, manufacturerLabel, labelSource, enrichment,
    documented: { lead: input.documentedLead, eligible: !!input.documentedLead && !documentedRejection,
      rejection: documentedRejection, selected: !!input.documentedLead && manufacturerLabel === input.documentedLead },
    candidateRejection,
  };
}
