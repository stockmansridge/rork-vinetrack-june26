// Stage 5 — AWRI "Dog Book" seed dry-run module (Master Chemical Catalogue).
//
// Resolves the versioned AWRI 2026/27 seed manifest
// (ingestion/seeds/awri_dogbook_2026_27.json) against an APVMA PubCRIS
// register snapshot and classifies every seed name. PURE and deterministic:
// no network, no database, no clock — the runner supplies the snapshot, and
// the same inputs always produce byte-identical output.
//
// TRUST MODEL (unchanged from Stages 3-4)
//   * AWRI is viticulture COVERAGE/REFERENCE only (`viticulture_reference`).
//     It contributes which products are worth seeding — never registration,
//     label, chemistry, WHP, or re-entry facts. Nothing in this module can
//     carry an AWRI re-entry code or activity group into a catalogue fact.
//   * The APVMA register remains the sole registration authority. Name
//     resolution reuses the adapter's deterministic discipline VERBATIM
//     (normaliseProductName / selectProductRow): exact normalised equality
//     first, the formulation-suffix rule second, any tie fails closed.
//     Substring/fuzzy resolution is structurally impossible — "Custodia"
//     can never reach "CUSTODIA FORTE".
//   * The AWRI booklet publishes NO registration numbers, so identity comes
//     exclusively from the register row the discipline selects; dedupe is by
//     `AU:apvma:<number>` ONLY, never by name similarity.
//   * A name that does not resolve stays visible as unresolved — it is never
//     silently replaced by a similarly named current product. Products on
//     AWRI's own cancelled list classify as conflict/cancelled even when a
//     current register row matches their name.
//   * DRY RUN: this module performs zero writes and never touches MasterOps.
//     Seeding candidates is a separate, later step that runs each resolved
//     registration number through the existing ingestion pipeline
//     (ingest.ts) — candidates only, never auto-approved.

import { normaliseProductName, selectProductRow } from "./apvma.ts";
import type { SelectionMode } from "./matching.ts";
import { identityKey } from "./contract.ts";

// ---------------------------------------------------------------------------
// Manifest shapes (ingestion/seeds/awri_dogbook_2026_27.json)
// ---------------------------------------------------------------------------

export interface AwriSeedEntry {
  awri_product_name: string;
  /** Always null — the AWRI booklet publishes no APVMA numbers. */
  apvma_registration_number: string | null;
  active_constituents: string[];
  /** AWRI reference metadata only — never written to catalogue facts. */
  activity_groups: string[];
  /** AWRI reference metadata only — never written to catalogue facts. */
  re_entry_codes: string[];
  sections: string[];
  expansion: "plain" | "variant" | "bare_parent";
  listed_as: string[];
}

export interface AwriCancelledEntry {
  awri_product_name: string;
  active_constituent: string;
  status: string;
  last_use_date: string;
}

export interface AwriSeedManifest {
  manifest_version: number;
  source: Record<string, string>;
  table2_rows_transcribed: number;
  entries: AwriSeedEntry[];
  cancelled_products: AwriCancelledEntry[];
}

/** Register snapshot row (PubCRIS product.csv fields the discipline needs). */
export interface RegisterProductRow {
  pcode: string;
  fpname: string;
  sname: string | null;
  hlevel1: string | null;
  fdesc: string | null;
  regcode: string | null;
  expdate: string | null;
}

// ---------------------------------------------------------------------------
// Outcomes
// ---------------------------------------------------------------------------

export type SeedOutcomeKind =
  | "resolved_current" // unique register match, regcode R (registered)
  | "resolved_not_current" // unique register match, but not currently registered
  | "unresolved_no_match" // no deterministic register match (NOT "not registered")
  | "unresolved_ambiguous"; // >1 register row matched — fails closed

