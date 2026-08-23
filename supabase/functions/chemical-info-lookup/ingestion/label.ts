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
 * PubCRIS stores each product's comment text as fixed-width 40-character
 * lines of a CRLF stream (`seq` is literally "Line No" in the dataset's
 * field metadata), sliced blindly — mid-word ("GRAP" + "EVINES") or ON an
 * inter-word space. The published extract then strips `\r` and trims each
 * chunk's edge whitespace (verified on a 5,000-row live sample: no stored
 * chunk starts or ends with a space). Two artefacts follow:
 *
 *   * mid-word slice   → "GRAP" + "EVINES"        → join with NO separator
 *   * slice on a space → "…AFTER" + "APPLICATION" → the space sat at a
 *     chunk edge and was trimmed away → restore exactly one space
 */
const PRODCOM_SLICE_WIDTH = 40;

const WORD_CHAR = /[A-Za-z0-9]/;
const CLOSING_PUNCT = /[.,:;!?)]/;

/**
 * Reassemble the register's chunked label-comment rows into one text block,
 * restoring ONLY the boundary spaces the publication's trimming provably
 * removed — never inventing whitespace, never splitting a reunited word.
 *
 * Evidence per chunk: a non-final chunk's pre-trim length is exactly the
 * slice width, and every stored `\n` was `\r\n` before `\r`-stripping, so
 * `width − (stored length + \n count)` counts the edge whitespace trimmed
 * off that chunk. Each trimmed unit funds AT MOST one restored space at a
 * seam adjacent to that chunk:
 *
 *   * seams touching a newline never take a space (the line break already
 *     separates, and a `\r` stripped at the seam shows up as deficit too);
 *   * word–word seams are funded first (word integrity is what statement
 *     parsing depends on), then closing-punctuation–letter seams;
 *   * seams are funded left to right — for the verified live case
 *     (91636: " APPLICATION…" lost its leading space) this places the
 *     space at the true seam and leaves the mid-word "HARVES"+"T" bare;
 *   * unfunded seams keep the bare join; unspent deficit is dropped
 *     (it was a stripped `\r` or line-edge whitespace — cosmetic).
 *
 * If the register ever changes its slice width, deficits clamp to zero and
 * this degrades to the plain bare join — never to invented whitespace.
 */
