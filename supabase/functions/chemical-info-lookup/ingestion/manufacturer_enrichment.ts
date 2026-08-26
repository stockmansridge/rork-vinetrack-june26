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
import { applyRateIdentities } from "../rate_identity.ts";

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

  const parse = extractManufacturerLabelUses(items);
  const whp = readWithholdingPeriod(items);
  const manufacturerUses = manufacturerUsesToRegisteredUses(parse.uses, {
    withholdingPeriodDays: whp,
    // Never zero-filled. A label that does not state a re-entry period has not
    // stated that there isn't one.
    reEntryPeriodHours: null,
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
export function applyManufacturerEnrichment(
  structured: any,
  result: ManufacturerEnrichmentResult,
  urls: { manufacturerLabelUrl: string | null; manufacturerProductUrl: string | null },
): void {
  if (!structured) return;

  // URLs are recorded even when the document could not be read: knowing the
  // registrant publishes a label is useful to an operator, and the link is
  // openable by hand.
  const labelUrl = result.fetchedUrl ?? urls.manufacturerLabelUrl ?? null;
  const refs = selectLabelReferences({
    manufacturerLabelUrl: labelUrl,
    regulatorLabelUrl: structured.registration?.regulator_label_url ??
      structured.registration?.label_reference ?? null,
    productUrl: urls.manufacturerProductUrl ??
      structured.label_urls?.product_url ?? structured.product_url ?? null,
    sdsUrl: structured.registration?.sds_url ?? null,
  });

  if (structured.registration) {
    structured.registration.manufacturer_label_url = refs.manufacturer_label_url;
    structured.registration.regulator_label_url = refs.regulator_label_url;
    structured.registration.manufacturer_product_url = refs.manufacturer_product_url;
    // Legacy field keeps pointing at the REGULATOR document for shipped
    // clients; the split is additive, never a replacement.
    structured.registration.label_reference = refs.label_reference ??
      structured.registration.label_reference ?? null;
  }
  structured.label_urls = {
    regulator_label_url: refs.regulator_label_url,
    manufacturer_label_url: refs.manufacturer_label_url,
    product_url: refs.manufacturer_product_url ?? structured.label_urls?.product_url ?? null,
  };

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