export interface SeedResolution {
  awri_product_name: string;
  expansion: AwriSeedEntry["expansion"];
  sections: string[];
  kind: SeedOutcomeKind;
  /** True when the name is on AWRI's cancelled-products list (booklet p.29). */
  awri_cancelled_listed: boolean;
  registration_number: string | null;
  registration_identity_key: string | null;
  registered_product_name: string | null;
  registrant: string | null;
  /** Register lifecycle, e.g. "R, expires 30/06/2029 0:00". */
  register_status: string | null;
  /** Selection tier from the shared deterministic matcher (matching.ts). */
  match_mode: SelectionMode | null;
}

export interface CancelledListResolution {
  awri_product_name: string;
  awri_status: string;
  last_use_date: string;
  kind: SeedOutcomeKind;
  registration_number: string | null;
  registration_identity_key: string | null;
  registered_product_name: string | null;
  register_status: string | null;
}

export interface DuplicateIdentity {
  registration_identity_key: string;
  awri_product_names: string[];
}

export interface SeedDryRunCounts {
  unique_products_found: number;
  names_resolved_total: number;
  with_apvma_registration_identities: number;
  candidate_eligible_identities: number;
  /** Pending manual SQL — this dry run has no database access. */
  already_in_master: null;
  /** Pending manual SQL — this dry run has no database access. */
  would_create_candidates: null;
  unresolved_total: number;
  unresolved_no_match: number;
  unresolved_ambiguous: number;
  /** Unresolved names synthesised by the bare-parent expansion rule. */
  unresolved_bare_parent_synthetic: number;
  conflicts_cancelled_lapsed: number;
  duplicate_identities_removed: number;
  database_changes: 0;
  production_writes: 0;
}

export interface SeedDryRunResult {
  seed_source: Record<string, string>;
  manifest_version: number;
  resolutions: SeedResolution[];
  cancelled_list_resolutions: CancelledListResolution[];
  /** Deduped AU:apvma:<n> identities eligible for candidate creation. */
  candidate_identities: string[];
  /** Deduped identities that resolved but sit in the conflict bucket. */
  conflict_identities: string[];
  duplicates: DuplicateIdentity[];
  counts: SeedDryRunCounts;
  invariants: {
    apvma_remains_authoritative: "PASS" | "FAIL";
    dry_run_no_writes: "PASS" | "FAIL";
  };
}

// ---------------------------------------------------------------------------
// Deterministic resolution against a register snapshot
// ---------------------------------------------------------------------------

interface IndexedRow {
  row: RegisterProductRow;
  norm: string;
}

/**
 * Shortlist register rows that could correspond to a requested name under
 * the pipeline's discipline (equal normalised name, or normalised name plus
 * additional tokens). The FINAL decision — exact tier, suffix tier, tie
 * fails closed — is delegated to the adapter's own selectProductRow so the
 * seed process can never be looser than live ingestion.
 */
function buildIndex(rows: RegisterProductRow[]): Map<string, IndexedRow[]> {
  const byFirstToken = new Map<string, IndexedRow[]>();
  for (const row of rows) {
    if (!row?.pcode || !row?.fpname) continue;
    const norm = normaliseProductName(row.fpname);
    if (!norm) continue;
    const first = norm.split(" ")[0];
    const bucket = byFirstToken.get(first);
    const indexed: IndexedRow = { row, norm };
    if (bucket) bucket.push(indexed);
    else byFirstToken.set(first, [indexed]);
  }
  return byFirstToken;
}

function shortlist(
  index: Map<string, IndexedRow[]>,
  requestedName: string,
): RegisterProductRow[] {
  const wanted = normaliseProductName(requestedName);
  if (!wanted) return [];
  const pool = index.get(wanted.split(" ")[0]) ?? [];
  const prefix = `${wanted} `;
  return pool
    .filter((i) => i.norm === wanted || i.norm.startsWith(prefix))
    .map((i) => i.row);
}

