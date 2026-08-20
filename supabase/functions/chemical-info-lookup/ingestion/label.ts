// Official label evidence (Master Chemical Catalogue Stage 4) — AU/APVMA.
//
// The APVMA publishes, as part of the PubCRIS register extract, the approved
// label's REGISTERED USE CLAIMS (product × host × pest) and the label's
// product statements (withholding periods, re-entry, restrictions) — the
// same facts printed on the approved label document. This module turns that
// published data into structured, field-attributed label evidence:
//
//   * registered crop/use + target  → produse/host/pest tables (verbatim)
//   * WHP                           → label statements, strict patterns only
//   * re-entry wording/period       → label statements, strict patterns only
//   * restrictions/directions       → verbatim statements, never paraphrased
//   * rates                         → NOT machine-published by the register.
//                                     Rates stay unresolved for admin review
//                                     (or AI-attributed) — NEVER promoted.
//
// Provenance: label-backed facts carry the contract's `manufacturer_label`
// kind (the APVMA-approved label is the registrant's approved label, §5.3) —
// structurally distinguishable from official_register (identity/chemistry),
// authoritative_classification (FRAC/HRAC/IRAC) and ai_interpretation.
//
// WHAT THIS MODULE WILL NEVER DO
//   * Invent a rate, WHP, or re-entry period the evidence does not state.
//   * Promote an AI-derived label fact to authoritative without a matching
//     label statement.
//   * Collapse different label contexts into one generic value — every claim
//     keeps its own crop, target, WHP and statements.

// deno-lint-ignore-file no-explicit-any

import type {
  LabelEvidence,
  LabelUseClaim,
  WireConflict,
  WireDataSource,
} from "./contract.ts";

// ---------------------------------------------------------------------------
// Comment reassembly (prodcom ships fixed-width chunks keyed by `seq`)
// ---------------------------------------------------------------------------

/**
 * Reassemble the register's chunked label-comment rows into one text block.
 * Chunks are fixed-width slices (words split mid-token: "GRAP" + "EVINES"),
 * so they join with NO separator; parsing regexes tolerate the whitespace the
 * register's own trimming may have dropped at chunk boundaries.
 */
export function assembleProductComments(
  rows: Array<{ seq?: unknown; applic?: unknown }>,
): string {
  return rows
    .filter((r) => r && r.applic != null)
    .map((r) => ({
      seq: Number.parseInt(String(r.seq ?? "0"), 10) || 0,
      text: String(r.applic),
    }))
    .sort((a, b) => a.seq - b.seq)
    .map((r) => r.text)
    .join("");
}

// ---------------------------------------------------------------------------
// Statement parsing (deterministic; unparseable statements stay verbatim)
// ---------------------------------------------------------------------------

export interface LabelStatement {
  /** Crop prefix when the line is "CROP: statement", else null. */
  crop: string | null;
  statement: string;
  section: "withholding" | "reentry" | "other";
}

