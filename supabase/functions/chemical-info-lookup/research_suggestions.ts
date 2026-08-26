// Research suggestions: validation, shortlisting and cross-isolate stability
// (Stage 2 §2, §5, §6).
//
// # The defect this module exists to close
//
// "Hortitrol Winter Oil" matches NOTHING in the APVMA register. The lexical
// matcher correctly returns zero candidates, and the request falls through to
// `runChemicalResearch` — a model pass. Those rows were then served in the same
// shape as register candidates, so two clients auto-continued into two
// different registrations (Portal → 33182, iOS → 50067) from an answer that
// was never a register answer at all.
//
// Three separate faults, addressed here:
//
//   1. NONDETERMINISM. A model pass can return different rows on different
//      invocations. Two clients therefore see two different products for one
//      query. `suggestionCacheKey` + a shared store make the answer stable for
//      the cache lifetime regardless of which isolate serves it.
//   2. UNVALIDATED IDENTITY. A model can state a registration number that does
//      not exist, or pair a real number with the wrong name. Nothing here may
//      become canonical until the REGISTER has confirmed that exact number.
//   3. SILENT SUBSTITUTION. One suggestion looks like a finding. Suggestions
//      stay explicitly suggestions, however few come back.
//
// # What this module must never do
//
// It must never invent, repair or "best-guess" a registration. When the
// register does not confirm a number, the number is REMOVED — a wrong number
// is worse than none, because a number is what downstream resolution trusts.

// deno-lint-ignore-file no-explicit-any

import type { RegisterCandidate } from "./ingestion/contract.ts";
import { normaliseProductNameLoose } from "./ingestion/matching.ts";

/**
 * How many research suggestions may be served.
 *
 * Small on purpose. This is a "did you mean" list for a query the register
 * could not answer, and a long list of model associations reads as authority
 * it does not have. NEVER padded to reach this number (Stage 2 §6).
 */
export const MAX_RESEARCH_SUGGESTIONS = 5;

/**
 * The candidate-discovery algorithm generation.
 *
 * # Why the cache key carries a version
 *
 * This cache stores the OUTPUT of a discovery algorithm, keyed only by what
 * was asked (country + normalised query). That silently assumes the algorithm
 * never changes -- and when it does, every stored row becomes a fossil of the
 * previous implementation that the new one is forced to serve.
 *
 * Production showed exactly that. `AU::hortitrol winter oil` held a single
 * Terra-only candidate (APVMA 50067) written by the pre-escalation algorithm.
 * A deploy that fixed discovery would have been masked for the full hour of
 * the TTL: the improved code would run, find more candidates, and then be
 * skipped in favour of the cached answer that demonstrated the bug. The fix
 * would have looked like it had failed.
 *
 * Bumping this constant retires every previous entry at once, with no
 * migration and no manual DELETE against production -- old rows simply stop
 * being addressable and expire on their own TTL.
 *
 * BUMP THIS whenever candidate discovery's behaviour changes: the escalation
 * rule, the merge policy, the recall prompt, or the shortlist cap.
 *
 *   v1  Terra-only discovery (no escalation from candidate_discovery).
 *   v2  Bounded Terra -> Sol recall escalation, merged candidate sets.
 *   v3  Single capable discovery pass for approximate names (no serial
 *       Terra -> Sol), 24-hour TTL.
 */
export const CANDIDATE_DISCOVERY_CACHE_VERSION = "candidate-discovery-v3";

/** Wire `source` value for a suggestion the register confirmed. */
export const VALIDATED_SUGGESTION_SOURCE = "research_validated";

/**
 * Look up ONE exact registration number in the official register.
 *
 * Returns the register's own row, or null when the register does not hold that
 * number. Implementations must be fail-soft: an outage returns null, which
 * degrades a suggestion to unvalidated rather than failing the search.
 */
export type RegisterNumberLookup = (
  registrationNumber: string,
) => Promise<RegisterCandidate | null>;

export interface ValidateSuggestionsOptions {
  countryCode: string;
  lookup: RegisterNumberLookup;
  maxSuggestions?: number;
}

export interface ValidateSuggestionsResult {
  rows: Record<string, unknown>[];
  /** Suggestions whose registration the register confirmed. */
  validatedCount: number;
  /** Numbers the research asserted that the register did NOT confirm. These
   *  were stripped from the served rows. */
  strippedCount: number;
  /** Non-fatal stage failures, for the diagnostics envelope. */
  degraded: string[];
}

/** Trimmed string, or "". */
function text(v: unknown): string {
  return String(v ?? "").trim();
}