function registerStatusOf(row: RegisterProductRow): string | null {
  return [
    row.regcode ? String(row.regcode).trim() : null,
    row.expdate ? `expires ${String(row.expdate).trim()}` : null,
  ].filter(Boolean).join(", ") || null;
}

/** PubCRIS regcode "R" = currently registered. Anything else is not current. */
function isCurrentRegcode(regcode: string | null): boolean {
  return (regcode ?? "").trim().toUpperCase() === "R";
}

interface NameResolution {
  kind: SeedOutcomeKind;
  row: RegisterProductRow | null;
  /** Selection tier from the shared deterministic matcher (matching.ts). */
  matchMode: SelectionMode | null;
}

function resolveName(
  index: Map<string, IndexedRow[]>,
  name: string,
): NameResolution {
  const candidates = shortlist(index, name);
  const selection = selectProductRow([name], candidates);
  if (selection === "ambiguous") {
    return { kind: "unresolved_ambiguous", row: null, matchMode: null };
  }
  if (!selection) {
    return { kind: "unresolved_no_match", row: null, matchMode: null };
  }
  const row = selection.row as RegisterProductRow;
  return {
    kind: isCurrentRegcode(row.regcode) ? "resolved_current" : "resolved_not_current",
    row,
    matchMode: selection.mode,
  };
}

// ---------------------------------------------------------------------------
// The dry run
// ---------------------------------------------------------------------------

