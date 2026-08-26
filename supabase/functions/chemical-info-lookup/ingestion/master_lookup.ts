// Master Chemical Catalogue lookup (sql/199) — approved-master resolution,
// serving, and search listing. Extracted from index.ts with an injected
// PostgREST select so the identity rules are unit-testable.
//
// Identity discipline (Stage 1, unchanged and NOT weakened):
//   * Only review_status='approved' rows are served.
//   * Identity hint (country:scheme:number) is deterministic and wins first.
//   * A name/alias must match EXACTLY ONE approved row for the country or the
//     match is abandoned — "custodia" can never reach "Custodia Forte".
//   * Aliases are exact whole-string equality, never substrings.
//   * Never fuzzy, never cross-country.
//
// Resolver upgrade: after the verbatim name misses, the SAME exact-equality
// query is retried with the name's typography variants (compact and loose
// forms — "Spray Seal" → "sprayseal", "Custodia320SC" → "custodia 320 sc").
// Still whole-string, still unique-or-nothing; only spacing/punctuation/case
// stop mattering.

// deno-lint-ignore-file no-explicit-any

import { ACTIVITY_GROUP_TABLE_VERSION } from "./activity_groups.ts";
import type { FieldProvenance } from "./ingest.ts";
import { pruneAuthoritativelyResolvedFields } from "./ingest.ts";
import {
  compactProductName,
  normaliseProductNameLoose,
} from "./matching.ts";
import {
  projectGrapevineUses,
  selectLabelReferences,
} from "../grapevine_label.ts";
import { inspectDefaultRateOptionIdentityReadiness } from "../default_rate_options.ts";

/** PostgREST query executor over master_chemicals. Null = table unavailable. */
export type MasterSelect = (query: string) => Promise<any[] | null>;

/** PostgREST double-quoted value (for or=() expressions). */
export function pgQuote(value: string): string {
  return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

/** Escape LIKE/ILIKE wildcards so a product name is matched literally. */
export function escapeLike(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/%/g, "\\%").replace(/_/g, "\\_");
}

/**
 * Exact-equality name variants for master matching: the verbatim name first,
 * then pure-typography forms. Bounded and deduplicated; each is only ever
 * used for WHOLE-STRING equality (ilike without wildcards / exact alias).
 */
export function masterNameVariants(name: string): string[] {
  const out: string[] = [];
  const push = (v: string) => {
    const t = v.trim();
    if (t && !out.some((x) => x.toLowerCase() === t.toLowerCase())) out.push(t);
  };
  push(name);
  push(compactProductName(name));
  push(normaliseProductNameLoose(name));
  return out;
}

/**
 * Resolve the single approved master row for this request, or null.
 *
 * Identity hint first (deterministic), then exact name/alias — which must be
 * UNIQUE among approved rows for that country or nothing is returned. Never
 * fuzzy, never substring, never cross-country.
 */
export async function fetchApprovedMaster(
  select: MasterSelect,
  productName: string,
  countryCode: string,
  registrationNumber: string,
  scheme: string | null,
): Promise<any | null> {
  if (!countryCode) return null;

  // Belt-and-braces jurisdiction assertion: whatever the query matched, the
  // row itself must belong to the requested country.
  const inCountry = (row: any): boolean =>
    String(row?.registration_country ?? "").trim().toUpperCase() === countryCode;

  if (registrationNumber && scheme) {
    const key = `${countryCode}:${scheme}:${registrationNumber.trim().toUpperCase()}`;
    const rows = await select(
      `select=*&review_status=eq.approved` +
        `&registration_identity_key=eq.${encodeURIComponent(key)}&limit=1`,
    );
    if (rows && rows.length === 1 && inCountry(rows[0])) return rows[0];
  }

  const name = productName.trim();
  if (!name) return null;

  for (const variant of masterNameVariants(name)) {
    const nameExpr = `registered_product_name.ilike.${pgQuote(escapeLike(variant))}`;
    const aliasExpr = `common_names.cs.{${pgQuote(variant.toLowerCase())}}`;
    const rows = await select(
      `select=*&review_status=eq.approved` +
        `&registration_country=eq.${encodeURIComponent(countryCode)}` +
        `&or=${encodeURIComponent(`(${nameExpr},${aliasExpr})`)}&limit=2`,
    );
    if (rows && rows.length === 1 && inCountry(rows[0])) return rows[0];
    // Zero rows → try the next typography variant. More than one row → the
    // name is not unique for this country: fail closed immediately (a looser
    // variant can only be MORE ambiguous, never less).
    if (rows && rows.length > 1) return null;
  }
  return null;
}

