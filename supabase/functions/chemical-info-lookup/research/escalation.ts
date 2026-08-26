// Terra → Sol escalation policy (task §8).
//
// Sol costs 2× Terra's input and ~1.7× its output. Escalating "when the
// answer looks a bit thin" would quietly make Sol the default model, which
// is exactly the cost failure the explicit model configuration exists to
// prevent. So escalation is a CLOSED LIST of named conditions, each one a
// research problem that more reasoning can actually fix.
//
// Hard rule: at most ONE Sol attempt per lookup, and Sol can never escalate
// again. `EscalationDecision.terminal` makes that structural rather than a
// convention someone can forget.

import type { ChemicalResearchResult } from "./schema.ts";
import type { ClassifiedUrl } from "./classify.ts";

export type EscalationReason =
  | "multiple_unresolved_identities"
  | "sources_disagree"
  | "registration_unresolved"
  | "registered_name_ambiguous"
  | "concentration_conflict"
  | "label_missing_for_known_registration"
  | "research_returned_nothing"
  /** Candidate discovery found at most ONE product for an approximate name.
   *  Not a claim that the one found is wrong — a claim that one is too few
   *  to present as a choice. */
  | "insufficient_candidate_recall";

export interface EscalationInput {
  /** Terra's parsed research, or null when Terra produced nothing usable. */
  research: ChemicalResearchResult | null;
  /** True once the official register CONFIRMED an identity for this lookup. */
  registerResolved: boolean;
  /** True when the register confirmed but no label document was established. */
  labelMissingForResolvedRegistration: boolean;
  /** Server-classified URLs from this research pass. */
  classified: ClassifiedUrl[];
}

export interface EscalationDecision {
  escalate: boolean;
  reasons: EscalationReason[];
  /** Always true for a Sol result — Sol is the end of the line. */
  terminal: boolean;
  /** One-line human summary for the ops log. */
  summary: string;
}

const NO_ESCALATION: EscalationDecision = {
  escalate: false,
  reasons: [],
  terminal: false,
  summary: "Terra resolved the research problem",
};

function distinctRegistrationNumbers(research: ChemicalResearchResult): string[] {
  const seen = new Set<string>();
  for (const c of research.registration_candidates) {
    const n = (c.number ?? "").trim();
    if (n) seen.add(n);
  }
  return [...seen];
}

function distinctRegisteredNames(research: ChemicalResearchResult): string[] {
  const seen = new Set<string>();
  for (const c of research.registration_candidates) {
    const n = (c.registered_product_name ?? "").trim().toLowerCase();
    if (n) seen.add(n);
  }
  return [...seen];
}

/**
 * Two credible sources stating different strengths for the SAME active is a
 * genuine reconciliation problem — precisely what a stronger model helps
 * with. Two entries for different actives is just a mixture.
 */
function hasConcentrationConflict(research: ChemicalResearchResult): boolean {
  const byName = new Map<string, Set<string>>();
  for (const a of research.active_ingredients) {
    if (a.concentration === null) continue;
    const key = a.name.trim().toLowerCase();
    if (!key) continue;
    const strength = `${a.concentration}${(a.concentration_unit ?? "").trim().toLowerCase()}`;
    const set = byName.get(key) ?? new Set<string>();
    set.add(strength);
    byName.set(key, set);
  }
  for (const set of byName.values()) if (set.size > 1) return true;
  return false;
}

/**
 * Decide whether Terra's result justifies one Sol attempt.
 *
 * Called AFTER the register has had its say: a lookup the register already
 * resolved is finished regardless of how vague the web research was, because
 * more AI cannot improve on an authoritative answer.
 */
export function decideEscalation(input: EscalationInput): EscalationDecision {
  const reasons: EscalationReason[] = [];
  const { research, registerResolved } = input;

  if (!research) {
    // Terra produced nothing parseable. If the register already answered,
    // there is nothing left to research; otherwise one deeper attempt is
    // warranted before giving up on discovery entirely.
    if (registerResolved) return NO_ESCALATION;
    return {
      escalate: true,
      reasons: ["research_returned_nothing"],
      terminal: false,
      summary: "Terra returned no usable research and the register did not resolve",
    };
  }

  if (registerResolved) {
    // The one open question a resolved registration can still have.
    if (input.labelMissingForResolvedRegistration) {
      const hasLabelCandidate = input.classified.some((c) => c.isOfficialLabelCandidate);
      if (!hasLabelCandidate) reasons.push("label_missing_for_known_registration");
    }
  } else {
    const numbers = distinctRegistrationNumbers(research);
    const names = distinctRegisteredNames(research);

    if (numbers.length === 0) {
      reasons.push("registration_unresolved");
    } else if (numbers.length > 1) {
      reasons.push("multiple_unresolved_identities");
    }

    // Identity strongly indicated (a canonical name is in hand) but the
    // register name behind it is still not pinned down.
    if (research.product.canonical_name && names.length > 1) {
      reasons.push("registered_name_ambiguous");
    }
  }

  if (hasConcentrationConflict(research)) reasons.push("concentration_conflict");

  // The model told us, in its own words, that credible sources disagreed.
  if (
    research.unresolved.some((u) =>
      /\b(conflict|disagree|inconsisten|contradict|differ)\w*/i.test(u)
    )
  ) {
    reasons.push("sources_disagree");
  }

  if (reasons.length === 0) return NO_ESCALATION;

  const deduped = [...new Set(reasons)];
  return {
    escalate: true,
    reasons: deduped,
    terminal: false,
    summary: `Terra unresolved: ${deduped.join(", ")}`,
  };
}