export function runSeedDryRun(
  manifest: AwriSeedManifest,
  registerRows: RegisterProductRow[],
): SeedDryRunResult {
  const index = buildIndex(registerRows);

  const cancelledNames = new Set(
    manifest.cancelled_products.map((c) => normaliseProductName(c.awri_product_name)),
  );

  // Deterministic order: resolutions sorted by normalised seed name.
  const entries = [...manifest.entries].sort((a, b) =>
    normaliseProductName(a.awri_product_name) < normaliseProductName(b.awri_product_name) ? -1 : 1
  );

  const resolutions: SeedResolution[] = [];
  for (const entry of entries) {
    const res = resolveName(index, entry.awri_product_name);
    const row = res.row;
    resolutions.push({
      awri_product_name: entry.awri_product_name,
      expansion: entry.expansion,
      sections: entry.sections,
      kind: res.kind,
      awri_cancelled_listed: cancelledNames.has(
        normaliseProductName(entry.awri_product_name),
      ),
      registration_number: row ? String(row.pcode).trim() : null,
      registration_identity_key: row
        ? identityKey("AU", "apvma", String(row.pcode))
        : null,
      registered_product_name: row ? String(row.fpname).trim() : null,
      registrant: row?.sname ? String(row.sname).trim() : null,
      register_status: row ? registerStatusOf(row) : null,
      match_mode: res.matchMode,
    });
  }

  const cancelledResolutions: CancelledListResolution[] = manifest.cancelled_products.map(
    (c) => {
      const res = resolveName(index, c.awri_product_name);
      const row = res.row;
      return {
        awri_product_name: c.awri_product_name,
        awri_status: c.status,
        last_use_date: c.last_use_date,
        kind: res.kind,
        registration_number: row ? String(row.pcode).trim() : null,
        registration_identity_key: row
          ? identityKey("AU", "apvma", String(row.pcode))
          : null,
        registered_product_name: row ? String(row.fpname).trim() : null,
        register_status: row ? registerStatusOf(row) : null,
      };
    },
  );

  // ---- Dedupe by AU:apvma:<number> ONLY --------------------------------
  const candidateByIdentity = new Map<string, string[]>();
  const conflictIdentities = new Set<string>();
  let resolvedNameCount = 0;

  for (const r of resolutions) {
    if (!r.registration_identity_key) continue;
    resolvedNameCount += 1;
    const isConflict = r.kind === "resolved_not_current" || r.awri_cancelled_listed;
    if (isConflict) {
      conflictIdentities.add(r.registration_identity_key);
      continue;
    }
    const names = candidateByIdentity.get(r.registration_identity_key);
    if (names) names.push(r.awri_product_name);
    else candidateByIdentity.set(r.registration_identity_key, [r.awri_product_name]);
  }
  for (const c of cancelledResolutions) {
    if (c.registration_identity_key) conflictIdentities.add(c.registration_identity_key);
  }
  // An identity can never sit in both buckets: conflict wins (fail safe).
  for (const identity of conflictIdentities) candidateByIdentity.delete(identity);

  const numericIdentity = (key: string): number =>
    Number.parseInt(key.split(":")[2] ?? "", 10) || 0;
  const candidateIdentities = Array.from(candidateByIdentity.keys()).sort(
    (a, b) => numericIdentity(a) - numericIdentity(b),
  );
  const duplicates: DuplicateIdentity[] = candidateIdentities
    .filter((k) => (candidateByIdentity.get(k)?.length ?? 0) > 1)
    .map((k) => ({
      registration_identity_key: k,
      awri_product_names: candidateByIdentity.get(k) ?? [],
    }));
  const duplicateNamesRemoved = duplicates.reduce(
    (acc, d) => acc + d.awri_product_names.length - 1,
    0,
  );

  // ---- Buckets ----------------------------------------------------------
  const unresolved = resolutions.filter(
    (r) => r.kind === "unresolved_no_match" || r.kind === "unresolved_ambiguous",
  );
  const conflictNames = resolutions.filter(
    (r) => r.registration_identity_key !== null &&
      (r.kind === "resolved_not_current" || r.awri_cancelled_listed),
  );
  // Cancelled-list rows that are not already counted through a Table 2 entry.
  const entryNames = new Set(
    resolutions.map((r) => normaliseProductName(r.awri_product_name)),
  );
  const cancelledOnlyRows = cancelledResolutions.filter(
    (c) => !entryNames.has(normaliseProductName(c.awri_product_name)),
  );

  const allResolvedIdentities = new Set<string>([
    ...candidateIdentities,
    ...conflictIdentities,
  ]);

  // ---- Invariants (structural, verified again by tests) ------------------
  // AWRI supplied no registration numbers, and every resolved identity came
  // from a register row through the adapter's own selection discipline.
  const awriSuppliedNumbers = manifest.entries.some(
    (e) => e.apvma_registration_number !== null,
  );
  const everyIdentityFromRegister = resolutions.every(
    (r) =>
      r.registration_identity_key === null ||
      (r.registration_number !== null &&
        r.registration_identity_key ===
          identityKey("AU", "apvma", r.registration_number) &&
        r.match_mode !== null),
  );

  const counts: SeedDryRunCounts = {
    unique_products_found: manifest.entries.length,
    names_resolved_total: resolvedNameCount,
    with_apvma_registration_identities: allResolvedIdentities.size,
    candidate_eligible_identities: candidateIdentities.length,
    already_in_master: null,
    would_create_candidates: null,
    unresolved_total: unresolved.length,
    unresolved_no_match: unresolved.filter((r) => r.kind === "unresolved_no_match").length,
    unresolved_ambiguous: unresolved.filter((r) => r.kind === "unresolved_ambiguous").length,
    unresolved_bare_parent_synthetic: unresolved.filter((r) => r.expansion === "bare_parent").length,
    conflicts_cancelled_lapsed: conflictNames.length + cancelledOnlyRows.length,
    duplicate_identities_removed: duplicateNamesRemoved,
    database_changes: 0,
    production_writes: 0,
  };

  return {
    seed_source: manifest.source,
    manifest_version: manifest.manifest_version,
    resolutions,
    cancelled_list_resolutions: cancelledResolutions,
    candidate_identities: candidateIdentities,
    conflict_identities: Array.from(conflictIdentities).sort(
      (a, b) => numericIdentity(a) - numericIdentity(b),
    ),
    duplicates,
    counts,
    invariants: {
      apvma_remains_authoritative: !awriSuppliedNumbers && everyIdentityFromRegister
        ? "PASS"
        : "FAIL",
      dry_run_no_writes: "PASS",
    },
  };
}