/**
 * Whether a catalogue row is complete enough to answer a vineyard spray
 * question WITHOUT going back to the label (task Phase 10).
 *
 * # Why an approved row is not automatically a finished row
 *
 * The Master Chemical Store is a CACHE and a catalogue, not an oracle. A row
 * earns `approved` when a human confirmed that what it holds is correct --
 * which is a statement about accuracy, not about completeness. APVMA 33182 is
 * the measured case: approved, correct, carrying real grapevine targets, and
 * carrying `rates: []` with `rates:GRAPEVINE` sitting in its own unresolved
 * list. It is right about everything it says and silent about the one number
 * an operator opens the app to find.
 *
 * The fast path used to serve that row and stop. The catalogue's own honest
 * admission of incompleteness became the reason the gap was never filled --
 * the cache defended itself against the very lookup that would have repaired
 * it.
 *
 * So the row must state its own sufficiency, from evidence it already carries:
 *
 *   * a registration number, or there is no identity to enrich;
 *   * an official label reference, or nothing established the rates;
 *   * no unresolved GRAPEVINE rate entry, because that IS the row saying the
 *     vineyard-critical field is missing.
 *
 * Incomplete does NOT mean wrong, and it never means discard. It means: keep
 * this exact registration and go and finish it.
 *
 * # Default-identity readiness (Gate D4A.2)
 *
 * A fourth condition joins the three above, for a reason the first three
 * cannot express. The fast path serves a stored row DIRECTLY, so it is the one
 * exit that never passes the D1 mint point — whatever identities the row was
 * written with are the identities the operator will be asked to persist. A row
 * approved before D1 can therefore be entirely correct about its rates and
 * still unable to produce a single canonical default option, because its rates
 * carry no `rate_v1_` id.
 *
 * Such a row is INCOMPLETE for this contract in exactly the existing sense: it
 * is right about what it says, and silent about something the operator needs.
 * The remedy is the one already built — keep the registration, go and finish
 * it from the authoritative source, and let the normal lock point mint. See
 * {@link masterHasDefaultIdentityReadiness} for why the row must never be
 * repaired from its own projection instead.
 */
export function masterHasCompleteVineyardData(row: any): boolean {
  const unresolved = Array.isArray(row?.verification_unresolved_fields)
    ? row.verification_unresolved_fields.map((x: unknown) => String(x).toUpperCase())
    : [];

  // Matches "RATES:GRAPEVINE" and any qualified form the extractor emits
  // (e.g. "RATES:GRAPEVINE:POWDERY MILDEW"). A rate gap for ONE grapevine
  // target is still a rate gap.
  const grapeRatesUnresolved = unresolved.some((x: string) => x.startsWith("RATES:GRAPEVINE"));

  const hasOfficialLabel = Boolean(
    row?.regulator_label_url || row?.label_reference || row?.manufacturer_label_url,
  );

  return Boolean(row?.registration_number) && hasOfficialLabel &&
    !grapeRatesUnresolved && masterHasDefaultIdentityReadiness(row);
}

/**
 * Whether this row's eligible grapevine rates can already become persistable
 * default options (Gate D4A.2).
 *
 * # Why the row cannot simply be repaired on the way out
 *
 * The obvious fix — call the D1 minter on the served envelope — is wrong, and
 * quietly so. Older stored `registered_uses` are POST-fan-out: one printed
 * direction covering three mites was written as three target rows, and the
 * seed recording that they were one direction is not in the row. Minting from
 * what remains would create three direction identities and three rate
 * identities where the label printed one direction and one rate, which is the
 * precise invariant D1.2 exists to hold. The original grouping is not
 * recoverable from the projection, and guessing at it would manufacture
 * plausible, permanent, wrong identities.
 *
 * So a row that is not ready is not repaired here. It is treated as
 * incomplete, its exact registration is kept, and the authoritative path
 * reconstructs the label — where the direction grouping genuinely exists and
 * the mint is sound.
 *
 * Eligibility is NOT defined here. It is delegated wholesale to the Gate D4A
 * option producer, so "a rate that must carry an identity" means the same
 * thing to this gate as it does to the thing that will actually build the
 * option. Consequently, and without any rule being restated:
 *
 *   * other-crop rates are irrelevant — they can never become vineyard
 *     defaults, so their identities cannot block a vineyard fast path;
 *   * verbatim `other`-basis grapevine directions are irrelevant — they are
 *     not calculable, so they were never going to produce an option;
 *   * a product with no grapevine rates at all is ready, and serves zero
 *     options, which is a legitimate product state and not a degradation.
 *
 * Both a MISSING id and a non-`rate_v1_` id (a `direction_v1_`, a UUID, free
 * text) fail, because the producer refuses both.
 *
 * Read-only: the row is inspected, never stamped, never rewritten.
 */