/** Whether a row came from the register or the approved catalogue. */
function isAuthoritativeRow(row: Record<string, unknown>): boolean {
  const source = text(row.source);
  return source === "master" || source === "official_register";
}

/**
 * Validate research suggestions against the official register (Stage 2 §5).
 *
 * For every suggestion carrying a registration number, that exact number is
 * read from the register. On confirmation the row is REPLACED with the
 * register's canonical name, number and registrant — the research supplied the
 * lead, the register supplies the facts. On non-confirmation the number is
 * stripped and the row stays a plain unverified suggestion.
 *
 * Authoritative rows pass through untouched: they are already the register's
 * own answer, and re-reading them here would be a second chance to get an
 * established identity wrong.
 */
export async function validateResearchSuggestions(
  rows: Record<string, unknown>[],
  options: ValidateSuggestionsOptions,
): Promise<ValidateSuggestionsResult> {
  const max = options.maxSuggestions ?? MAX_RESEARCH_SUGGESTIONS;
  const out: Record<string, unknown>[] = [];
  const degraded: string[] = [];
  let validatedCount = 0;
  let strippedCount = 0;
  let suggestionsKept = 0;

  // Dedupe on the CONFIRMED number, so research proposing the same product
  // twice under two spellings collapses to the register's one identity.
  const seenNumbers = new Set<string>();
  const seenNames = new Set<string>();

  for (const raw of rows ?? []) {
    const row = { ...(raw ?? {}) } as Record<string, unknown>;

    if (isAuthoritativeRow(row)) {
      out.push(row);
      continue;
    }

    // Shortlist cap applies to SUGGESTIONS only — an authoritative row is
    // never dropped to make room for a guess, and the list is never padded to
    // reach the cap.
    if (suggestionsKept >= max) continue;

    const number = text(row.registration_number);
    if (!number) {
      const nameKey = normaliseProductNameLoose(text(row.name));
      if (nameKey && seenNames.has(nameKey)) continue;
      if (nameKey) seenNames.add(nameKey);
      row.registration_validated = false;
      out.push(row);
      suggestionsKept++;
      continue;
    }

    let confirmed: RegisterCandidate | null = null;
    try {
      confirmed = await options.lookup(number);
    } catch (err) {
      // Fail-soft and VISIBLE: an unreachable register means we cannot
      // confirm, which is not the same as disproving. The row survives as an
      // unverified suggestion with its unconfirmed number removed.
      degraded.push("suggestion_validation_failed");
      console.warn(
        "research suggestion validation failed:",
        err instanceof Error ? err.message : String(err),
      );
    }

    if (!confirmed) {
      // A number the register will not confirm is REMOVED. Serving it would
      // hand a downstream structured lookup a pointer to a registration that
      // may not exist — exactly how a model guess becomes canonical.
      delete row.registration_number;
      delete row.registration_scheme;
      row.registration_validated = false;
      row.registration_unconfirmed_number = number;
      strippedCount++;
      const nameKey = normaliseProductNameLoose(text(row.name));
      if (nameKey && seenNames.has(nameKey)) continue;
      if (nameKey) seenNames.add(nameKey);
      out.push(row);
      suggestionsKept++;
      continue;
    }

    const canonicalNumber = text(confirmed.registration_number) || number;
    if (seenNumbers.has(canonicalNumber)) continue;
    seenNumbers.add(canonicalNumber);

    // The register's row wins on every field it asserts. The research name is
    // discarded, not merged: a half-model, half-register name is a product
    // that exists in neither source.
    out.push({
      ...row,
      name: text(confirmed.registered_product_name) || text(row.name),
      brand: text(confirmed.registrant) || text(row.brand),
      activeIngredient: text(confirmed.actives_summary) || text(row.activeIngredient),
      chemicalGroup: (confirmed.activity_groups ?? []).join(" + ") ||
        text(row.chemicalGroup),
      registration_number: canonicalNumber,
      registration_country: options.countryCode,
      source: VALIDATED_SUGGESTION_SOURCE,
      registration_validated: true,
    });
    validatedCount++;
    suggestionsKept++;
  }

  return { rows: out, validatedCount, strippedCount, degraded };
}

// ---------------------------------------------------------------------------
// Cross-isolate stability (Stage 2 §4)
// ---------------------------------------------------------------------------

/**
 * The shared cache key for a research suggestion set.
 *
 * Country-scoped and typography-normalised, so "Hortitrol Winter Oil",
 * "hortitrol winter oil" and "Hortitrol  Winter  Oil" are ONE key — two
 * clients typing the same product with different capitalisation must not race
 * two independent model passes and reach two different products.
 *
 * The country is part of the key, never merged away: AU and NZ registers are
 * different law, and a shared entry across them would be a jurisdiction leak.
 *
 * The VERSION segment is what stops a previous algorithm's answer outliving
 * it. See `CANDIDATE_DISCOVERY_CACHE_VERSION`.
 */