// ---------------------------------------------------------------------------
// Report + comparison SQL
// ---------------------------------------------------------------------------

/** The required dry-run count report, exactly one line per required field. */
export function formatSeedReport(result: SeedDryRunResult, testsLine: string): string {
  const c = result.counts;
  const src = result.seed_source;
  return [
    `AWRI edition/source: ${src.title ?? "AWRI Dog Book"} — edition ${src.edition}, compiled ${src.compiled} (${src.id})`,
    `Unique products found: ${c.unique_products_found}`,
    `With APVMA registration: ${c.names_resolved_total} names → ${c.with_apvma_registration_identities} distinct identities`,
    `Already in Master: PENDING MANUAL SQL (no database access in this dry run)`,
    `Would create Candidates: PENDING MANUAL SQL (≤ ${c.candidate_eligible_identities} candidate-eligible identities)`,
    `Unresolved: ${c.unresolved_total} (${c.unresolved_no_match} no deterministic match, ${c.unresolved_ambiguous} ambiguous; ${c.unresolved_bare_parent_synthetic} of these are synthetic bare-parent expansions)`,
    `Conflicts / cancelled / lapsed: ${c.conflicts_cancelled_lapsed}`,
    `Duplicate identities removed: ${c.duplicate_identities_removed}`,
    `APVMA remains authoritative: ${result.invariants.apvma_remains_authoritative}`,
    `Dry run (no writes): ${result.invariants.dry_run_no_writes}`,
    `Tests: ${testsLine}`,
    `Database changes: NONE`,
    `Production writes: NONE`,
  ].join("\n");
}

/**
 * Read-only comparison SQL for the VineTrack Supabase SQL Editor. Two
 * SELECT statements, zero writes: summary counts, then per-identity detail.
 */
export function buildComparisonSql(result: SeedDryRunResult): string {
  const numbers = result.candidate_identities
    .map((k) => k.split(":")[2])
    .filter((n): n is string => Boolean(n));
  const csv = numbers.join(",");
  return `-- Stage 5 — AWRI Dog Book 2026/27 seed dry-run comparison (READ-ONLY).
-- Source: ${result.seed_source.id ?? "awri_dogbook_2026_27"} (${result.seed_source.edition ?? "2026/27"})
-- ${numbers.length} candidate-eligible identities resolved from the APVMA register.
-- Run each statement separately in the Supabase SQL Editor. No writes.

-- 1) Summary counts ---------------------------------------------------------
with awri_identity(registration_identity_key) as (
  select 'AU:apvma:' || n
  from unnest(string_to_array('${csv}', ',')) as n
)
select
  (select count(*) from awri_identity)                        as awri_identities_total,
  count(mc.id)                                                as existing_master_rows,
  count(*) filter (where mc.review_status = 'candidate')      as existing_candidates,
  count(*) filter (where mc.review_status = 'approved')       as existing_approved,
  count(*) filter (where mc.review_status = 'retired')        as existing_retired,
  (select count(*) from awri_identity) - count(mc.id)         as identities_not_in_master
from awri_identity ai
left join public.master_chemicals mc
  on mc.registration_identity_key = ai.registration_identity_key;

-- 2) Per-identity detail (existing rows first, then missing) ----------------
with awri_identity(registration_identity_key) as (
  select 'AU:apvma:' || n
  from unnest(string_to_array('${csv}', ',')) as n
)
select
  ai.registration_identity_key,
  coalesce(mc.review_status, 'NOT IN MASTER')                 as review_status,
  mc.registered_product_name
from awri_identity ai
left join public.master_chemicals mc
  on mc.registration_identity_key = ai.registration_identity_key
order by (mc.id is null), ai.registration_identity_key;
`;
}