export function assembleProductComments(
  rows: Array<{ seq?: unknown; applic?: unknown }>,
): string {
  const chunks = rows
    .filter((r) => r && r.applic != null && String(r.applic).length > 0)
    .map((r) => ({
      seq: Number.parseInt(String(r.seq ?? "0"), 10) || 0,
      text: String(r.applic),
    }))
    .sort((a, b) => a.seq - b.seq)
    .map((r) => r.text);
  if (chunks.length <= 1) return chunks.join("");

  // Pre-trim length: stored text plus one stripped `\r` per stored `\n`.
  const adjusted = chunks.map((t) => t.length + (t.split("\n").length - 1));
  // Edge whitespace trimmed off each NON-FINAL chunk (the final chunk is
  // the remainder of the stream — its length proves nothing).
  const deficit = chunks.map((_, i) =>
    i < chunks.length - 1
      ? Math.max(0, PRODCOM_SLICE_WIDTH - adjusted[i])
      : 0
  );

  const spaceAt = new Array<boolean>(chunks.length - 1).fill(false);
  const spend = (i: number): boolean => {
    if (deficit[i] > 0) {
      deficit[i] -= 1;
      return true;
    }
    return false;
  };
  const passes: ReadonlyArray<(left: string, right: string) => boolean> = [
    (l, r) => WORD_CHAR.test(l) && WORD_CHAR.test(r),
    (l, r) => CLOSING_PUNCT.test(l) && /[A-Za-z(]/.test(r),
  ];
  for (const eligible of passes) {
    for (let s = 0; s < chunks.length - 1; s++) {
      if (spaceAt[s]) continue;
      const left = chunks[s].slice(-1);
      const right = chunks[s + 1].slice(0, 1);
      if (left === "\n" || right === "\n") continue;
      if (!eligible(left, right)) continue;
      if (spend(s) || spend(s + 1)) spaceAt[s] = true;
    }
  }

  return chunks
    .map((t, i) => (i < spaceAt.length && spaceAt[i] ? `${t} ` : t))
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
 * The same "<crops>: <statement>" shape, but tolerating the Title Case APVMA
 * actually prints in the WITHHOLDING PERIODS section ("Bananas:",
 * "Grapevines:", "Custard apples and Pawpaws (papaya):").
 *
 * This is used ONLY where the right-hand side is itself a recognised WHP
 * wording, which is what keeps it safe: an unrelated Title Case line such as
 * "First Aid Instructions: If poisoning occurs…" can never be mistaken for a
 * crop, because its statement states no withholding period.
 */
const TITLE_CASE_CROP_LINE = /^([A-Za-z][A-Za-z0-9 ()/&,.'-]{0,60}?):\s*(\S.*)$/;

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
    // A Title Case crop prefix, proven to BE one by the statement after the
    // colon stating a withholding period. Without this,
    // "Bananas: NOT REQUIRED WHEN USED AS DIRECTED" reads as a PRODUCT-WIDE
    // statement and becomes every crop's WHP — including grapevines'.
    //
    // Section-independent on purpose: a long withholding block wraps, and a
    // wrapped ALL-CAPS continuation line ("APPLICATION PAPAYA LEAVES MUST
    // NOT BE…") looks exactly like a new section heading, so by the time the
    // grapevine line is reached the parser no longer believes it is in the
    // withholding section. `whpDaysFromStatement` still applies its own
    // section rule to "not required", which is the wording that actually
    // needs the context; "DO NOT HARVEST FOR 30 DAYS" describes itself.
    const titled = TITLE_CASE_CROP_LINE.exec(line);
    if (titled && whpDaysFromStatement(titled[2].trim(), section) !== null) {
      out.push({
        crop: titled[1].trim(),
        statement: titled[2].trim(),
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

/**
 * Whether two target wordings are the SAME target, with no prefix latitude.
 *
 * Prefix correspondence is right for a COMPLETE target context: a label cell
 * reading "Botrytis" really is the register's "BOTRYTIS CINEREA". It is wrong
 * for a wrapped FRAGMENT of a longer target, where the same latitude lets
 * "Leaf spot" — the third printed line of "Phomopsis Cane and Leaf spot" —
 * claim to be the unrelated register target "LEAF SPOT - ALTERNARIA
 * CERCOSPORA". A fragment must name its target exactly or not at all.
 */
export function targetsAreEquivalent(a: string, b: string): boolean {
  const na = targetNorm(a);
  const nb = targetNorm(b);
  return Boolean(na) && na === nb;
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
  /**
   * Disagreements a HUMAN still needs to resolve. Under the document-authority
   * rule this is now only ever document-vs-register, never AI-vs-label.
   */
  conflicts: WireConflict[];
  /**
   * AI readings that stronger authority has already settled — recorded for
   * audit, never surfaced as an operator-blocking conflict.
   *
   * A grower cannot adjudicate "the model said 200 g, the approved label did
   * not". The label already won; asking them to resolve it makes a correctly
   * resolved product look broken.
   */
  superseded: WireConflict[];
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

/** Order-independent identity of one rate reading (label/raw_text excluded
 * — an AI paraphrase of the same number is the same reading). */
function rateKey(r: any): string {
  return [
    String(r?.basis ?? ""),
    r?.value ?? "",
    r?.min_value ?? "",
    r?.max_value ?? "",
    String(r?.unit ?? "").toLowerCase(),
  ].join("|");
}

function ratesEquivalent(a: any[], b: any[]): boolean {
  return a.map(rateKey).sort().join(";") === b.map(rateKey).sort().join(";");
}

/** Compact human-readable rate list for conflict entries and diffs. */
export function ratesSummary(rates: any[]): string {
  const list = (Array.isArray(rates) ? rates : []).map((r) => {
    if (r?.basis === "other") {
      return `"${String(r?.raw_text ?? "").slice(0, 60)}"`;
    }
    const amount = r?.value != null
      ? String(r.value)
      : `${r?.min_value ?? "?"}–${r?.max_value ?? "?"}`;
    const per = r?.basis === "per_hectare" || r?.basis === "range_per_hectare"
      ? "ha"
      : "100 L";
    return `${amount} ${String(r?.unit ?? "")}/${per}`;
  });
  return list.join(" + ") || "(none)";
}

/**
 * Serve the label's registered use claims, letting the AI extraction
 * contribute ONLY clearly-attributed detail (rates) to the claim it matches.
 *
 *   * The claim set (which crops, which targets) is the label's — an AI use
 *     with no corresponding claim is dropped and recorded as a conflict.
 *   * Rates (Stage LD-2): DOCUMENT-bound rates outrank AI rates on the same
 *     claim — an AI disagreement becomes a structured conflict and the AI
 *     reading is never served alongside. AI rates survive only on claims
 *     the document gave no rates, still attributed ai_interpretation.
 *   * WHP/re-entry: the label value wins where stated; an AI disagreement
 *     becomes a structured conflict. Where the label is silent, an AI value
 *     may be carried but stays attributed to ai_interpretation — it is NEVER
 *     promoted to label evidence.
 *   * Refresh passes re-merge STORED uses (which carry their own provenance
 *     from an earlier merge): a stored manufacturer_label fact rides through
 *     an extraction-failure pass WITHOUT downgrade — raw AI extractions
 *     never carry a provenance key, so the serving path is unaffected.
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
  const superseded: WireConflict[] = [];
  const matchedAi = new Set<number>();

  // Did a label DOCUMENT extraction pass actually complete for this product?
  //
  // This is the whole authority question for rates. Before Stage LD-2 existed,
  // an AI rate riding alongside a label claim was the only rate available and
  // was better than nothing. Now, when the approved document has been read,
  // the document IS the rate authority — and a use it gave no rate to has no
  // registered rate. Absence in a successfully parsed authoritative source is
  // a fact about the label, not an invitation for the model to fill the gap.
  const documentParsed = evidence.document !== undefined;

  const uses = evidence.claims.map((claim) => {
    const aiIndex = aiUses.findIndex(
      (u, i) =>
        !matchedAi.has(i) &&
        cropsCorrespond(String(u?.crop ?? ""), claim.crop) &&
        targetsCorrespond(String(u?.target_raw ?? ""), claim.target_raw),
    );
    const ai = aiIndex >= 0 ? aiUses[aiIndex] : null;
    if (aiIndex >= 0) matchedAi.add(aiIndex);

    const carried = (key: string): string =>
      ai?.provenance?.[key] === "manufacturer_label"
        ? "manufacturer_label"
        : "ai_interpretation";

    const docRates = Array.isArray(claim.rates) && claim.rates.length
      ? claim.rates
      : null;
    const aiRates: any[] = Array.isArray(ai?.rates) ? ai.rates : [];
    // Rule B: with the document parsed, canonical rates are the document's or
    // they are empty. Rule A (no usable document) keeps the previous
    // behaviour, where a clearly-attributed AI rate is still the only reading
    // anyone has.
    const canonicalRates = docRates ?? (documentParsed ? [] : aiRates);
    const use: any = {
      crop: claim.crop,
      target_raw: claim.target_raw,
      rates: canonicalRates,
    };
    if (claim.target) use.target = claim.target;
    else if (ai?.target) use.target = ai.target;

    const provenance: Record<string, string | null> = {
      claim: "manufacturer_label",
      rates: docRates
        ? "manufacturer_label"
        : (use.rates.length ? carried("rates") : null),
      withholding_period: null,
      re_entry: null,
      restrictions: null,
    };

    // ---- Rates: the document is authority; an AI reading is superseded ----
    if (
      aiRates.length && carried("rates") === "ai_interpretation" &&
      (docRates ? !ratesEquivalent(aiRates, docRates) : documentParsed)
    ) {
      pushConflict(superseded, {
        field: "label_rates",
        extracted_value: `${ratesSummary(aiRates)} (${claim.crop} — ${claim.target_raw})`,
        authoritative_value: docRates
          ? `${ratesSummary(docRates)} — official label document`
          : "the approved label document states no rate for this use",
        extracted_source: "ai_interpretation",
        authoritative_source: "manufacturer_label",
      });
    }

    // ---- WHP: label statement wins; disagreement is a conflict ------------
    const aiWhp = typeof ai?.withholding_period_days === "number"
      ? ai.withholding_period_days
      : null;
    if (claim.withholding_period_days !== undefined) {
      use.withholding_period_days = claim.withholding_period_days;
      provenance.withholding_period = "manufacturer_label";
      if (aiWhp !== null && aiWhp !== claim.withholding_period_days) {
        pushConflict(superseded, {
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
      provenance.withholding_period = carried("withholding_period");
    }

    // ---- Re-entry: same discipline ----------------------------------------
    const aiReentry = typeof ai?.re_entry_period_hours === "number"
      ? ai.re_entry_period_hours
      : null;
    if (claim.re_entry_period_hours !== undefined) {
      use.re_entry_period_hours = claim.re_entry_period_hours;
      provenance.re_entry = "manufacturer_label";
      if (aiReentry !== null && aiReentry !== claim.re_entry_period_hours) {
        pushConflict(superseded, {
          field: "re_entry_period_hours",
          extracted_value: `${aiReentry} hours (${claim.crop})`,
          authoritative_value: `${claim.re_entry_period_hours} hours — label statement`,
          extracted_source: "ai_interpretation",
          authoritative_source: "manufacturer_label",
        });
      }
    } else if (aiReentry !== null) {
      use.re_entry_period_hours = aiReentry;
      provenance.re_entry = carried("re_entry");
    }

    // ---- Restrictions: verbatim label statements win -----------------------
    if (claim.statements.length) {
      use.restrictions = claim.statements.join("\n");
      provenance.restrictions = "manufacturer_label";
    } else if (typeof ai?.restrictions === "string" && ai.restrictions.trim()) {
      use.restrictions = ai.restrictions;
      provenance.restrictions = carried("restrictions");
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
    pushConflict(superseded, {
      field: "registered_uses",
      extracted_value: [crop, targetRaw].filter(Boolean).join(" — "),
      authoritative_value: "not a registered use claim on the current approved label",
      extracted_source: "ai_interpretation",
      authoritative_source: "manufacturer_label",
    });
  });

  return { uses, conflicts, superseded };
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

function ratesSignaturePart(rates: any[]): string {
  return (Array.isArray(rates) ? rates : []).map(rateKey).sort().join(",");
}

/** Canonical signature of fresh label evidence claims. Document-bound rates
 * (Stage LD-2) are part of the claim content — a changed label rate is a
 * material change. */
export function labelClaimsSignature(evidence: LabelEvidence): string {
  return evidence.claims
    .map((c) =>
      [
        signatureEntry(
          c.crop,
          c.target_raw,
          c.withholding_period_days,
          c.re_entry_period_hours,
        ),
        ratesSignaturePart(c.rates ?? []),
      ].join("||")
    )
    .sort()
    .join(" ; ");
}

/**
 * Canonical signature of a master row's stored registered uses.
 * `includeDocumentRates` must mirror whether THIS refresh pass extracted the
 * label document: stored document-backed rates are compared only against a
 * fresh extraction — an extraction outage says NOTHING about them (absence
 * is never drift, so a failed pass can never strip or churn stored rates).
 * AI-attributed rates are never part of the signature.
 */
export function storedUsesSignature(
  uses: any[],
  includeDocumentRates = false,
): string {
  return (Array.isArray(uses) ? uses : [])
    .map((u) =>
      [
        signatureEntry(
          u?.crop,
          u?.target_raw,
          u?.withholding_period_days,
          u?.re_entry_period_hours,
        ),
        includeDocumentRates && u?.provenance?.rates === "manufacturer_label"
          ? ratesSignaturePart(u?.rates)
          : "",
      ].join("||")
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
