// Exact-registration enrichment cache (Stage C §G).
//
// # The gap this closes
//
// Stage B enrichment is expensive in a way no other stage is: a research call,
// a product-page fetch, a PDF download and a text extraction, each with its own
// timeout. Until now the ONLY places its result could live were the current
// HTTP response and the per-isolate `SourceCache`.
//
// Per-isolate is effectively no cache at all for this workload. Portal and iOS
// land on different isolates, isolates recycle constantly, and every cold start
// begins with an empty map — so two operators looking up the same registered
// chemical minutes apart each paid the full web + PDF cost, and so did the same
// operator opening the same product twice.
//
// The reviewed Master Chemical catalogue is NOT that cache and must not become
// it. A master row means "a human confirmed this", which is a claim about
// review, not about freshness. Writing enrichment output there would either
// require approval (defeating the point) or quietly manufacture approved rows
// nobody reviewed. So this is a SEPARATE, clearly-labelled lookup cache:
//
//   * keyed by exact registration identity, never by a typed name;
//   * versioned by the parser contract, so a parser fix retires every entry;
//   * service-role only, like the suggestion cache beside it;
//   * fail-soft in every direction — a cache error costs latency, never
//     correctness.
//
// It is a cache, not an approval mechanism. Nothing here confers authority on
// what it stores; it only avoids paying twice for the same public documents.

// deno-lint-ignore-file no-explicit-any

/**
 * The enrichment contract generation.
 *
 * BUMP THIS whenever the manufacturer-label parser, the practical-source
 * priority or the served enrichment shape changes. Bumping retires every
 * stored entry at once: old rows stop being addressable and expire on their
 * own TTL, so a parser fix can never be masked by a cached result produced by
 * the parser it fixed.
 *
 *   v1  Anchor-based manufacturer DFU extraction, manufacturer-first practical
 *       source priority, per-state conditional rates.
 *   v2  Fetched-document identity confirmation and canonical final URL/projection
 *       rebuilding.
 *   v3  Independently retained byte-verified manufacturer label/product links,
 *       even when regulator rows remain the practical source.
 */
export const ENRICHMENT_CACHE_VERSION = "enrichment-v3";

/**
 * How long an enrichment stays fresh.
 *
 * Seven days. What is cached is a reading of a PUBLISHED document: a
 * registrant's current approved label, which changes when a registration is
 * varied or a label reissued — a timescale of months, not hours. A week keeps
 * the data honest while ensuring a label revision cannot linger indefinitely,
 * and the version segment remains the immediate invalidation lever for anything
 * caused by our own code.
 */
export const ENRICHMENT_CACHE_TTL_SECONDS = 7 * 24 * 60 * 60;

/** Cache key: exact registration identity plus the contract generation. */
export function enrichmentCacheKey(
  countryCode: string,
  scheme: string | null,
  registrationNumber: string,
): string {
  const country = String(countryCode ?? "").trim().toUpperCase();
  const sch = String(scheme ?? "").trim().toLowerCase();
  const number = String(registrationNumber ?? "").trim().toUpperCase();
  return `${country}:${sch}:${number}::${ENRICHMENT_CACHE_VERSION}`;
}

/** What a cached enrichment carries. Documents and readings only — no identity claim. */
export interface CachedEnrichment {
  manufacturer_product_url: string | null;
  manufacturer_label_url: string | null;
  /** True only after readable PDF bytes confirmed the locked product identity. */
  manufacturer_links_verified: boolean;
  regulator_label_url: string | null;
  /** The served practical use rows, grapevine and other crops alike. */
  registered_uses: any[];
  withholding_period_days: number | null;
  re_entry_period_hours: number | null;
  practical_source: string;
  /**
   * Fingerprint of the document the readings came from (sha256 of the PDF).
   *
   * Provenance a human can check: if a registrant reissues a label, the hash
   * changes, so a stored reading can always be traced to the exact bytes it
   * was read from rather than merely to a URL that may now serve something
   * else.
   */
  source_fingerprint: string | null;
  parser_version: string;
  refreshed_at: string;
}

