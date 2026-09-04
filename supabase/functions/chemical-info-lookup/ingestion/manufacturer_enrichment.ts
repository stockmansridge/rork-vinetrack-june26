// Stage B orchestration: turn an accepted manufacturer-label URL into the
// practical grapevine data a structured lookup serves.
//
// This is the step that was missing entirely. `authority.ts` could ACCEPT a
// manufacturer label, `manufacturer_label.ts` can READ one, and nothing joined
// the two: the URL was returned as a link and the rate table inside it was
// never fetched. That is why APVMA 33182 served `rates:GRAPEVINE unresolved`
// while its registrant published the rates on a public PDF.
//
// # Boundaries
//
//   * Identity is never read from the document and never written by it. The
//     inputs carry a registration that is already locked; this module returns
//     uses, rates, restrictions and a WHP, and nothing else.
//   * Every failure is NAMED and leaves the caller exactly where it was. The
//     regulator's data is not touched, cleared or downgraded by a manufacturer
//     document that could not be fetched or could not be read.
//   * No product is special-cased. The only inputs are an accepted URL, the
//     page it was accepted from, and the regulator's own use rows.

import type { AdapterDeps } from "./contract.ts";
import {
  extractManufacturerDocumentText,
  fetchManufacturerDocument,
  type ManufacturerFetchOutcome,
} from "./manufacturer_document.ts";
import {
  extractManufacturerLabelUses,
  manufacturerUsesToRegisteredUses,
  type PracticalSource,
  selectPracticalUses,
} from "./manufacturer_label.ts";
import { assembleTextLines } from "./label_extract.ts";
import { parseLabelStatements, whpDaysFromStatement } from "./label.ts";
import {
  isGrapevineCrop,
  projectGrapevineUses,
  selectLabelReferences,
} from "../grapevine_label.ts";
import { applyRateIdentities, type RateIdentityProduct } from "../rate_identity.ts";
import { normaliseProductNameLoose } from "./matching.ts";

/** Everything the live path needs to prove what happened, and why. */
export interface ManufacturerEnrichmentDiagnostics {
  manufacturer_label_fetch: "success" | "failure" | "skipped";
  manufacturer_label_fetch_outcome: ManufacturerFetchOutcome | "skipped";
  manufacturer_label_fetch_reason: string;
  manufacturer_label_extract: "success" | "failure" | "skipped";
  /** Document size, for a sense of what was read. Never the contents. */
  manufacturer_label_bytes: number | null;
  manufacturer_label_sha256: string | null;
  label_rows_found: number;
  grapevine_rows_found: number;
  grapevine_rates_found: number;
  withholding_period_days: number | null;
  practical_source: PracticalSource;
  practical_source_reason: string;
}

export interface ManufacturerEnrichmentResult {
  /** The use rows to serve. Falls back to the regulator's rows untouched. */
  uses: Record<string, unknown>[];
  source: PracticalSource;
  /** The manufacturer label URL actually fetched, after redirects. */
  fetchedUrl: string | null;
  withholdingPeriodDays: number | null;
  diagnostics: ManufacturerEnrichmentDiagnostics;
}

/**
 * Returns manufacturer-label evidence only after the fetched PDF was readable
 * and confirmed the locked product identity. Practical rate-source selection
 * is deliberately irrelevant: a verified label remains useful evidence even
 * when the regulator's parsed rows are more complete and continue to win.
 */
export function verifiedManufacturerLabelUrl(
  result: ManufacturerEnrichmentResult,
): string | null {
  return result.fetchedUrl &&
      result.diagnostics.manufacturer_label_fetch === "success" &&
      result.diagnostics.manufacturer_label_fetch_outcome === "fetched" &&
      result.diagnostics.manufacturer_label_extract === "success"
    ? result.fetchedUrl
    : null;
}

/**
 * The product-wide withholding statement, read from the document's own text.
 *
 * Labels state the WHP once, in prose, beneath the Directions-for-Use table
 * rather than inside it — "Withholding Periods: DO NOT apply later than one
 * day before harvest." The bounded statement grammar in `label.ts` decides
 * what counts; this only supplies it with lines.
 *
 * Returns the FIRST recognised period. A label that states different periods
 * for different crops would need per-crop binding, which is a separate
 * problem: this deliberately does not guess at one, and a document with no
 * recognised wording yields null rather than zero.
 */
function readWithholdingPeriod(items: Parameters<typeof assembleTextLines>[0]): number | null {
  const text = assembleTextLines(items).map((l) => l.text).join("\n");
  for (const statement of parseLabelStatements(text)) {
    const days = whpDaysFromStatement(statement.statement, statement.section);
    if (days !== null) return days;
  }
  return null;
}