const CROP_LINE = /^([A-Z][A-Z0-9 ()/&,.'-]{0,60}?):\s*(\S.*)$/;

/**
 * Split reassembled label comments into statements. Section headers (all-caps
 * lines without a crop prefix) scope what a crop line may assert: WHP numbers
 * are only read inside a withholding section or from self-descriptive
 * harvest statements.
 */
export function parseLabelStatements(text: string): LabelStatement[] {
  const out: LabelStatement[] = [];
  let section: LabelStatement["section"] = "other";
  for (const rawLine of text.split("\n")) {
    const line = rawLine.trim();
    if (!line) continue;
    const cropMatch = CROP_LINE.exec(line);
    if (cropMatch) {
      out.push({
        crop: cropMatch[1].trim(),
        statement: cropMatch[2].trim(),
        section,
      });
      continue;
    }
    if (/WITHHOLDING/i.test(line)) {
      section = "withholding";
    } else if (/RE-?ENTRY|SAFETY DIRECTIONS/i.test(line)) {
      section = "reentry";
    } else if (line === line.toUpperCase() && /[A-Z]{4,}/.test(line)) {
      section = "other";
    }
    // Mixed-case detail lines ("Harvest") keep the current section.
    out.push({ crop: null, statement: line, section });
  }
  return out;
}

const HARVEST_DAYS = /DO\s+NOT\s+HARVEST\s+FOR\s+(\d+)\s*DAYS?\b/i;
const HARVEST_WEEKS = /DO\s+NOT\s+HARVEST\s+FOR\s+(\d+)\s*WEEKS?\b/i;
const NOT_REQUIRED = /NOT\s+REQUIRED\s+WHEN\s+USED\s+AS\s+DIRECTED/i;

/**
 * Harvest WHP in days from one label statement, or null when the statement
 * does not state one in a recognised form (the wording is preserved
 * verbatim elsewhere — a number is never guessed).
 */
export function whpDaysFromStatement(
  statement: string,
  section: LabelStatement["section"],
): number | null {
  const days = HARVEST_DAYS.exec(statement);
  if (days) return Number.parseInt(days[1], 10);
  const weeks = HARVEST_WEEKS.exec(statement);
  if (weeks) return Number.parseInt(weeks[1], 10) * 7;
  // "Not required" is only a WHP statement inside a withholding section —
  // the same words appear in unrelated label sections.
  if (section === "withholding" && NOT_REQUIRED.test(statement)) return 0;
  return null;
}

const RE_ENTRY_CONTEXT = /RE-?ENTER|RE-?ENTRY|DO\s+NOT\s+ALLOW\s+ENTRY/i;
const HOURS = /(\d+)\s*HOURS?\b/i;
const DAYS = /(\d+)\s*DAYS?\b/i;

/** Whether a statement is about re-entry at all. */
export function isReentryStatement(statement: string): boolean {
  return RE_ENTRY_CONTEXT.test(statement);
}

/**
 * Re-entry period in hours from one re-entry statement, or null when the
 * label states a condition rather than a period ("until the spray has
 * dried") — the wording is kept, the number is never invented.
 */
export function reentryHoursFromStatement(statement: string): number | null {
  if (!isReentryStatement(statement)) return null;
  const hours = HOURS.exec(statement);
  if (hours) return Number.parseInt(hours[1], 10);
  const days = DAYS.exec(statement);
  if (days) return Number.parseInt(days[1], 10) * 24;
  return null;
}

// ---------------------------------------------------------------------------
// Deterministic crop/target correspondence (never fuzzy)
// ---------------------------------------------------------------------------

const GENERIC_CROP_TOKENS = new Set([
  "FRUIT",
  "FRUITS",
  "NUT",
  "NUTS",
  "TREE",
  "TREES",
  "CROP",
  "CROPS",
  "VINE",
  "VINES",
  "WINE",
  "TABLE",
  "AND",
  "OTHER",
]);

function cropTokens(raw: string): Set<string> {
  const tokens = String(raw)
    .toUpperCase()
    .replace(/[^A-Z0-9]+/g, " ")
    .trim()
    .split(/\s+/)
    .map((t) => {
      // Viticulture stem: GRAPE / GRAPES / GRAPEVINE(S) / WINEGRAPE(S) are
      // the same crop noun on labels and in the register's host table.
      if (t.includes("GRAPE")) return "GRAPE";
      return t.length > 3 && t.endsWith("S") ? t.slice(0, -1) : t;
    })
    .filter((t) => t && !GENERIC_CROP_TOKENS.has(t));
  return new Set(tokens);
}

/**
 * Whether two crop wordings name the same crop: at least one shared SPECIFIC
 * token after normalisation/singularisation. "GRAPEVINE" ↔ "GRAPEVINES" ↔
 * "Grapes (winegrapes)" correspond; "GRAPEVINE" ↔ "ALMONDS" never do.
 */
export function cropsCorrespond(a: string, b: string): boolean {
  const ta = cropTokens(a);
  const tb = cropTokens(b);
  if (!ta.size || !tb.size) return false;
  for (const t of ta) if (tb.has(t)) return true;
  return false;
}

function targetNorm(raw: string): string {
  return String(raw)
    .toUpperCase()
    .replace(/[^A-Z0-9]+/g, " ")
    .trim()
    // The register qualifies some pests with the crop ("DOWNY MILDEW ON
    // GRAPE"); the qualifier is crop context, not part of the target.
    .replace(/\s+ON\s+[A-Z ]+$/, "")
    .trim();
}

/**
 * Whether two target wordings name the same target: normalised equality or a
 * word-boundary prefix ("BOTRYTIS" ↔ "BOTRYTIS CINEREA"). Never substring
 * matching in the middle of words.
 */
export function targetsCorrespond(a: string, b: string): boolean {
  const na = targetNorm(a);
  const nb = targetNorm(b);
  if (!na || !nb) return false;
  if (na === nb) return true;
  return na.startsWith(`${nb} `) || nb.startsWith(`${na} `);
}

/** VineTrack spray-target enum, only when the register wording maps cleanly. */
export function targetEnumFor(pestDesc: string): string | undefined {
  const value = String(pestDesc).toUpperCase();
  if (value.includes("POWDERY MILDEW")) return "powdery_mildew";
  if (value.includes("DOWNY MILDEW")) return "downy_mildew";
  if (value.includes("BOTRYTIS") || value.includes("GREY MOULD")) return "botrytis";
  return undefined;
}

// ---------------------------------------------------------------------------
// Evidence assembly
// ---------------------------------------------------------------------------

export interface LabelEvidenceInput {
  pcode: string;
  useRows: Array<{ hostcode?: unknown; pestcode?: unknown }>;
  hostRows: Array<{ hostcode?: unknown; hostdesc?: unknown }>;
  pestRows: Array<{ pestcode?: unknown; pestdesc?: unknown }>;
  commentRows: Array<{ seq?: unknown; applic?: unknown }>;
  retrievedAt: string;
  claimsReference: string;
  statementsReference: string | null;
}

/**
 * Build official label evidence from the register's published label claim
 * data. Every fact is either verbatim register data or a strictly parsed
 * number backed by a verbatim statement; every gap is recorded, never filled.
 */
export function buildLabelEvidence(input: LabelEvidenceInput): LabelEvidence {
  const hostsByCode = new Map<string, string>();
  for (const h of input.hostRows) {
    if (h?.hostcode && h?.hostdesc) {
      hostsByCode.set(String(h.hostcode), String(h.hostdesc).trim());
    }
  }
  const pestsByCode = new Map<string, string>();
  for (const p of input.pestRows) {
    if (p?.pestcode && p?.pestdesc) {
      pestsByCode.set(String(p.pestcode), String(p.pestdesc).trim());
    }
  }

  const unresolved = new Set<string>();
  const statements = parseLabelStatements(
    assembleProductComments(input.commentRows),
  );

  // Product-level re-entry evidence (labels state it once, not per crop).
  const productReentry = statements.filter(
    (s) => s.crop === null && isReentryStatement(s.statement),
  );

  const claims: LabelUseClaim[] = [];
  for (const row of input.useRows) {
    const hostCode = String(row?.hostcode ?? "").trim();
    const pestCode = String(row?.pestcode ?? "").trim();
    if (!hostCode || !pestCode) continue;
    const crop = hostsByCode.get(hostCode);
    const targetRaw = pestsByCode.get(pestCode);
    if (!crop || !targetRaw) {
      // The register claims a use it cannot name for us: the claim is
      // omitted rather than fabricated, and the gap is recorded.
      unresolved.add(`registered_use_claim:${hostCode}:${pestCode}`);
      continue;
    }

    const cropStatements = statements.filter(
      (s) => s.crop !== null && cropsCorrespond(crop, s.crop),
    );
    const claim: LabelUseClaim = {
      crop,
      target_raw: targetRaw,
      statements: cropStatements.map((s) => `${s.crop}: ${s.statement}`),
    };
    const target = targetEnumFor(targetRaw);
    if (target) claim.target = target;

    for (const s of cropStatements) {
      const whp = whpDaysFromStatement(s.statement, s.section);
      if (whp !== null && claim.withholding_period_days === undefined) {
        claim.withholding_period_days = whp;
      }
      const reentry = reentryHoursFromStatement(s.statement);
      if (reentry !== null && claim.re_entry_period_hours === undefined) {
        claim.re_entry_period_hours = reentry;
      }
    }
    if (
      claim.re_entry_period_hours === undefined && productReentry.length
    ) {
      const hours = productReentry
        .map((s) => reentryHoursFromStatement(s.statement))
        .find((h) => h !== null);
      if (hours !== null && hours !== undefined) {
        claim.re_entry_period_hours = hours;
      }
      claim.statements = [
        ...claim.statements,
        ...productReentry.map((s) => s.statement),
      ];
    }
    claims.push(claim);
  }

  // Honest gaps, per label context — never one generic entry.
  const cropsSeen = new Set<string>();
  for (const claim of claims) {
    if (cropsSeen.has(claim.crop)) continue;
    cropsSeen.add(claim.crop);
    // The register publishes no machine-readable rate table: every claimed
    // crop's rates await the label document at admin review.
    unresolved.add(`rates:${claim.crop}`);
    if (claim.withholding_period_days === undefined) {
      unresolved.add(`withholding_period:${claim.crop}`);
    }
  }
  if (claims.length && claims.every((c) => c.re_entry_period_hours === undefined)) {
    const hasReentryWording = statements.some((s) => isReentryStatement(s.statement));
    if (!hasReentryWording) unresolved.add("re_entry_period_hours");
  }

  const sources: WireDataSource[] = claims.length
    ? [{
      kind: "manufacturer_label",
      name: `APVMA-approved label — registered use claims (product ${input.pcode})`,
      reference: input.claimsReference,
      retrieved_at: input.retrievedAt,
    }]
    : [];
  if (claims.length && input.statementsReference && statements.length) {
    sources.push({
      kind: "manufacturer_label",
      name: `APVMA-approved label — label statements (product ${input.pcode})`,
      reference: input.statementsReference,
      retrieved_at: input.retrievedAt,
    });
  }

  return {
    claims,
    statements: statements.map((s) => (s.crop ? `${s.crop}: ${s.statement}` : s.statement)),
    sources,
    unresolved: Array.from(unresolved).sort(),
  };
}

// ---------------------------------------------------------------------------
// Merge: label evidence over the AI extraction (uses)
// ---------------------------------------------------------------------------

export interface LabelUseMergeResult {
  uses: any[];
  conflicts: WireConflict[];
}

function pushConflict(list: WireConflict[], entry: WireConflict): void {
  const dup = list.some(
    (c) =>
      c.field === entry.field &&
      c.extracted_value === entry.extracted_value &&
      c.authoritative_value === entry.authoritative_value,
  );
  if (!dup) list.push(entry);
}

/**
 * Serve the label's registered use claims, letting the AI extraction
 * contribute ONLY clearly-attributed detail (rates) to the claim it matches.
 *
 *   * The claim set (which crops, which targets) is the label's — an AI use
 *     with no corresponding claim is dropped and recorded as a conflict.
 *   * WHP/re-entry: the label value wins where stated; an AI disagreement
 *     becomes a structured conflict. Where the label is silent, an AI value
 *     may be carried but stays attributed to ai_interpretation — it is NEVER
 *     promoted to label evidence.
 *   * Distinct claims stay distinct: rates attach per crop AND target, never
 *     collapsed across contexts.
 *   * Every served use carries field-level provenance (additive `provenance`
 *     key; both apps' decoders ignore unknown keys).
 */
export function mergeLabelEvidenceIntoUses(
  aiUses: any[],
  evidence: LabelEvidence,
): LabelUseMergeResult {
  const conflicts: WireConflict[] = [];
  const matchedAi = new Set<number>();

  const uses = evidence.claims.map((claim) => {
    const aiIndex = aiUses.findIndex(
      (u, i) =>
        !matchedAi.has(i) &&
        cropsCorrespond(String(u?.crop ?? ""), claim.crop) &&
        targetsCorrespond(String(u?.target_raw ?? ""), claim.target_raw),
    );
    const ai = aiIndex >= 0 ? aiUses[aiIndex] : null;
    if (aiIndex >= 0) matchedAi.add(aiIndex);

    const use: any = {
      crop: claim.crop,
      target_raw: claim.target_raw,
      rates: Array.isArray(ai?.rates) ? ai.rates : [],
    };
    if (claim.target) use.target = claim.target;
    else if (ai?.target) use.target = ai.target;

    const provenance: Record<string, string | null> = {
      claim: "manufacturer_label",
      rates: use.rates.length ? "ai_interpretation" : null,
      withholding_period: null,
      re_entry: null,
      restrictions: null,
    };

    // ---- WHP: label statement wins; disagreement is a conflict ------------
    const aiWhp = typeof ai?.withholding_period_days === "number"
      ? ai.withholding_period_days
      : null;
    if (claim.withholding_period_days !== undefined) {
      use.withholding_period_days = claim.withholding_period_days;
      provenance.withholding_period = "manufacturer_label";
      if (aiWhp !== null && aiWhp !== claim.withholding_period_days) {
        pushConflict(conflicts, {
          field: "withholding_period_days",
          extracted_value: `${aiWhp} days (${claim.crop})`,
          authoritative_value:
            `${claim.withholding_period_days} days — ${claim.statements.join(" / ") || "label statement"}`,
          extracted_source: "ai_interpretation",
          authoritative_source: "manufacturer_label",
        });
      }
    } else if (aiWhp !== null) {
      use.withholding_period_days = aiWhp;
      provenance.withholding_period = "ai_interpretation";
    }

    // ---- Re-entry: same discipline ----------------------------------------
    const aiReentry = typeof ai?.re_entry_period_hours === "number"
      ? ai.re_entry_period_hours
      : null;
    if (claim.re_entry_period_hours !== undefined) {
      use.re_entry_period_hours = claim.re_entry_period_hours;
      provenance.re_entry = "manufacturer_label";
      if (aiReentry !== null && aiReentry !== claim.re_entry_period_hours) {
        pushConflict(conflicts, {
          field: "re_entry_period_hours",
          extracted_value: `${aiReentry} hours (${claim.crop})`,
          authoritative_value: `${claim.re_entry_period_hours} hours — label statement`,
          extracted_source: "ai_interpretation",
          authoritative_source: "manufacturer_label",
        });
      }
    } else if (aiReentry !== null) {
      use.re_entry_period_hours = aiReentry;
      provenance.re_entry = "ai_interpretation";
    }

    // ---- Restrictions: verbatim label statements win -----------------------
    if (claim.statements.length) {
      use.restrictions = claim.statements.join("\n");
      provenance.restrictions = "manufacturer_label";
    } else if (typeof ai?.restrictions === "string" && ai.restrictions.trim()) {
      use.restrictions = ai.restrictions;
      provenance.restrictions = "ai_interpretation";
    }

    use.provenance = provenance;
    return use;
  });

  // AI uses with no corresponding label claim are NOT served as registered
  // uses — the label's claim set is authoritative for WHICH uses exist.
  aiUses.forEach((u, i) => {
    if (matchedAi.has(i)) return;
    const crop = String(u?.crop ?? "").trim();
    const targetRaw = String(u?.target_raw ?? "").trim();
    if (!crop && !targetRaw) return;
    pushConflict(conflicts, {
      field: "registered_uses",
      extracted_value: [crop, targetRaw].filter(Boolean).join(" — "),
      authoritative_value: "not a registered use claim on the current approved label",
      extracted_source: "ai_interpretation",
      authoritative_source: "manufacturer_label",
    });
  });

  return { uses, conflicts };
}

// ---------------------------------------------------------------------------
// Refresh signatures (order-independent label-claims comparison)
// ---------------------------------------------------------------------------

function signatureEntry(
  crop: unknown,
  targetRaw: unknown,
  whp: unknown,
  reentry: unknown,
): string {
  return [
    String(crop ?? "").trim().toUpperCase(),
    String(targetRaw ?? "").trim().toUpperCase(),
    typeof whp === "number" ? String(whp) : "",
    typeof reentry === "number" ? String(reentry) : "",
  ].join("|");
}

/** Canonical signature of fresh label evidence claims. */
export function labelClaimsSignature(evidence: LabelEvidence): string {
  return evidence.claims
    .map((c) =>
      signatureEntry(
        c.crop,
        c.target_raw,
        c.withholding_period_days,
        c.re_entry_period_hours,
      )
    )
    .sort()
    .join(" ; ");
}

/** Canonical signature of a master row's stored registered uses. */
export function storedUsesSignature(uses: any[]): string {
  return (Array.isArray(uses) ? uses : [])
    .map((u) =>
      signatureEntry(
        u?.crop,
        u?.target_raw,
        u?.withholding_period_days,
        u?.re_entry_period_hours,
      )
    )
    .sort()
    .join(" ; ");
}

/** Compact human-readable summary for refresh diffs. */
export function usesSummary(
  entries: Array<{ crop?: unknown; target_raw?: unknown; withholding_period_days?: unknown }>,
): string {
  if (!entries.length) return "(none)";
  return entries
    .map((e) => {
      const whp = typeof e?.withholding_period_days === "number"
        ? `, WHP ${e.withholding_period_days}d`
        : "";
      return `${String(e?.crop ?? "").trim()} — ${String(e?.target_raw ?? "").trim()}${whp}`;
    })
    .join("; ");
}
