// Country-scoped, in-memory cache for authoritative source discovery.
//
// PURPOSE — load shedding only (Stage 3 §L): the same product typed twice in
// quick succession must not hammer the external register. This cache is a
// transport optimisation, deliberately SEPARATE from master_chemicals: a
// cached source response is never an approved master product, never served as
// catalogue data, and never outlives its TTL. Cross-instance dedupe of
// repeated lookups is provided by the catalogue's registration-identity
// uniqueness itself, not by this cache.
//
// PROVENANCE — every entry retains the country, the source adapter, the
// retrieval timestamp, and the registration identity when known. Reads
// require an exact country+source match; an AU request can structurally
// never be served from another country's cached search.
//
// STALENESS POLICY (documented in docs/master-chemical-ingestion.md §7):
//   * resolved identities:            6 hours
//   * unresolved / ambiguous misses:  1 hour  (negative cache)
//   * source_unavailable failures:    5 minutes (fast retry after outages)
//   * capacity:                       256 entries, oldest evicted first
// Edge isolates are ephemeral, so these are upper bounds, not guarantees.

interface CacheEntry<T> {
  value: T;
  country: string;
  source: string;
  retrieved_at: string;
  identity_key: string | null;
  expires_at_ms: number;
}

export const RESOLVED_TTL_MS = 6 * 60 * 60 * 1000;
export const NEGATIVE_TTL_MS = 60 * 60 * 1000;
export const UNAVAILABLE_TTL_MS = 5 * 60 * 1000;
const MAX_ENTRIES = 256;

export class SourceCache {
  private entries = new Map<string, CacheEntry<unknown>>();

  private composite(country: string, source: string, key: string): string {
    return `${country}::${source}::${key}`;
  }

  get<T>(
    country: string,
    source: string,
    key: string,
    nowMs: number,
  ): { value: T; retrieved_at: string; identity_key: string | null } | null {
    const entry = this.entries.get(this.composite(country, source, key));
    if (!entry) return null;
    if (entry.expires_at_ms <= nowMs) {
      this.entries.delete(this.composite(country, source, key));
      return null;
    }
    // Belt-and-braces jurisdiction assertion: the key embeds country+source,
    // but the entry's own provenance must ALSO match before it is served.
    if (entry.country !== country || entry.source !== source) return null;
    return {
      value: entry.value as T,
      retrieved_at: entry.retrieved_at,
      identity_key: entry.identity_key,
    };
  }

  set<T>(
    country: string,
    source: string,
    key: string,
    value: T,
    ttlMs: number,
    nowMs: number,
    retrievedAtIso: string,
    identityKey: string | null,
  ): void {
    if (this.entries.size >= MAX_ENTRIES) {
      const oldest = this.entries.keys().next().value;
      if (oldest !== undefined) this.entries.delete(oldest);
    }
    this.entries.set(this.composite(country, source, key), {
      value,
      country,
      source,
      retrieved_at: retrievedAtIso,
      identity_key: identityKey,
      expires_at_ms: nowMs + ttlMs,
    });
  }

  clear(): void {
    this.entries.clear();
  }

  get size(): number {
    return this.entries.size;
  }
}