/** Count the rate records attached to grapevine rows. */
function countGrapevineRates(uses: Record<string, unknown>[]): number {
  let n = 0;
  for (const use of uses) {
    if (!isGrapevineCrop(String(use.crop ?? ""))) continue;
    n += Array.isArray(use.rates) ? use.rates.length : 0;
  }
  return n;
}

function countGrapevineRows(uses: Record<string, unknown>[]): number {
  return uses.filter((u) => isGrapevineCrop(String(u.crop ?? ""))).length;
}

/**
 * A catalogue link is only a discovery lead until the fetched PDF confirms
 * the locked registration or registered product identity from its own text.
 */
export function manufacturerDocumentConfirmsIdentity(input: {
  text: string;
  registrationNumber?: string | null;
  registeredProductName?: string | null;
}): boolean {
  const documentText = String(input.text ?? "");
  const number = String(input.registrationNumber ?? "").trim();
  if (number && new RegExp(`(^|\\D)${number.replace(/[.*+?^${}()|[\\]\\]/g, "\\$&")}(\\D|$)`).test(documentText)) {
    return true;
  }

  const product = normaliseProductNameLoose(String(input.registeredProductName ?? ""));
  if (!product) return false;
  const haystack = normaliseProductNameLoose(documentText);
  const tokens = product.split(" ").filter((token) => token.length > 2);
  return tokens.length > 0 && tokens.every((token) => haystack.includes(token));
}

/**
 * Fetch, read and project the manufacturer's label.
 *
 * `regulatorUses` is what the lookup already had. It is returned unchanged on
 * every failure path, because an enrichment attempt that fails must leave the
 * operator exactly where they would have been — never worse off.
 */