export function suggestionCacheKey(countryCode: string, query: string): string {
  const code = text(countryCode).toUpperCase();
  const normalised = normaliseProductNameLoose(text(query));
  return `${code}::${CANDIDATE_DISCOVERY_CACHE_VERSION}::${normalised}`;
}

/**
 * A store that outlives ONE edge isolate.
 *
 * The existing `SourceCache` is per-isolate and in-memory, which is fine for
 * load-shedding but cannot deliver parity: Portal and iOS routinely land on
 * different isolates, so each ran its own model pass and each got its own
 * answer. Every method is fail-soft — a cache that errors must cost latency,
 * never correctness.
 */
export interface SharedSuggestionStore {
  read(key: string): Promise<Record<string, unknown>[] | null>;
  write(
    key: string,
    countryCode: string,
    query: string,
    rows: Record<string, unknown>[],
    ttlSeconds: number,
  ): Promise<void>;
}

/**
 * How long a shared suggestion set stays stable.
 *
 * # Why an hour was the wrong order of magnitude
 *
 * The one-hour TTL was chosen when this cache existed only to stop two
 * clients racing two model passes and reaching two different products. For
 * that job an hour is plenty.
 *
 * But the rows it stores are REGISTER-VALIDATED identities: every registration
 * number in them was read back from the APVMA register before it was written.
 * Registered product identities do not change hourly -- they change when a
 * registration is granted, renewed or cancelled, on a timescale of months.
 * Expiring them every hour meant the next operator to type an approximate name
 * paid the full discovery cost again to be told what the register had already
 * confirmed.
 *
 * 24 hours keeps the cache honest about a genuinely slow-moving fact while
 * bounding how long a cancelled registration could linger. The version segment
 * in the key remains the real invalidation lever: an algorithm change retires
 * every entry immediately, without waiting for any TTL.
 */
export const SUGGESTION_CACHE_TTL_SECONDS = 24 * 60 * 60;

/**
 * PostgREST-backed shared store.
 *
 * Deliberately the SMALLEST mechanism that gives cross-isolate stability: one
 * table, one keyed read, one upsert. No new subsystem, no external cache
 * service, and it reuses the service-role credentials the function already
 * holds for `master_chemicals`.
 *
 * Fail-soft in every direction, INCLUDING a missing table: the migration
 * (sql/211) is proposed separately, so a deploy that lands before the
 * migration must degrade to today's per-isolate behaviour rather than break
 * search.
 */
export function createPostgrestSuggestionStore(
  baseUrl: string,
  serviceKey: string,
  fetchFn: typeof fetch = fetch,
  now: () => Date = () => new Date(),
): SharedSuggestionStore | null {
  const url = (baseUrl ?? "").replace(/\/+$/, "");
  if (!url || !serviceKey) return null;
  const endpoint = `${url}/rest/v1/chemical_research_suggestion_cache`;
  const headers = {
    apikey: serviceKey,
    Authorization: `Bearer ${serviceKey}`,
    "Content-Type": "application/json",
  };

  return {
    async read(key: string): Promise<Record<string, unknown>[] | null> {
      try {
        const nowIso = now().toISOString();
        const res = await fetchFn(
          `${endpoint}?select=payload&cache_key=eq.${encodeURIComponent(key)}` +
            `&expires_at=gt.${encodeURIComponent(nowIso)}&limit=1`,
          { headers },
        );
        if (!res.ok) return null;
        const rows = await res.json();
        if (!Array.isArray(rows) || rows.length !== 1) return null;
        const payload = rows[0]?.payload;
        return Array.isArray(payload) ? payload : null;
      } catch {
        return null;
      }
    },

    async write(
      key: string,
      countryCode: string,
      query: string,
      rows: Record<string, unknown>[],
      ttlSeconds: number,
    ): Promise<void> {
      try {
        const expiresAt = new Date(now().getTime() + ttlSeconds * 1000)
          .toISOString();
        await fetchFn(endpoint, {
          method: "POST",
          headers: { ...headers, Prefer: "resolution=merge-duplicates" },
          body: JSON.stringify([{
            cache_key: key,
            country_code: text(countryCode).toUpperCase(),
            normalised_query: normaliseProductNameLoose(text(query)),
            payload: rows,
            expires_at: expiresAt,
          }]),
        });
      } catch {
        // Intentionally silent: a cache write is never worth a failed search.
      }
    },
  };
}