export function masterHasDefaultIdentityReadiness(row: any): boolean {
  try {
    return inspectDefaultRateOptionIdentityReadiness(row?.registered_uses).ready;
  } catch (err) {
    // Readiness is a gate, not an oracle. If inspection itself fails, prefer
    // the slower authoritative path over asserting a row is ready.
    console.error(
      "master default-identity readiness check failed:",
      err instanceof Error ? err.message : String(err),
    );
    return false;
  }
}

/** Per-field provenance for a served master row: everything the row carries is catalogue-reviewed evidence. */
function masterFieldProvenance(row: any): Record<string, FieldProvenance> {
  const has = (v: unknown): boolean => v !== null && v !== undefined && v !== "";
  const of = (present: boolean): FieldProvenance => (present ? "master_catalogue" : "unresolved");
  const actives = Array.isArray(row.active_ingredients) ? row.active_ingredients : [];
  const uses = Array.isArray(row.registered_uses) ? row.registered_uses : [];
  return {
    product_name: of(has(row.registered_product_name)),
    product_category: of(has(row.product_category)),
    form_type: of(has(row.form_type)),
    registration: of(has(row.registration_number)),
    registrant: of(has(row.registrant)),
    active_ingredients: of(actives.length > 0),
    activity_groups: of((Array.isArray(row.activity_groups) ? row.activity_groups : []).length > 0),
    registered_uses: of(uses.length > 0),
    label_rates: of(uses.some((u: any) => Array.isArray(u?.rates) && u.rates.length)),
    withholding_periods: of(uses.some((u: any) => u?.withholding_period_days != null)),
    re_entry: of(uses.some((u: any) => u?.re_entry_period_hours != null)),
    restrictions: of(uses.some((u: any) => has(u?.restrictions))),
    label_version: of(has(row.label_version)),
    label_reference: of(has(row.label_reference)),
  };
}

/**
 * Serve a master row in EXACTLY the structured contract every client already
 * decodes, plus the additive master envelope. The row's own sql/194
 * verification evidence (register/label provenance recorded at review time)
 * travels with it — no AI source, no AI confidence.
 */
export function buildMasterStructuredResponse(row: any): any {
  const registeredUses = Array.isArray(row.registered_uses) ? row.registered_uses : [];

  // Grapevine-first projection, and the manufacturer/regulator label split.
  //
  // This path serves REGISTER-RESOLVED products — which is how the acceptance
  // product (APVMA 33182) actually arrives. Wiring the projection only into
  // the AI builder would have left every real register lookup on the old
  // shape, so the change would have looked correct in tests and done nothing
  // in production.
  const grapevine = projectGrapevineUses(registeredUses);
  // Production rows predate the four-way source split and carry only
  // `label_reference`. Reading the new column FIRST and falling back keeps
  // one code path serving both shapes -- no backfill, no schema redesign, and
  // no row that silently reports having no label because it was written
  // before the column existed.
  const regulatorLabelUrl = row.regulator_label_url ?? row.label_reference ?? null;
  const labelRefs = selectLabelReferences({
    manufacturerLabelUrl: row.manufacturer_label_url,
    regulatorLabelUrl,
    productUrl: row.product_url,
    sdsUrl: row.sds_url,
  });

  const served = {
    product_name: row.registered_product_name ?? null,
    product_category: row.product_category ?? "",
    form_type: row.form_type ?? null,
    registration: {
      country_code: row.registration_country ?? "",
      scheme: row.registration_scheme ?? null,
      registration_number: row.registration_number ?? null,
      registrant: row.registrant ?? null,
      registered_product_name: row.registered_product_name ?? null,
      label_reference: labelRefs.label_reference ?? row.label_reference ?? null,
      manufacturer_label_url: labelRefs.manufacturer_label_url,
      regulator_label_url: labelRefs.regulator_label_url,
      label_version: row.label_version ?? null,
    },
    // The label URLs a client can OPEN, in one predictable block.
    //
    // The registration block keeps its own fields for the clients already
    // decoding them; this is the grouped form the Review Chemical screen
    // reads, so a screen wanting "the official label" does not have to know
    // the history of three column names to find it.
    label_urls: {
      regulator_label_url: labelRefs.regulator_label_url ?? regulatorLabelUrl,
      manufacturer_label_url: labelRefs.manufacturer_label_url,
      product_url: labelRefs.manufacturer_product_url ?? row.product_url ?? null,
    },
    active_ingredients: Array.isArray(row.active_ingredients) ? row.active_ingredients : [],
    activity_groups: Array.isArray(row.activity_groups) ? row.activity_groups : [],
    activity_group_scheme: row.activity_group_scheme ?? null,
    registered_uses: registeredUses,
    grapevine_uses: grapevine.grapevine_uses,
    other_crop_uses: grapevine.other_crop_uses,
    registered_for_grapevine: grapevine.registered_for_grapevine,
    label_reference_rate_ranges: grapevine.label_reference_rate_ranges,
    label_rate_bases: Array.isArray(row.label_rate_bases) ? row.label_rate_bases : [],
    verification: {
      status: row.verification_status ?? "unverified",
      sources: Array.isArray(row.verification_sources) ? row.verification_sources : [],
      conflicts: Array.isArray(row.verification_conflicts) ? row.verification_conflicts : [],
      unresolved_fields: Array.isArray(row.verification_unresolved_fields)
        ? row.verification_unresolved_fields
        : [],
      verified_at: row.verified_at ?? null,
    },
    activity_group_table_version: row.activity_group_table_version ?? ACTIVITY_GROUP_TABLE_VERSION,
    schema_version: row.intelligence_schema_version ?? 1,
    field_provenance: masterFieldProvenance(row),
    match_source: "master",
    master: {
      master_chemical_id: row.id,
      master_revision: row.catalogue_version ?? 1,
      catalogue_status: row.review_status ?? null,
      registration_identity_key: row.registration_identity_key ?? null,
    },
  };
  // Contract invariant at serve time: rows stored before the invariant may
  // carry stale unresolved entries for fields the catalogue actually holds —
  // the serving envelope is cleaned; the stored row is never rewritten.
  pruneAuthoritativelyResolvedFields(served);
  return served;
}