export async function enrichFromManufacturerLabel(input: {
  deps: AdapterDeps;
  /** The URL the authority layer accepted as `manufacturer_label`, or null. */
  manufacturerLabelUrl: string | null;
  /** The product page it was accepted FROM. Required for host custody. */
  sourcePageUrl: string | null;
  /** The use rows the regulator path produced. */
  regulatorUses: Record<string, unknown>[];
  /**
   * The locked registered product, for identity minting (Gate D1.2).
   *
   * Threaded this far down because direction and rate identities must be
   * minted while a printed direction still holds its complete target set —
   * i.e. inside the projection below, before the one-target-per-row fan-out.
   */
  product?: RateIdentityProduct | null;
  /** Register-resolved name, used only to verify the fetched document. */
  registeredProductName?: string | null;
}): Promise<ManufacturerEnrichmentResult> {
  const regulatorUses = input.regulatorUses ?? [];

  const skipped = (reason: string): ManufacturerEnrichmentResult => ({
    uses: regulatorUses,
    source: regulatorUses.length ? "regulator_label" : "none",
    fetchedUrl: null,
    withholdingPeriodDays: null,
    diagnostics: {
      manufacturer_label_fetch: "skipped",
      manufacturer_label_fetch_outcome: "skipped",
      manufacturer_label_fetch_reason: reason,
      manufacturer_label_extract: "skipped",
      manufacturer_label_bytes: null,
      manufacturer_label_sha256: null,
      label_rows_found: 0,
      grapevine_rows_found: countGrapevineRows(regulatorUses),
      grapevine_rates_found: countGrapevineRates(regulatorUses),
      withholding_period_days: null,
      practical_source: regulatorUses.length ? "regulator_label" : "none",
      practical_source_reason: reason,
    },
  });

  if (!input.manufacturerLabelUrl) {
    return skipped("no manufacturer label was accepted for this product");
  }
  if (!input.sourcePageUrl) {
    return skipped(
      "no inspected product page to attribute the label to — host custody " +
        "cannot be established without the page it was linked from",
    );
  }

  const fetched = await fetchManufacturerDocument(
    input.deps,
    input.manufacturerLabelUrl,
    input.sourcePageUrl,
  );

  if (fetched.outcome !== "fetched" || !fetched.bytes) {
    // Fail closed: the regulator's rows stand exactly as they were.
    return {
      uses: regulatorUses,
      source: regulatorUses.length ? "regulator_label" : "none",
      fetchedUrl: null,
      withholdingPeriodDays: null,
      diagnostics: {
        manufacturer_label_fetch: "failure",
        manufacturer_label_fetch_outcome: fetched.outcome,
        manufacturer_label_fetch_reason: fetched.reason,
        manufacturer_label_extract: "skipped",
        manufacturer_label_bytes: null,
        manufacturer_label_sha256: null,
        label_rows_found: 0,
        grapevine_rows_found: countGrapevineRows(regulatorUses),
        grapevine_rates_found: countGrapevineRates(regulatorUses),
        withholding_period_days: null,
        practical_source: regulatorUses.length ? "regulator_label" : "none",
        practical_source_reason:
          "the manufacturer label could not be fetched, so the regulator's " +
          "data carries the lookup unchanged",
      },
    };
  }

  const items = await extractManufacturerDocumentText(input.deps, fetched.bytes);
  if (!items || items.length === 0) {
    return {
      uses: regulatorUses,
      source: regulatorUses.length ? "regulator_label" : "none",
      fetchedUrl: fetched.url,
      withholdingPeriodDays: null,
      diagnostics: {
        manufacturer_label_fetch: "success",
        manufacturer_label_fetch_outcome: fetched.outcome,
        manufacturer_label_fetch_reason: fetched.reason,
        manufacturer_label_extract: "failure",
        manufacturer_label_bytes: fetched.byteSize ?? null,
        manufacturer_label_sha256: fetched.sha256 ?? null,
        label_rows_found: 0,
        grapevine_rows_found: countGrapevineRows(regulatorUses),
        grapevine_rates_found: countGrapevineRates(regulatorUses),
        withholding_period_days: null,
        practical_source: regulatorUses.length ? "regulator_label" : "none",
        practical_source_reason:
          "the manufacturer document had no readable text layer (a scanned " +
          "label), so the regulator's data carries the lookup",
      },
    };
  }

  const documentText = assembleTextLines(items).map((line) => line.text).join("\n");
  if (!manufacturerDocumentConfirmsIdentity({
    text: documentText,
    registrationNumber: input.product?.registration_number ?? null,
    registeredProductName: input.registeredProductName ?? null,
  })) {
    return {
      uses: regulatorUses,
      source: regulatorUses.length ? "regulator_label" : "none",
      fetchedUrl: null,
      withholdingPeriodDays: null,
      diagnostics: {
        manufacturer_label_fetch: "success",
        manufacturer_label_fetch_outcome: fetched.outcome,
        manufacturer_label_fetch_reason:
          "the fetched PDF did not confirm the locked registration or registered product identity",
        manufacturer_label_extract: "failure",
        manufacturer_label_bytes: fetched.byteSize ?? null,
        manufacturer_label_sha256: fetched.sha256 ?? null,
        label_rows_found: 0,
        grapevine_rows_found: countGrapevineRows(regulatorUses),
        grapevine_rates_found: countGrapevineRates(regulatorUses),
        withholding_period_days: null,
        practical_source: regulatorUses.length ? "regulator_label" : "none",
        practical_source_reason:
          "manufacturer document identity was not confirmed, so regulator data carries the lookup",
      },
    };
  }

  const parse = extractManufacturerLabelUses(items);
  const whp = readWithholdingPeriod(items);
  const manufacturerUses = manufacturerUsesToRegisteredUses(parse.uses, {
    withholdingPeriodDays: whp,
    // Never zero-filled. A label that does not state a re-entry period has not
    // stated that there isn't one.
    reEntryPeriodHours: null,
    product: input.product ?? null,
  });

  const chosen = selectPracticalUses({ manufacturerUses, regulatorUses });

  return {
    uses: chosen.uses,
    source: chosen.source,
    fetchedUrl: fetched.url,
    withholdingPeriodDays: chosen.source === "manufacturer_label" ? whp : null,
    diagnostics: {
      manufacturer_label_fetch: "success",
      manufacturer_label_fetch_outcome: fetched.outcome,
      manufacturer_label_fetch_reason: fetched.reason,
      manufacturer_label_extract: parse.found ? "success" : "failure",
      manufacturer_label_bytes: fetched.byteSize ?? null,
      manufacturer_label_sha256: fetched.sha256 ?? null,
      label_rows_found: manufacturerUses.length,
      grapevine_rows_found: countGrapevineRows(chosen.uses),
      grapevine_rates_found: countGrapevineRates(chosen.uses),
      withholding_period_days: chosen.source === "manufacturer_label" ? whp : null,
      practical_source: chosen.source,
      practical_source_reason: chosen.reason,
    },
  };
}

/**
 * Apply an enrichment result onto an already-merged structured response.
 *
 * # Why this runs AFTER the register merge, not before
 *
 * `mergeDiscoveryIntoStructured` sets `registered_uses` from the register's
 * own label evidence and ONLY from that — `merged.registered_uses = uses`,
 * where `uses` is empty when the register produced no claims. Enriching
 * before the merge would therefore have the merge silently discard everything
 * the manufacturer label established, which is precisely the "older APVMA
 * document extraction overwrites a newer manufacturer rate set" failure.
 *
 * So the register speaks first and keeps the last word on IDENTITY, chemistry,
 * category and status. The manufacturer's current label then supplies the
 * PRACTICAL rows on top. The two authorities are not in competition: they are
 * authoritative about different things.
 */
