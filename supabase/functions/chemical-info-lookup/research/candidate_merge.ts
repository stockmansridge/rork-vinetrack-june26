// Merging two candidate-discovery passes (Stage A §3).
//
// # Why merge rather than replace
//
// Everywhere else in this orchestrator, Sol REPLACES Terra: enrichment asks
// one question ("what does this product's label say?") and the better model
// gives the better answer, so the weaker one is redundant.
//
// Candidate discovery asks a different question — "which products might the
// operator have meant?" — and there the two passes are ADDITIVE. Terra found
// SYNERTROL HORTI; Sol is asked what ELSE is plausible. Taking Sol's answer
// alone would throw away a genuine candidate for no reason and could easily
// make recall worse than before escalation existed, which would be a strange
// outcome for a change whose entire purpose is recall.
//
// So the union wins, and Terra's ordering leads: it ran first, on the
// unprompted question, and its candidates were not influenced by being told
// what another model had already found.

import type {
  ChemicalResearchResult,
  ResearchRegistrationCandidate,
} from "./schema.ts";

/**
 * The most candidates a merged discovery pass may carry.
 *
 * Matches `MAX_RESEARCH_SUGGESTIONS` downstream. A "did you mean" list is a
 * decision aid; past about five entries it stops being a choice and becomes
 * a research task of its own, handed back to the person who asked.
 */
export const MAX_MERGED_CANDIDATES = 5;

/**
 * Exact registered identity, or null when the candidate cannot state one.
 *
 * `country:scheme:number`, upper/lower-cased consistently. Identity dedupe is
 * NEVER by product name: two registrations can share a verbatim registered
 * name (pack sizes, re-registrations), and collapsing those would delete a
 * genuinely different registered product from the operator's choices.
 */
export function candidateIdentity(
  candidate: ResearchRegistrationCandidate,
  fallbackCountry = "",
): string | null {
  const number = (candidate.number ?? "").trim().toUpperCase();
  if (!number) return null;
  const country = ((candidate.country || fallbackCountry) ?? "").trim().toUpperCase();
  const scheme = (candidate.scheme ?? "").trim().toLowerCase();
  return `${country}:${scheme}:${number}`;
}

export interface MergeCandidatesResult {
  research: ChemicalResearchResult;
  /** Distinct registration numbers carried by the merged candidate list, in
   *  served order. The diagnostics line reports exactly this. */
  mergedNumbers: string[];
  /** Candidates Sol contributed that Terra had not already found. */
  addedCount: number;
  /** Sol candidates dropped as duplicates of a Terra identity. */
  duplicateCount: number;
}

/**
 * Merge a fallback discovery pass into the primary one.
 *
 * `primary` supplies the product identity and every non-candidate field: it
 * answered the operator's actual question, and the fallback was asked a
 * narrower one ("what else?"). Only the candidate list is unioned, plus the
 * fallback's sources so its evidence trail is not lost.
 *
 * Candidates with no registration number are kept only when they carry a
 * usable name — they are still legitimate "did you mean" rows that the
 * register may confirm later — but they can never displace an identified
 * candidate, and they are deduped by name since they have no identity.
 */
export function mergeCandidateResearch(
  primary: ChemicalResearchResult,
  fallback: ChemicalResearchResult | null,
  countryCode = "",
  maxCandidates = MAX_MERGED_CANDIDATES,
): MergeCandidatesResult {
  const merged: ResearchRegistrationCandidate[] = [];
  const seenIdentities = new Set<string>();
  const seenNames = new Set<string>();
  let addedCount = 0;
  let duplicateCount = 0;

  const take = (
    candidate: ResearchRegistrationCandidate,
    isFallback: boolean,
  ): void => {
    const identity = candidateIdentity(candidate, countryCode);
    if (identity) {
      if (seenIdentities.has(identity)) {
        if (isFallback) duplicateCount++;
        return;
      }
      seenIdentities.add(identity);
    } else {
      // No identity to dedupe on, so fall back to the name. A nameless,
      // numberless candidate is nothing at all and is dropped.
      const nameKey = (candidate.registered_product_name ?? "").trim().toLowerCase();
      if (!nameKey) return;
      if (seenNames.has(nameKey)) {
        if (isFallback) duplicateCount++;
        return;
      }
      seenNames.add(nameKey);
    }
    if (merged.length >= maxCandidates) return;
    merged.push(candidate);
    if (isFallback) addedCount++;
  };

  // Terra first: it answered the unprompted question.
  for (const c of primary.registration_candidates) take(c, false);
  if (fallback) for (const c of fallback.registration_candidates) take(c, true);

  const research: ChemicalResearchResult = {
    ...primary,
    registration_candidates: merged,
    sources: fallback
      ? dedupeSources([...primary.sources, ...fallback.sources])
      : primary.sources,
    unresolved: fallback
      ? [...new Set([...primary.unresolved, ...fallback.unresolved])]
      : primary.unresolved,
  };

  return {
    research,
    mergedNumbers: merged
      .map((c) => (c.number ?? "").trim())
      .filter((n) => n.length > 0),
    addedCount,
    duplicateCount,
  };
}

/** Union of two source lists, keyed by URL, first occurrence winning. */
function dedupeSources<T extends { url: string }>(sources: T[]): T[] {
  const seen = new Set<string>();
  const out: T[] = [];
  for (const s of sources) {
    const key = (s.url ?? "").trim().toLowerCase();
    if (!key || seen.has(key)) continue;
    seen.add(key);
    out.push(s);
  }
  return out;
}