export interface EnrichmentCacheStore {
  read(key: string): Promise<CachedEnrichment | null>;
  write(
    key: string,
    identity: { countryCode: string; scheme: string | null; registrationNumber: string },
    value: CachedEnrichment,
    ttlSeconds: number,
  ): Promise<void>;
}

/**
 * PostgREST-backed store over `chemical_enrichment_cache` (sql/213).
 *
 * Fail-soft including a MISSING TABLE: a deploy that lands before the
 * migration must degrade to today's behaviour — paying the enrichment cost
 * every time — rather than breaking the lookup.
 */
export function createPostgrestEnrichmentCache(
  baseUrl: string,
  serviceKey: string,
  fetchFn: typeof fetch = fetch,
  now: () => Date = () => new Date(),
): EnrichmentCacheStore | null {
  const url = (baseUrl ?? "").replace(/\/+$/, "");
  if (!url || !serviceKey) return null;
  const endpoint = `${url}/rest/v1/chemical_enrichment_cache`;
  const headers = {
    apikey: serviceKey,
    Authorization: `Bearer ${serviceKey}`,
    "Content-Type": "application/json",
  };

  return {
    async read(key: string): Promise<CachedEnrichment | null> {
      try {
        const res = await fetchFn(
          `${endpoint}?select=payload&cache_key=eq.${encodeURIComponent(key)}` +
            `&expires_at=gt.${encodeURIComponent(now().toISOString())}&limit=1`,
          { headers },
        );
        if (!res.ok) return null;
        const rows = await res.json();
        if (!Array.isArray(rows) || rows.length !== 1) return null;
        const payload = rows[0]?.payload;
        return payload && typeof payload === "object" ? payload as CachedEnrichment : null;
      } catch {
        return null;
      }
    },

    async write(key, identity, value, ttlSeconds): Promise<void> {
      try {
        const expiresAt = new Date(now().getTime() + ttlSeconds * 1000).toISOString();
        await fetchFn(endpoint, {
          method: "POST",
          headers: { ...headers, Prefer: "resolution=merge-duplicates" },
          body: JSON.stringify([{
            cache_key: key,
            registration_country: String(identity.countryCode ?? "").toUpperCase(),
            registration_scheme: identity.scheme,
            registration_number: identity.registrationNumber,
            parser_version: ENRICHMENT_CACHE_VERSION,
            payload: value,
            expires_at: expiresAt,
          }]),
        });
      } catch {
        // Intentionally silent: a cache write is never worth a failed lookup.
      }
    },
  };
}

function isHttpsUrl(value: unknown): boolean {
  try {
    return new URL(String(value ?? "")).protocol === "https:";
  } catch {
    return false;
  }
}

/**
 * Whether the cache carries a complete verified manufacturer link pair.
 *
 * The explicit verification bit is minted only after readable PDF bytes confirm
 * the locked identity. URL shape alone can never promote a discovery lead.
 */
export function cachedVerifiedManufacturerLinksAreUsable(
  value: CachedEnrichment | null,
): boolean {
  return Boolean(
    value?.manufacturer_links_verified === true &&
      isHttpsUrl(value.manufacturer_label_url) &&
      isHttpsUrl(value.manufacturer_product_url) &&
      String(value.source_fingerprint ?? "").trim(),
  );
}

/** Whether cached manufacturer-derived practical rates are worth serving. */
export function cachedManufacturerRatesAreUsable(value: CachedEnrichment | null): boolean {
  if (!value || value.practical_source !== "manufacturer_label") return false;
  if (!Array.isArray(value.registered_uses) || value.registered_uses.length === 0) {
    return false;
  }
  return value.registered_uses.some((u: any) =>
    Array.isArray(u?.rates) && u.rates.some((r: any) => r?.basis && r.basis !== "other")
  );
}

/** Backward-compatible name retained for existing callers and focused tests. */
export const cachedEnrichmentIsUsable = cachedManufacturerRatesAreUsable;
