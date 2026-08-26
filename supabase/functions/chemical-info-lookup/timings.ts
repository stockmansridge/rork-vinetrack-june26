// Per-stage timing for one lookup (Stage C §H).
//
// # Why a stage breakdown, not a total
//
// "The search took 94 seconds" is not actionable. It cannot distinguish a slow
// register from a slow model from a slow registrant website, so every latency
// investigation began by guessing which stage to instrument next.
//
// Worse, a total cannot answer the question this stage exists to settle:
// whether a SEARCH ever entered a stage that only a structured lookup should
// reach. `assertSearchStagesOnly` turns that from a code-reading exercise into
// a value anyone can read off the response.
//
// Observation only. Nothing here may influence what is served.

/** The stages a lookup can spend time in. */
export type LookupStage =
  /** Approved master catalogue + official register candidate discovery. */
  | "search_register"
  /** The candidate-discovery model pass. */
  | "model_discovery"
  /** Reading suggested registration numbers back from the register. */
  | "registration_validation"
  /** Exact structured identity resolution. */
  | "structured_identity"
  /** The product-enrichment model pass. */
  | "manufacturer_research"
  /** Fetching and parsing a registrant product page. */
  | "page_inspection"
  /** Downloading a manufacturer label document. */
  | "pdf_download"
  /** Extracting the document's text layer and reading its tables. */
  | "pdf_extraction";

/**
 * Stages a `search` request may NEVER enter.
 *
 * Search answers "which product do you mean?" — a question no label document
 * can help with, because you cannot read the right label until the product is
 * known. Every stage here costs seconds to tens of seconds and belongs to a
 * lookup that has already been given an identity.
 */
export const STRUCTURED_ONLY_STAGES: readonly LookupStage[] = [
  "structured_identity",
  "manufacturer_research",
  "page_inspection",
  "pdf_download",
  "pdf_extraction",
] as const;

export interface StageTimings {
  stages: Partial<Record<LookupStage, number>>;
  total_ms: number;
}

/**
 * A stopwatch with named laps.
 *
 * Repeated entries into one stage ACCUMULATE, because two register calls are
 * two costs and reporting only the second would understate the stage.
 */
export class LookupTimer {
  private readonly startedMs: number;
  private readonly totals = new Map<LookupStage, number>();
  private readonly now: () => number;

  constructor(now: () => number = Date.now) {
    this.now = now;
    this.startedMs = now();
  }

  /** Time an async stage, whatever its outcome. */
  async time<T>(stage: LookupStage, fn: () => Promise<T>): Promise<T> {
    const started = this.now();
    try {
      return await fn();
    } finally {
      // Recorded in `finally` on purpose: a stage that THREW still consumed
      // the time, and a timeout is exactly the case a latency investigation
      // most needs to see.
      this.add(stage, this.now() - started);
    }
  }

  /** Record a duration measured elsewhere. */
  add(stage: LookupStage, ms: number): void {
    this.totals.set(stage, (this.totals.get(stage) ?? 0) + Math.max(0, ms));
  }

  /** Whether a stage was entered at all. */
  entered(stage: LookupStage): boolean {
    return this.totals.has(stage);
  }

  snapshot(): StageTimings {
    const stages: Partial<Record<LookupStage, number>> = {};
    for (const [stage, ms] of this.totals) stages[stage] = Math.round(ms);
    return { stages, total_ms: Math.max(0, this.now() - this.startedMs) };
  }
}

/**
 * The stages a search entered that only a structured lookup may enter.
 *
 * Empty is the contract. A non-empty array means a search performed work that
 * can take minutes, which is the defect Stage C exists to remove — so it is
 * surfaced as data rather than left to be re-derived from a call graph.
 */
export function structuredOnlyStagesEntered(timer: LookupTimer): LookupStage[] {
  return STRUCTURED_ONLY_STAGES.filter((s) => timer.entered(s));
}
