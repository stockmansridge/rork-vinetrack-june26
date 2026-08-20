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
      label_reference: row.label_reference ?? null,
      label_version: row.label_version ?? null,
    },
    active_ingredients: Array.isArray(row.active_ingredients) ? row.active_ingredients : [],
    activity_groups: Array.isArray(row.activity_groups) ? row.activity_groups : [],
    activity_group_scheme: row.activity_group_scheme ?? null,
    registered_uses: Array.isArray(row.registered_uses) ? row.registered_uses : [],
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