/**
 * How many distinct registered products candidate discovery must surface
 * before the operator has a genuine choice rather than a fait accompli.
 *
 * Two. Not because two is a magic number, but because ONE is definitionally
 * not a choice, and a search whose whole purpose is "which of these did you
 * mean?" cannot answer with a single row it found first.
 */
export const MIN_DISCOVERY_CANDIDATES = 2;

export interface CandidateDiscoveryEscalationInput {
  /** Terra's parsed research, or null when Terra produced nothing usable. */
  research: ChemicalResearchResult | null;
  /** True once the official register CONFIRMED an identity for this lookup. */
  registerResolved: boolean;
  /** True when the query is a bare registration number. */
  isProductCodeQuery: boolean;
}

/**
 * Decide whether CANDIDATE DISCOVERY justifies one Sol attempt (Stage A §1).
 *
 * # The defect this exists to fix
 *
 * Discovery was categorically barred from escalating — "the operator is
 * mid-search and a second frontier-model call is the wrong trade at that
 * moment". That reasoning is sound about LATENCY and wrong about RECALL, and
 * it silently made discovery Terra-only forever.
 *
 * Production proved the cost. For "Hortitrol Winter Oil" Terra returned one
 * plausible product (APVMA 50067), the APVMA adapter confirmed that
 * registration genuinely exists, and discovery stopped there. But:
 *
 *   "50067 is a real registered product"     <- what validation proved
 *   "50067 is the only product they meant"   <- what the system concluded
 *
 * Those are different claims. The server's ranking is perfectly capable of
 * presenting a choice between several products — it simply never received a
 * second candidate to rank, because discovery had already stopped. No amount
 * of downstream ranking can recover a candidate that was never discovered.
 *
 * # The rule
 *
 * Escalate when discovery has fewer than two distinct registered candidates
 * for an approximate name. Deliberately narrow:
 *
 *   * a bare registration NUMBER never escalates — the register either holds
 *     it or it does not, and a second model pass cannot improve on that;
 *   * a register-RESOLVED lookup never escalates — the authoritative source
 *     already answered, so more AI is pure cost;
 *   * two or more candidates never escalate — the operator already has a
 *     choice, which is the entire objective.
 *
 * So Sol is bought for exactly one situation: the approximate-name search
 * that came back with too little to choose from.
 */
export function decideCandidateDiscoveryEscalation(
  input: CandidateDiscoveryEscalationInput,
): EscalationDecision {
  // A bare number is an exact identity assertion, not an approximate name.
  if (input.isProductCodeQuery) return NO_ESCALATION;

  // The register already answered. Nothing a model finds can outrank it.
  if (input.registerResolved) return NO_ESCALATION;

  if (!input.research) {
    return {
      escalate: true,
      reasons: ["research_returned_nothing"],
      terminal: false,
      summary: "Terra returned no usable candidate research",
    };
  }

  const distinct = distinctRegistrationNumbers(input.research).length;
  if (distinct >= MIN_DISCOVERY_CANDIDATES) return NO_ESCALATION;

  return {
    escalate: true,
    reasons: ["insufficient_candidate_recall"],
    terminal: false,
    summary:
      `Candidate discovery found ${distinct} distinct registration(s); ` +
      `${MIN_DISCOVERY_CANDIDATES} needed before an operator has a choice`,
  };
}

/**
 * The decision recorded for a Sol result. Sol is terminal by construction —
 * there is no path from here to another model call.
 */
export function solTerminalDecision(reasons: EscalationReason[]): EscalationDecision {
  return {
    escalate: false,
    reasons,
    terminal: true,
    summary: `Sol escalation completed (${reasons.join(", ") || "no reason recorded"})`,
  };
}
