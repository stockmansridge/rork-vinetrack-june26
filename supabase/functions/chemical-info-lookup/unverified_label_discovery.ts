// Document-only discovery when a unique regulatory registration cannot be established.
// Never promote a research lead into registration identity or invent chemistry.
import type { ChemicalResearchResult } from "./research/schema.ts";
import { classifyUrl } from "./research/classify.ts";
import { inspectCandidateProductPages } from "./research/page_inspector.ts";
import { selectManufacturerLabel } from "./research/linked_documents.ts";
import { enrichFromManufacturerLabel, verifiedManufacturerLabelUrl } from "./ingestion/manufacturer_enrichment.ts";
import { nameCorresponds } from "./ingestion/matching.ts";

export async function discoverUnverifiedLabel(
  query: string,
  research: ChemicalResearchResult,
  fetchFn: typeof fetch,
): Promise<Record<string, unknown> | null> {
  // Numbers alone are not product names; never guess a variant from an ambiguous register.
  if (!/[a-z]{3}/i.test(query) || query.trim().length < 5) return null;
  const leads = [
    ...research.documents.product_page_candidates.map((d) => d.url),
    ...research.documents.official_label_candidates.map((d) => d.linked_from_url ?? ""),
  ].filter(Boolean);
  const { pages } = await inspectCandidateProductPages({ fetchFn }, leads, "AU");
  const matches: { url: string; page: string }[] = [];
  for (const page of pages) {
    const kind = classifyUrl(page.finalUrl, "AU");
    // Without a register-locked identity, require a positively known registrant host.
    if (kind.trust !== "registrant" || !nameCorresponds(query, page.pageProductName)) continue;
    const selected = selectManufacturerLabel({
      page: { pageUrl: page.finalUrl, pageProductName: page.pageProductName },
      pageIsTrustedProductPage: true,
      pageIsVerifiedRegistrantDomain: true,
      registeredProductName: query,
      documents: page.links.filter((link) => link.url !== page.finalUrl),
    });
    if (selected.label) matches.push({ url: selected.label.url, page: page.finalUrl });
  }
  // Distinct competing documents are ambiguous. Don't choose the first one.
  const unique = [...new Map(matches.map((match) => [match.url, match])).values()];
  if (unique.length !== 1) return null;
  const accepted = unique[0];
  const enrichment = await enrichFromManufacturerLabel({
    deps: { fetchFn, now: () => new Date() },
    manufacturerLabelUrl: accepted.url,
    sourcePageUrl: accepted.page,
    regulatorUses: [],
    registeredProductName: query,
  });
  const label = verifiedManufacturerLabelUrl(enrichment);
  if (!label) return null;
  const uses = enrichment.uses;
  return {
    product_name: query,
    product_category: "",
    form_type: null,
    registration: {
      country_code: "AU", scheme: null, registration_number: null,
      registrant: null, registered_product_name: null,
      label_reference: label, manufacturer_label_url: label,
      regulator_label_url: null, manufacturer_product_url: accepted.page,
      label_version: null,
    },
    active_ingredients: [], activity_groups: [], activity_group_scheme: null,
    registered_uses: uses,
    label_rate_bases: [],
    verification: {
      status: "unverified",
      sources: [{ kind: "manufacturer_label", name: "Registrant label", reference: label, retrieved_at: new Date().toISOString() }],
      conflicts: [], unresolved_fields: ["registration", "active_ingredients"], verified_at: null,
    },
    field_provenance: { label_reference: "manufacturer_label", registered_uses: "manufacturer_label" },
    label_urls: { regulator_label_url: null, manufacturer_label_url: label, product_url: accepted.page },
    activity_group_table_version: 0, schema_version: 1,
    match_source: "unresolved",
    guidance: "APVMA registration not verified. Review the label and enter any missing details before saving.",
  };
}