export function applyVerifiedManufacturerLinks(
  structured: any,
  urls: { manufacturerLabelUrl: string; manufacturerProductUrl: string },
): void {
  if (!structured) return;

  const refs = selectLabelReferences({
    manufacturerLabelUrl: urls.manufacturerLabelUrl,
    // The register-confirmed legacy reference wins over manufacturer evidence.
    regulatorLabelUrl: structured.registration?.label_reference ??
      structured.registration?.regulator_label_url ?? null,
    productUrl: urls.manufacturerProductUrl,
    sdsUrl: structured.registration?.sds_url ?? null,
  });

  if (structured.registration) {
    structured.registration.manufacturer_label_url = refs.manufacturer_label_url;
    structured.registration.regulator_label_url = refs.regulator_label_url;
    structured.registration.manufacturer_product_url = refs.manufacturer_product_url;
    structured.product_url = refs.manufacturer_product_url;
    // Legacy field keeps pointing at the REGULATOR document for shipped
    // clients; the split is additive, never a replacement.
    structured.registration.label_reference = refs.label_reference ??
      structured.registration.label_reference ?? null;
  }
  structured.label_urls = {
    regulator_label_url: refs.regulator_label_url,
    manufacturer_label_url: refs.manufacturer_label_url,
    product_url: refs.manufacturer_product_url,
  };
}

export function applyManufacturerEnrichment(
  structured: any,
  result: ManufacturerEnrichmentResult,
  urls: { manufacturerLabelUrl: string | null; manufacturerProductUrl: string | null },
): void {
  if (!structured) return;

  // A linked URL becomes manufacturer-label evidence only after the fetched
  // PDF is readable and confirms the locked registration/product identity.
  // It does not need to replace the regulator as the practical rate source.
  // Discovery leads and failed/unreadable PDFs never populate final fields.
  const labelUrl = verifiedManufacturerLabelUrl(result);
  if (labelUrl && urls.manufacturerProductUrl) {
    applyVerifiedManufacturerLinks(structured, {
      manufacturerLabelUrl: labelUrl,
      manufacturerProductUrl: urls.manufacturerProductUrl,
    });
  }

  // Practical rows only change when a source actually supplied some.
  if (result.source === "manufacturer_label" && result.uses.length > 0) {
    structured.registered_uses = result.uses;
    // Enrichment REPLACES the register's rows wholesale, so the identities
    // minted during `buildStructuredResponse` went with the rows they were
    // stamped on. Re-minting here is what stops a manufacturer-sourced rate
    // reaching a client with no id at all. Deterministic, so a row that
    // survived unchanged keeps the identity it already had.
    applyRateIdentities(structured);
    const grapevine = projectGrapevineUses(result.uses);
    structured.grapevine_uses = grapevine.grapevine_uses;
    structured.other_crop_uses = grapevine.other_crop_uses;
    structured.registered_for_grapevine = grapevine.registered_for_grapevine;
    structured.label_reference_rate_ranges = grapevine.label_reference_rate_ranges;
    // The projection may copy rate objects rather than share them; stamping
    // again is idempotent and guarantees every served view carries the id.
    applyRateIdentities(structured);
    structured.label_rate_bases = Array.from(
      new Set(
        result.uses.flatMap((u) =>
          (Array.isArray(u.rates) ? u.rates : []).map((r: { basis?: string }) => r?.basis)
        ).filter(Boolean),
      ),
    );

    // The gaps this enrichment actually closed. Nothing else is touched: a
    // field is only removed from the unresolved list when the served data
    // genuinely answers it.
    const unresolved: string[] = Array.isArray(structured.verification?.unresolved_fields)
      ? structured.verification.unresolved_fields
      : [];
    const grapevineRated = grapevine.grapevine_uses.some((u: { rates?: unknown[] }) =>
      Array.isArray(u.rates) && u.rates.length > 0
    );
    structured.verification.unresolved_fields = unresolved.filter((f: string) => {
      const key = String(f).toUpperCase();
      if (key === "REGISTERED_USES") return false;
      if (grapevineRated && key.startsWith("RATES:GRAPEVINE")) return false;
      if (grapevineRated && key === "RATES") return false;
      if (
        result.withholdingPeriodDays !== null &&
        (key === "WITHHOLDING_PERIOD_DAYS" || key.startsWith("WITHHOLDING_PERIOD:GRAPEVINE"))
      ) return false;
      return true;
    }).sort();

    if (structured.field_provenance) {
      structured.field_provenance.registered_uses = "manufacturer_label";
      structured.field_provenance.label_rates = "manufacturer_label";
      if (result.withholdingPeriodDays !== null) {
        structured.field_provenance.withholding_periods = "manufacturer_label";
      }
    }
  }

  // Always observable, whatever happened.
  structured.practical_source = result.source;
}