/**
 * Approved master rows matching a human search, mapped to the search-result
 * shape (additive `source`/`master_chemical_id` fields). Substring matching is
 * fine HERE — this is a discovery listing a human picks from; identity is only
 * ever established by the structured lookup's exact rules. The compact
 * typography variant joins the OR so "Spray Seal" also finds "Sprayseal".
 */
export async function searchMaster(
  select: MasterSelect,
  query: string,
  countryCode: string,
): Promise<any[]> {
  try {
    if (!countryCode) return [];
    const trimmed = query.trim();
    if (!trimmed) return [];

    const exprs: string[] = [];
    for (const variant of masterNameVariants(trimmed)) {
      exprs.push(`registered_product_name.ilike.${pgQuote(`%${escapeLike(variant)}%`)}`);
      exprs.push(`common_names.cs.{${pgQuote(variant.toLowerCase())}}`);
    }
    const rows = await select(
      `select=*&review_status=eq.approved` +
        `&registration_country=eq.${encodeURIComponent(countryCode)}` +
        `&or=${encodeURIComponent(`(${exprs.join(",")})`)}` +
        `&order=registered_product_name.asc&limit=3`,
    );
    if (!rows) return [];
    return rows.map((row: any) => {
      const actives = Array.isArray(row.active_ingredients) ? row.active_ingredients : [];
      const groups = Array.isArray(row.activity_groups) ? row.activity_groups : [];
      const uses = Array.isArray(row.registered_uses) ? row.registered_uses : [];
      const firstUse = uses[0] ?? null;
      return {
        name: String(row.registered_product_name ?? ""),
        // EXACT registration identity travels with every candidate.
        //
        // A search row used to carry a name and a `master_chemical_id` and
        // nothing else, so selecting it handed the structured lookup a NAME
        // to re-resolve -- re-running fuzzy identity matching on a decision
        // the operator had already made, and giving it a fresh chance to land
        // somewhere else. Identity is decided once, here, and travels intact.
        registration_country: String(row.registration_country ?? "").toUpperCase() || null,
        registration_scheme: row.registration_scheme ?? null,
        registration_number: row.registration_number ?? null,
        product_category: row.product_category ?? null,
        // Vineyard relevance, so the picker can say which candidate is even
        // about grapevines. Derived from the row's OWN registered uses.
        has_grapevine_use: uses.some((u: any) => {
          const crop = String(u?.crop ?? "").toLowerCase();
          return crop.includes("grape") || crop.includes("vine");
        }),
        activeIngredient: actives
          .map((a: any) => {
            const conc = a?.concentration != null
              ? ` ${a.concentration}${a?.concentration_unit ? ` ${a.concentration_unit}` : ""}`
              : "";
            return `${String(a?.name ?? "").trim()}${conc}`.trim();
          })
          .filter((s: string) => s)
          .join(" + "),
        chemicalGroup: groups.join(" + "),
        brand: String(row.registrant ?? ""),
        primaryUse: firstUse
          ? [firstUse.target_raw, firstUse.crop ? `(${firstUse.crop})` : ""]
            .filter(Boolean).join(" ")
          : "",
        modeOfAction: groups.join(" + "),
        source: "master",
        master_chemical_id: row.id,
      };
    }).filter((r: any) => r.name);
  } catch (err) {
    console.error("master search skipped:", err instanceof Error ? err.message : String(err));
    return [];
  }
}
