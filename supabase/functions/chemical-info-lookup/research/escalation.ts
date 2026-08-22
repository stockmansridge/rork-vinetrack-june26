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
  | "research_returned_nothing";

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
