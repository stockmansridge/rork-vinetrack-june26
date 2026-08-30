// Official label DOCUMENT extraction (Stage LD-2) — AU / APVMA eLabels.
//
// PURPOSE
//   The register publishes NO machine-readable rate table (Stage 4 leaves a
//   `rates:<crop>` gap on every claimed crop). The official label document
//   discovered by Stage LD-1 DOES print the Directions-for-Use table. This
//   module turns the document's PDF text layer into structured label rates,
//   WHP/re-entry corroboration and verbatim critical comments — bound to the
//   ALREADY-AUTHORITATIVE register claims, failing closed on any uncertain
//   association.
//
// EXTRACTION DISCIPLINE
//   * Input is ONLY the authoritative document Stage LD-1 confirmed and
//     fetched. No other PDF is ever parsed.
//   * Pure deterministic parsing: a bounded rate grammar over the label
//     wordings measured on real eLabels documents. Anything the grammar
//     cannot parse is carried VERBATIM (`basis: "other"`, `raw_text`) — a
//     quote is deterministic, a numeric guess is not. NO AI anywhere.
//   * The fail-closed join: a DFU row's rates attach to a register claim
//     only when the crop corresponds AND at least one target corresponds
//     (the same regression-pinned `cropsCorrespond`/`targetsCorrespond`
//     used everywhere else). An unmatched or ambiguous row serves NOTHING —
//     it is preserved verbatim in `unbound_rows` for admin review.
//   * WHP / re-entry are parsed SEPARATELY with the SAME strict statement
//     patterns as Stage 4 (label.ts). Where the register statements already
//     state a value, the document is corroboration: a disagreement becomes
//     a structured conflict (both sides manufacturer_label — reviewed,
//     never silently resolved) and the register-published value stands.
//   * Every failure is contained: a document that cannot be parsed leaves
//     the Stage 4 / LD-1 result byte-identical.
//
// WHAT THIS MODULE WILL NEVER DO
//   * Mint a use claim the register does not publish.
//   * Guess a number from wording the grammar cannot parse.
//   * Break a crop/target tie — ambiguity always fails closed.
//   * Let AI establish or alter an authoritative label value.

import type {
  LabelDocumentDiscovery,
  LabelEvidence,
  LabelUseClaim,
  PdfTextItem,
  UnboundDfuRow,
  WireConflict,
  WireLabelRate,
} from "./contract.ts";
import {
  cropsCorrespond,
  isReentryStatement,
  parseLabelStatements,
  reentryHoursFromStatement,
  targetsAreEquivalent,
  targetsCorrespond,
  whpDaysFromCell,
  whpDaysFromStatement,
} from "./label.ts";
import { deriveLabelTargetWordings } from "./label_target_wording.ts";

/** Bumped whenever the deterministic grammar changes (refresh comparability). */
export const LABEL_PARSER_VERSION = 2;

// ---------------------------------------------------------------------------
// Default PDF text extractor (production) — unpdf, the serverless pdf.js
// build (pure JS, no native deps; runs in the Supabase Edge Deno runtime).
// Tests inject captured item fixtures instead (AdapterDeps.extractPdfText).
// ---------------------------------------------------------------------------

/**
 * Extract positioned text items from PDF bytes. Throws on any parser
 * failure — callers treat a throw as "no text this pass" (fail soft).
 */
export async function extractPdfTextItems(
  bytes: Uint8Array,
): Promise<PdfTextItem[]> {
  const { getDocumentProxy } = await import("npm:unpdf@1.8.1");
  const doc = await getDocumentProxy(new Uint8Array(bytes));
  const items: PdfTextItem[] = [];
  for (let page = 1; page <= doc.numPages; page++) {
    const pdfPage = await doc.getPage(page);
    const content = await pdfPage.getTextContent();
    for (const raw of content.items) {
      // deno-lint-ignore no-explicit-any
      const item = raw as any;
      if (typeof item?.str !== "string" || !Array.isArray(item?.transform)) continue;
      items.push({
        page,
        x: Number(item.transform[4]) || 0,
        y: Number(item.transform[5]) || 0,
        width: Number(item.width) || 0,
        str: item.str,
      });
    }
  }
  return items;
}

// ---------------------------------------------------------------------------
// Line assembly (measured: same-line items share y within ±4pt — superscript
// ® marks sit ~3pt above the baseline; word gaps arrive as explicit " "
// items, so concatenation in x order reproduces the printed text verbatim)
// ---------------------------------------------------------------------------

const LINE_Y_TOLERANCE = 4;

export interface TextLine {
  page: number;
  y: number;
  items: Array<{ x: number; width: number; str: string }>;
  text: string;
}

/** Group positioned items into reading-order lines (page asc, y desc). */
export function assembleTextLines(items: PdfTextItem[]): TextLine[] {
  const lines: TextLine[] = [];
  const sorted = [...items]
    .filter((i) => i.str.length > 0)
    .sort((a, b) => a.page - b.page || b.y - a.y || a.x - b.x);
  for (const item of sorted) {
    const line = lines.length ? lines[lines.length - 1] : null;
    if (
      line && line.page === item.page &&
      Math.abs(line.y - item.y) <= LINE_Y_TOLERANCE
    ) {
      line.items.push({ x: item.x, width: item.width, str: item.str });
    } else {
      lines.push({
        page: item.page,
        y: item.y,
        items: [{ x: item.x, width: item.width, str: item.str }],
        text: "",
      });
    }
  }
  for (const line of lines) {
    line.items.sort((a, b) => a.x - b.x);
    line.text = line.items.map((i) => i.str).join("").replace(/\s+/g, " ").trim();
  }
  return lines.filter((l) => l.text.length > 0);
}

// Cells: contiguous runs of items chained by their measured extents.
// A whitespace-only item wider than a real inter-word space (measured
// ≤2.5pt in cells vs 19–140pt between columns) is layout padding — a hard
// column boundary, never text.
const CELL_CHAIN_GAP = 4;
const COLUMN_SPACER_WIDTH = 8;

export interface LineCell {
  x: number;
  text: string;
}

/** Split one line's items into visually contiguous cells. */
export function segmentCells(line: TextLine): LineCell[] {
  interface Acc {
    x: number;
    right: number;
    parts: string[];
  }
  const cells: Acc[] = [];
  for (const item of line.items) {
    if (item.str.trim().length === 0 && item.width > COLUMN_SPACER_WIDTH) {
      continue; // inter-column padding — the next item starts a new cell
    }
    const last = cells.length ? cells[cells.length - 1] : null;
    if (last && item.x - last.right <= CELL_CHAIN_GAP) {
      last.parts.push(item.str);
      last.right = Math.max(last.right, item.x + item.width);
    } else {
      cells.push({ x: item.x, right: item.x + item.width, parts: [item.str] });
    }
  }
  return cells
    .map((c) => ({ x: c.x, text: c.parts.join("").replace(/\s+/g, " ").trim() }))
    .filter((c) => c.text.length > 0);
}

// ---------------------------------------------------------------------------
// Rate grammar (bounded, deterministic — measured label forms only)
// ---------------------------------------------------------------------------

const UNIT_PATTERN = "(mL|ml|L|l|g|kg)";
const NUM = "(\\d+(?:\\.\\d+)?)";
const RANGE_SEP = "(?:or|to|–|—|-)";
const PER_100L = "(?:\\/|per\\b)\\s*100\\s*(?:L\\b|litres?\\b|liters?\\b)";
const PER_HA = "(?:\\/|per\\b)\\s*(?:ha\\b|hectares?\\b)";

const RANGE_100L_RE = new RegExp(
  `${NUM}\\s*${RANGE_SEP}\\s*${NUM}\\s*${UNIT_PATTERN}\\s*${PER_100L}`,
  "gi",
);
const SINGLE_100L_RE = new RegExp(
  `${NUM}\\s*${UNIT_PATTERN}\\b[^0-9]{0,40}?${PER_100L}`,
  "gi",
);
const RANGE_HA_RE = new RegExp(
  `${NUM}\\s*${RANGE_SEP}\\s*${NUM}\\s*${UNIT_PATTERN}\\s*${PER_HA}`,
  "gi",
);
const SINGLE_HA_RE = new RegExp(`${NUM}\\s*${UNIT_PATTERN}\\s*${PER_HA}`, "gi");

function canonicalUnit(raw: string): string {
  const lower = raw.toLowerCase();
  if (lower === "ml") return "mL";
  if (lower === "l") return "L";
  return lower; // g, kg
}

/**
 * The label's own qualifier for a rate ("Dilute spraying: …"), or "".
 * The scan is bounded by the end of the PREVIOUS parsed rate (the masked
 * span), so a preceding rate's trailing unit can never leak into the label.
 */
function rateLabelBefore(
  cell: string,
  masked: boolean[],
  matchStart: number,
): string {
  let boundary = matchStart;
  while (boundary > 0 && !masked[boundary - 1]) boundary--;
  const before = cell.slice(boundary, matchStart);
  const qualifier = /(?:^|[.;)] )\s*([A-Za-z][A-Za-z ()/-]{0,38}?)\s*:\s*$/.exec(
    before.trim().length ? before : "",
  );
  if (qualifier) return qualifier[1].trim();
  const loose = /([A-Za-z][A-Za-z ()/-]{0,38}?)\s*:\s*$/.exec(before);
  return loose ? loose[1].trim() : "";
}

interface RateMatch {
  start: number;
  end: number;
  rate: WireLabelRate;
}

function collectMatches(
  cell: string,
  masked: boolean[],
  re: RegExp,
  build: (m: RegExpExecArray) => Omit<WireLabelRate, "label" | "raw_text">,
): RateMatch[] {
  const out: RateMatch[] = [];
  re.lastIndex = 0;
  let m: RegExpExecArray | null;
  while ((m = re.exec(cell)) !== null) {
    const start = m.index;
    const end = m.index + m[0].length;
    let overlaps = false;
    for (let i = start; i < end; i++) {
      if (masked[i]) {
        overlaps = true;
        break;
      }
    }
    if (overlaps) continue;
    const label = rateLabelBefore(cell, masked, start);
    for (let i = start; i < end; i++) masked[i] = true;
    out.push({
      start,
      end,
      rate: {
        label,
        raw_text: cell,
        ...build(m),
      },
    });
  }
  return out;
}

/**
 * A rate column's basis, taken from the COLUMN HEADER rather than the cell.
 *
 * APVMA tables print the unit once, in the heading ("RATE PER 100 L"), and
 * then a bare quantity in every cell ("200 g"). The quantity alone carries no
 * basis, so without the header the grammar can only quote it verbatim. This
 * is the header speaking for its own column — not an inference.
 */
export type RateBasisHint = "per_100_litres" | "per_hectare" | null;

/**
 * A cell holding NOTHING but a quantity: "200 g", "150 to 200 g",
 * "1.7-2.2 kg", "2.2 to 4.5 kg", optionally with a single footnote marker.
 * Anchored end to end on purpose — "200g + 600mL miscible summer oil" is a
 * tank mix, not a rate this grammar may reduce to one number.
 */
const BARE_QUANTITY_RE = new RegExp(
  `^${NUM}(?:\\s*${RANGE_SEP}\\s*${NUM})?\\s*${UNIT_PATTERN}\\s*\\*?$`,
  "i",
);

/** A cell that states no rate at all: the table's "this column is empty" mark. */
const EMPTY_RATE_CELL_RE = /^(?:[-–—]|nil|n\/a|none)$/i;

/**
 * Wording that belongs to the WITHHOLDING or GRAZING column, never to a rate
 * column. Finding any of it inside a "rate" cell proves the cell was
 * assembled across a column boundary — the reading is corrupt, not merely
 * unparsed, and §10 says corrupt authoritative data must never be served.
 */
const WHP_IN_RATE_CELL_RE =
  /\b\d+\s*(?:days?|weeks?|months?)\b|\((?:H|G)\)|\bWHP\b|\bnot\s+required\b|\bnil\b/i;

/**
 * Whether a rate cell has visibly crossed a column boundary.
 *
 * This is the safety net that would have caught the production defect on its
 * own: "30 days (H) 150 to 200 g" is not a rate wording the grammar failed to
 * parse, it is two columns glued together.
 */
export function rateCellCrossesColumns(rawCell: string): boolean {
  const cell = rawCell.replace(/\s+/g, " ").trim();
  if (!cell) return false;
  // A genuine rate may legitimately mention an interval ("every 14 days") in
  // its own qualifier, so require BOTH a WHP signature AND a quantity that
  // the rate grammar can see — the mixed cell, not the wordy one.
  if (!WHP_IN_RATE_CELL_RE.test(cell)) return false;
  return /\d/.test(cell.replace(WHP_IN_RATE_CELL_RE, ""));
}

/**
 * Parse one DFU rate cell into wire rates. Bounded grammar over measured
 * label forms ("Mix 30 mL of X per 100 litres of water", "35 or 54 mL/100 L",
 * "540 mL/ha", ranges with –/to/or). Every entry carries the verbatim cell
 * text. Unparseable wording → ONE `basis:"other"` verbatim entry. An empty
 * cell → no rates at all.
 *
 * # Multiple rates on one basis (task §4, §5)
 *
 * A registered use legitimately carries SEVERAL rates: a dilute rate and a
 * concentrate rate, an early-season and a late-season rate, a per-100 L and
 * a per-hectare rate side by side. Every one is preserved as its own record.
 *
 * This function previously kept at most ONE rate per basis, and when a cell
 * held two different numbers on the same basis it discarded BOTH and emitted
 * a single `basis:"other"` entry whose `raw_text` was the whole cell — which
 * is how `"2 L / 100 L 3 L / 100 L 3 L / 100 L…"` reached the app. The
 * instinct was sound (never guess which rate applies); the remedy threw away
 * the readings instead of keeping them.
 *
 * Now every distinct reading survives in printed order; an identical repeated
 * reading is deduplicated; where two rates on one basis each carry a
 * DISTINGUISHING qualifier the condition is attached to its own rate; and
 * where they do not, every rate on that basis is flagged
 * `condition_ambiguous` — numbers kept verbatim, association declared
 * unproven. No rate is ever converted between bases, and no condition is
 * ever invented.
 *
 * `basisHint` is the column header's own basis and is consulted ONLY for a
 * cell that is nothing but a quantity. It never overrides wording the cell
 * states for itself: a cell reading "540 mL/ha" in a per-100-L column stays
 * per-hectare, because the cell is more specific than the heading.
 */
export function parseRateCell(
  rawCell: string,
  basisHint: RateBasisHint = null,
): WireLabelRate[] {
  const cell = rawCell.replace(/\s+/g, " ").trim();
  if (!cell) return [];
  if (EMPTY_RATE_CELL_RE.test(cell)) return [];
  const masked = new Array<boolean>(cell.length).fill(false);

  const matches: RateMatch[] = [
    ...collectMatches(cell, masked, RANGE_100L_RE, (m) => ({
      basis: "range_per_100_litres",
      min_value: Number.parseFloat(m[1]),
      max_value: Number.parseFloat(m[2]),
      unit: canonicalUnit(m[3]),
    })),
    ...collectMatches(cell, masked, RANGE_HA_RE, (m) => ({
      basis: "range_per_hectare",
      min_value: Number.parseFloat(m[1]),
      max_value: Number.parseFloat(m[2]),
      unit: canonicalUnit(m[3]),
    })),
    ...collectMatches(cell, masked, SINGLE_100L_RE, (m) => ({
      basis: "per_100_litres",
      value: Number.parseFloat(m[1]),
      unit: canonicalUnit(m[2]),
    })),
    ...collectMatches(cell, masked, SINGLE_HA_RE, (m) => ({
      basis: "per_hectare",
      value: Number.parseFloat(m[1]),
      unit: canonicalUnit(m[2]),
    })),
  ];

  if (!matches.length) {
    const bare = BARE_QUANTITY_RE.exec(cell);
    if (bare && basisHint) {
      const unit = canonicalUnit(bare[3]);
      return [
        bare[2] !== undefined
          ? {
            label: "",
            basis: basisHint === "per_hectare"
              ? "range_per_hectare"
              : "range_per_100_litres",
            min_value: Number.parseFloat(bare[1]),
            max_value: Number.parseFloat(bare[2]),
            unit,
            raw_text: cell,
          }
          : {
            label: "",
            basis: basisHint,
            value: Number.parseFloat(bare[1]),
            unit,
            raw_text: cell,
          },
      ];
    }
    return [{ label: "", basis: "other", unit: "", raw_text: cell }];
  }

  // Keep every DISTINCT reading, in printed order. Identity covers the
  // numbers, the unit AND the label: "Dilute: 35 mL/100 L" and
  // "Concentrate: 35 mL/100 L" are two real rates that happen to share a
  // number, and collapsing them would lose a condition the label states.
  const ordered = matches.sort((a, b) => a.start - b.start).map((m) => m.rate);
  const distinct: WireLabelRate[] = [];
  for (const rate of ordered) {
    const duplicate = distinct.some(
      (r) => sameRateReading(r, rate) && r.label === rate.label,
    );
    if (!duplicate) distinct.push(rate);
  }
  return flagAmbiguousConditions(distinct);
}

/** Whether two rates state the same numbers, unit and basis. */
export function sameRateReading(a: WireLabelRate, b: WireLabelRate): boolean {
  return a.basis === b.basis && a.value === b.value &&
    a.min_value === b.min_value && a.max_value === b.max_value &&
    a.unit === b.unit;
}

/**
 * Flag rates whose governing condition the grammar could not establish.
 *
 * Applied per BASIS. Several rates on one basis need a distinguishing
 * qualifier each, or a reader cannot tell which applies when — the
 * conservative half of task §5. Rates on DIFFERENT bases are never ambiguous
 * with respect to each other: a /100 L rate and a /ha rate are two ways of
 * expressing one instruction, not a choice between two doses.
 *
 * Conditions must be present AND distinct. Two rates both labelled
 * "Grapevines" are no more attributable than two labelled nothing.
 */
export function flagAmbiguousConditions(rates: WireLabelRate[]): WireLabelRate[] {
  const byBasis = new Map<string, WireLabelRate[]>();
  for (const rate of rates) {
    const list = byBasis.get(rate.basis) ?? [];
    list.push(rate);
    byBasis.set(rate.basis, list);
  }

  const ambiguousBases = new Set<string>();
  for (const [basis, list] of byBasis) {
    if (list.length < 2) continue;
    const labels = list.map((r) => r.label.trim().toLowerCase());
    const allLabelled = labels.every((l) => l.length > 0);
    const allDistinct = new Set(labels).size === labels.length;
    if (!allLabelled || !allDistinct) ambiguousBases.add(basis);
  }

  if (!ambiguousBases.size) return rates;
  return rates.map((rate) =>
    ambiguousBases.has(rate.basis) ? { ...rate, condition_ambiguous: true } : rate
  );
}

// ---------------------------------------------------------------------------
// Directions-for-Use table parsing
//
// Measured layouts:
//   * one table WITH a CROP column (Sprayseal 80160);
//   * per-crop "Table N. <Crop>" tables WITHOUT one (Custodia Forte 91636);
//   * one document mixing a SIX-column layout (CROP | DISEASE | RATE PER
//     100 L | RATE PER HECTARE | WHP | CRITICAL COMMENTS) with a FIVE-column
//     one (no per-hectare column) and stacking the rate heading across two
//     printed lines — "RATE PER" above "100 L" (Dithane 59688).
//
// Columns are reconstructed from header anchor x-positions. The heading text
// itself is assembled ACROSS printed lines, because a heading that wraps is
// still one heading: reading only the first line turns "RATE PER 100 L" into
// "RATE PER", which matches no rate pattern, which silently leaves the table
// with the PREVIOUS page's column map. That is how a withholding period ends
// up inside a rate cell.
// ---------------------------------------------------------------------------

export interface DfuRow {
  crop_text: string;
  /** The target cell's visual lines, verbatim (wrap-aware candidates). */
  target_lines: string[];
  /** The rate cell this row's rate should be read from, verbatim. */
  rate_text: string;
  /** Basis the rate COLUMN's heading states, when it states one. */
  rate_basis: RateBasisHint;
  /** A separate per-hectare column's cell, when the table prints one. */
  rate_ha_text: string;
  /** The WHP column's cell, verbatim — captured, never merged into a rate. */
  whp_text: string;
  comments_text: string;
}

const DFU_HEADING = /DIRECTIONS\s+FOR\s+USE/i;
const DFU_FOOTER = /NOT\s+TO\s+BE\s+USED\s+FOR\s+ANY\s+PURPOSE/i;
const TABLE_TITLE = /^Table\s+\d+\s*[.:]?\s+(.+)$/i;

type ColumnKind =
  | "crop"
  | "target"
  | "rate"
  | "rate_100l"
  | "rate_ha"
  | "whp"
  | "comments"
  | "ignored";

/**
 * Words that START a column heading. Deliberately prefix-anchored on RATE and
 * WHP: the rest of the heading may be printed on the line below, and the
 * anchor has to exist before those continuations can be attached to it.
 */
const HEADER_START: ReadonlyArray<RegExp> = [
  /^(CROP|CROPS|SITUATION)$/i,
  /^(DISEASE|DISEASES|PEST|PESTS|DISEASE\/PEST|DISEASES\/PESTS|WEED|WEEDS|INSECT|INSECTS)$/i,
  /^RATE\b/i,
  /^WHP\b/i,
  /^(CRITICAL\s+COMMENTS|CRITICAL\s+USE\s+COMMENTS|COMMENTS):?$/i,
  /^(STATE|STATES)$/i,
];

/**
 * The bounded vocabulary of heading CONTINUATION fragments measured on real
 * eLabels documents. A line built only from these is the rest of the heading,
 * not the table's first row — nothing else is ever absorbed into a heading.
 */
const HEADER_FRAGMENT =
  /^(?:PER|PER\s+100\s*L|PER\s+HECTARE|100\s*L|100|L|HECTARE|HA|Harvest\s*\(H\)|Grazing\s*\(G\)|\(H\)|\(G\)|\(WHP\)|COMMENTS:?|USE\s+COMMENTS)$/i;

/** Classify one FULLY ASSEMBLED heading. */
function classifyHeader(raw: string): ColumnKind {
  const text = raw.replace(/\s+/g, " ").trim();
  if (/^(CROP|CROPS|SITUATION)\b/i.test(text)) return "crop";
  if (/^(DISEASE|DISEASES|PEST|PESTS|WEED|WEEDS|INSECT|INSECTS)\b/i.test(text)) {
    return "target";
  }
  if (/^RATE\b/i.test(text)) {
    // The heading names its own basis. "RATE PER 100 L" and "RATE PER
    // HECTARE" are DIFFERENT columns and must never share a bucket — that
    // is what allowed two independent numbers to be concatenated.
    if (/\b100\s*L\b/i.test(text)) return "rate_100l";
    if (/\b(HECTARE|HA)\b/i.test(text)) return "rate_ha";
    return "rate";
  }
  if (/^WHP\b/i.test(text)) return "whp";
  if (/COMMENTS/i.test(text)) return "comments";
  return "ignored";
}

interface HeaderColumn {
  kind: ColumnKind;
  anchorX: number;
}

interface HeaderAnchor {
  anchorX: number;
  parts: string[];
}

/** How far a continuation fragment may sit from its heading's anchor. */
const HEADER_FRAGMENT_TOLERANCE = 45;

/**
 * Seed anchors from one line's RAW items — the header row's wide
 * justification spacers would otherwise chain its tokens into one cell.
 */
function seedHeaderAnchors(line: TextLine): HeaderAnchor[] | null {
  const anchors: HeaderAnchor[] = [];
  for (const item of line.items) {
    const text = item.str.trim();
    if (!text) continue;
    if (HEADER_START.some((re) => re.test(text))) {
      anchors.push({ anchorX: item.x, parts: [text] });
    }
  }
  if (!anchors.length) return null;
  anchors.sort((a, b) => a.anchorX - b.anchorX);
  return anchors;
}

/**
 * The critical-comments column when its heading is printed somewhere else.
 *
 * Measured on Dithane 59688 page 12: the TREE AND VINE table prints
 * "CRITICAL COMMENTS" in a merged banner ABOVE the column row, so the column
 * row itself carries only the comments cell's first line of text. That text's
 * left edge IS the column's left edge, and it is the right-most thing on the
 * line — a position, not a guess.
 */
function synthesiseCommentsAnchor(
  line: TextLine,
  anchors: HeaderAnchor[],
): HeaderAnchor | null {
  const rightMost = anchors[anchors.length - 1].anchorX;
  const trailing = line.items
    .filter((i) => i.str.trim().length > 0 && i.x > rightMost + 20)
    .sort((a, b) => a.x - b.x);
  const first = trailing[0];
  if (!first) return null;
  if (HEADER_FRAGMENT.test(first.str.trim())) return null;
  return { anchorX: first.x, parts: ["CRITICAL COMMENTS"] };
}

/**
 * Whether `line` is the continuation of a heading already seeded from the
 * line above: it must contribute at least one fragment, and everything else
 * on it must belong to the comments column (whose cell text starts level
 * with the heading and simply keeps going).
 */
function isHeaderContinuation(
  line: TextLine,
  anchors: HeaderAnchor[],
  commentsX: number | null,
): boolean {
  let fragments = 0;
  for (const item of line.items) {
    const text = item.str.trim();
    if (!text) continue;
    if (HEADER_FRAGMENT.test(text)) {
      const nearest = anchors.reduce(
        (best, a) =>
          Math.abs(a.anchorX - item.x) < Math.abs(best.anchorX - item.x) ? a : best,
        anchors[0],
      );
      if (Math.abs(nearest.anchorX - item.x) <= HEADER_FRAGMENT_TOLERANCE) {
        fragments++;
        continue;
      }
      return false;
    }
    if (commentsX !== null && item.x >= commentsX - 4) continue;
    return false;
  }
  return fragments > 0;
}

/** Attach one continuation line's fragments to their headings. */
function absorbHeaderContinuation(line: TextLine, anchors: HeaderAnchor[]): void {
  for (const item of line.items) {
    const text = item.str.trim();
    if (!text || !HEADER_FRAGMENT.test(text)) continue;
    const nearest = anchors.reduce(
      (best, a) =>
        Math.abs(a.anchorX - item.x) < Math.abs(best.anchorX - item.x) ? a : best,
      anchors[0],
    );
    if (Math.abs(nearest.anchorX - item.x) <= HEADER_FRAGMENT_TOLERANCE) {
      nearest.parts.push(text);
    }
  }
}

/**
 * Turn assembled anchors into a column map, or null when this is not a table
 * header. A header needs a target column and at least one rate column —
 * without both there is no rate to bind and nothing may be served.
 */
function finaliseHeader(anchors: HeaderAnchor[]): HeaderColumn[] | null {
  const columns = anchors.map((a) => ({
    kind: classifyHeader(a.parts.join(" ")),
    anchorX: a.anchorX,
  }));
  const hasTarget = columns.some((c) => c.kind === "target");
  const hasRate = columns.some(
    (c) => c.kind === "rate" || c.kind === "rate_100l" || c.kind === "rate_ha",
  );
  if (!hasTarget || !hasRate) return null;
  columns.sort((a, b) => a.anchorX - b.anchorX);
  return columns;
}

/**
 * Column geometry for one table. Header anchors give the column ORDER, but
 * a header can be centred/indented inside its column (measured: Custodia
 * Forte's Table 1 prints CRITICAL COMMENTS 95pt right of the column's
 * content edge), so the first body line that fills EVERY column teaches the
 * true content left edges; every other line assigns each cell to the
 * nearest known edge.
 */
interface ColumnGeometry {
  columns: HeaderColumn[];
  learned: number[] | null;
  /** The basis this table's rate column states in its own heading. */
  rateBasis: RateBasisHint;
}

function assignCells(
  geometry: ColumnGeometry,
  cells: LineCell[],
): Map<ColumnKind, string[]> {
  const out = new Map<ColumnKind, string[]>();
  const push = (kind: ColumnKind, text: string): void => {
    if (kind === "ignored") return;
    const bucket = out.get(kind) ?? [];
    bucket.push(text);
    out.set(kind, bucket);
  };
  const anchors = geometry.columns.map((c) => c.anchorX);
  if (
    geometry.learned === null &&
    cells.length === geometry.columns.length &&
    cells.every((c, i) => i === 0 || c.x > cells[i - 1].x) &&
    Math.abs(cells[0].x - anchors[0]) <= 60
  ) {
    geometry.learned = cells.map((c) => c.x);
    cells.forEach((cell, i) => push(geometry.columns[i].kind, cell.text));
    return out;
  }
  const edges = geometry.learned ?? anchors;
  for (const cell of cells) {
    let best = 0;
    for (let i = 1; i < edges.length; i++) {
      if (Math.abs(cell.x - edges[i]) < Math.abs(cell.x - edges[best])) best = i;
    }
    push(geometry.columns[best].kind, cell.text);
  }
  return out;
}

/** Positioned text from one column of one printed line. */
interface PlacedCell {
  y: number;
  text: string;
}

function joinCells(cells: PlacedCell[]): string {
  return cells.map((c) => c.text).join(" ").replace(/\s+/g, " ").trim();
}

/** Vertical gap beyond which a trigger-column line starts a NEW row (the
 * measured intra-cell wrap pitch is 10–12pt; inter-row gaps are ≥50pt). */
const ROW_GAP = 18;

interface RowAccumulator {
  cropLines: PlacedCell[];
  targetLines: PlacedCell[];
  rate100Lines: PlacedCell[];
  rateHaLines: PlacedCell[];
  rateGenericLines: PlacedCell[];
  whpLines: PlacedCell[];
  commentLines: PlacedCell[];
  titleCrop: string | null;
  rateBasis: RateBasisHint;
  lastTriggerY: number;
  page: number;
}

/**
 * One crop block's target lines, split into the sub-rows the label printed.
 *
 * Inside a merged crop cell the label stacks several use rows: the wrap pitch
 * between the lines of ONE target cell is 10–12pt, while the gap to the next
 * sub-row is far larger. Splitting on that measured gap is what keeps a rate
 * with the target it was printed beside, instead of spreading it across every
 * target the crop happens to list.
 */
function splitTargetBands(targets: PlacedCell[]): PlacedCell[][] {
  if (targets.length <= 1) return targets.length ? [targets] : [];
  const ordered = [...targets].sort((a, b) => b.y - a.y);
  const bands: PlacedCell[][] = [[ordered[0]]];
  for (let i = 1; i < ordered.length; i++) {
    const gap = Math.abs(ordered[i - 1].y - ordered[i].y);
    if (gap > ROW_GAP) bands.push([ordered[i]]);
    else bands[bands.length - 1].push(ordered[i]);
  }
  return bands;
}

/**
 * Which sub-row a positioned cell belongs to: the band whose printed extent
 * contains it, with the boundary halfway between neighbouring bands. Cells
 * above the first band (a comment that starts higher than its row) belong to
 * the first band; cells below the last belong to the last.
 */
function bandIndexFor(bands: PlacedCell[][], y: number): number {
  for (let i = 0; i < bands.length - 1; i++) {
    const bottomOfThis = Math.min(...bands[i].map((c) => c.y));
    const topOfNext = Math.max(...bands[i + 1].map((c) => c.y));
    if (y > (bottomOfThis + topOfNext) / 2) return i;
  }
  return bands.length - 1;
}

// ---------------------------------------------------------------------------
// Why a blank rate cell is NEVER filled in from a neighbouring row
// ---------------------------------------------------------------------------
//
// It is tempting to treat an empty rate cell as a MERGED cell and inherit the
// rate printed above it. Many labels really are laid out that way: one crop,
// one rate, and a long list of weeds sharing it.
//
// A PDF text layer cannot support that inference. It reports where glyphs were
// drawn, not where table cells begin and end, so a rate spanning five rows and
// a rate belonging to one row with four blank rows beneath it are BYTE FOR
// BYTE the same input: one cell at one vertical position, nothing elsewhere.
//
// Dithane 59688 is the measured proof. Its TREE AND VINE table prints
// "150 to 200 g" against the Phomopsis row alone, and leaves the Blackspot and
// Downy mildew rate cells genuinely EMPTY — the label registers those uses
// with no rate in that column. Any inheritance rule strong enough to spread
// CHATEAU's shared rate across its weeds also spreads Phomopsis's rate onto
// two uses the label never gave a rate to, and publishes it as authoritative
// manufacturer_label evidence.
//
// So the rule stands: a rate is served where the label printed one, and a gap
// stays a gap. A missing rate is reported honestly and can be filled by a
// human against the label; an invented one is indistinguishable from evidence.
// Recovering genuinely merged cells needs the document's RULING LINES (or a
// layout pass that reads them), not a guess about vertical proximity.

function finishRow(acc: RowAccumulator | null, rows: DfuRow[]): void {
  if (!acc) return;
  const crop = joinCells(acc.cropLines) || (acc.titleCrop ?? "");
  const comments = joinCells(acc.commentLines);
  const targets = acc.targetLines.filter((t) => t.text.trim().length > 0);

  // The per-100-L column is the rate a vineyard operator dilutes to; a table
  // with only a generic RATE column keeps using it.
  const primary = acc.rate100Lines.length ? acc.rate100Lines : acc.rateGenericLines;
  const primaryBasis: RateBasisHint = acc.rate100Lines.length
    ? "per_100_litres"
    : acc.rateBasis;

  const bands = splitTargetBands(targets);
  if (bands.length <= 1) {
    const rate = joinCells(primary);
    const rateHa = joinCells(acc.rateHaLines);
    const whp = joinCells(acc.whpLines);
    if (!crop && !targets.length && !rate) return;
    rows.push({
      crop_text: crop,
      target_lines: targets.map((t) => t.text),
      rate_text: rate,
      rate_basis: primaryBasis,
      rate_ha_text: rateHa,
      whp_text: whp,
      comments_text: comments,
    });
    return;
  }

  // Several sub-rows share this crop cell. Rates and WHP go to the sub-row
  // whose printed band contains them — never to a neighbouring band, for the
  // reason set out above the band helpers; the critical comments describe the
  // crop block as a whole and stay with every sub-row (they are carried
  // verbatim, never parsed, so sharing them states nothing the label does not).
  const perBand = bands.map(() => ({
    rate: [] as PlacedCell[],
    rateHa: [] as PlacedCell[],
    whp: [] as PlacedCell[],
  }));
  for (const cell of primary) perBand[bandIndexFor(bands, cell.y)].rate.push(cell);
  for (const cell of acc.rateHaLines) perBand[bandIndexFor(bands, cell.y)].rateHa.push(cell);
  for (const cell of acc.whpLines) perBand[bandIndexFor(bands, cell.y)].whp.push(cell);

  bands.forEach((band, i) => {
    rows.push({
      crop_text: crop,
      target_lines: band.map((t) => t.text),
      rate_text: joinCells(perBand[i].rate),
      rate_basis: primaryBasis,
      rate_ha_text: joinCells(perBand[i].rateHa),
      whp_text: joinCells(perBand[i].whp),
      comments_text: comments,
    });
  });
}

export interface DfuParse {
  found: boolean;
  rows: DfuRow[];
}

/**
 * Parse the document's Directions-for-Use section into verbatim rows.
 * Deterministic and bounded: rows exist only where a recognised column
 * header established the table geometry; everything else is ignored.
 */
export function parseDirectionsForUse(items: PdfTextItem[]): DfuParse {
  const lines = assembleTextLines(items);
  const rows: DfuRow[] = [];
  let inSection = false;
  let geometry: ColumnGeometry | null = null;
  let titleCrop: string | null = null;
  let acc: RowAccumulator | null = null;
  const cropColumn = (): boolean =>
    Boolean(geometry?.columns.some((c) => c.kind === "crop"));

  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    if (!inSection) {
      if (DFU_HEADING.test(line.text)) inSection = true;
      continue;
    }
    if (DFU_FOOTER.test(line.text)) {
      finishRow(acc, rows);
      acc = null;
      break;
    }
    const title = TABLE_TITLE.exec(line.text);
    if (title) {
      finishRow(acc, rows);
      acc = null;
      geometry = null;
      titleCrop = title[1].trim();
      continue;
    }

    // ---- Header block: seed anchors, then absorb the wrapped heading ----
    const seeds = seedHeaderAnchors(line);
    if (seeds) {
      const commentsSeed = seeds.some((a) => /COMMENTS/i.test(a.parts[0]))
        ? null
        : synthesiseCommentsAnchor(line, seeds);
      const anchors = commentsSeed ? [...seeds, commentsSeed] : seeds;
      anchors.sort((a, b) => a.anchorX - b.anchorX);
      const commentsX = anchors.find((a) => /COMMENTS/i.test(a.parts[0]))?.anchorX ?? null;

      let consumed = index;
      while (consumed + 1 < lines.length) {
        const next = lines[consumed + 1];
        if (next.page !== line.page) break;
        if (!isHeaderContinuation(next, anchors, commentsX)) break;
        absorbHeaderContinuation(next, anchors);
        consumed++;
      }

      const header = finaliseHeader(anchors);
      if (header) {
        finishRow(acc, rows);
        acc = null;
        geometry = {
          columns: header,
          learned: null,
          rateBasis: header.some((c) => c.kind === "rate_100l")
            ? "per_100_litres"
            : header.some((c) => c.kind === "rate_ha")
            ? "per_hectare"
            : null,
        };
        index = consumed;
        continue;
      }
    }
    if (!geometry) continue;

    // Assign this line's cells to columns (measured-extent chaining).
    const byColumn = assignCells(geometry, segmentCells(line));
    const cellText = (kind: ColumnKind): string =>
      (byColumn.get(kind) ?? []).join(" ").replace(/\s+/g, " ").trim();

    // Row trigger: a CROP-column line in crop tables; a TARGET-column line
    // in title tables. A trigger within wrap pitch of the current row's
    // last trigger line is a continuation (wrapped cell), not a new row.
    const triggerKind: ColumnKind = cropColumn() ? "crop" : "target";
    const triggerText = cellText(triggerKind);
    if (triggerText) {
      const gap = acc && acc.page === line.page
        ? Math.abs(acc.lastTriggerY - line.y)
        : Number.POSITIVE_INFINITY;
      if (!acc || gap > ROW_GAP) {
        finishRow(acc, rows);
        acc = {
          cropLines: [],
          targetLines: [],
          rate100Lines: [],
          rateHaLines: [],
          rateGenericLines: [],
          whpLines: [],
          commentLines: [],
          titleCrop,
          rateBasis: geometry.rateBasis,
          lastTriggerY: line.y,
          page: line.page,
        };
      } else {
        acc.lastTriggerY = line.y;
        acc.page = line.page;
      }
    }
    if (!acc) continue;

    const place = (bucket: PlacedCell[], kind: ColumnKind): void => {
      const text = cellText(kind);
      if (text) bucket.push({ y: line.y, text });
    };
    place(acc.cropLines, "crop");
    place(acc.targetLines, "target");
    place(acc.rate100Lines, "rate_100l");
    place(acc.rateHaLines, "rate_ha");
    place(acc.rateGenericLines, "rate");
    place(acc.whpLines, "whp");
    place(acc.commentLines, "comments");
  }
  finishRow(acc, rows);
  return { found: inSection, rows };
}

// ---------------------------------------------------------------------------
// Fail-closed binding (document rows → register claims)
// ---------------------------------------------------------------------------

/**
 * One candidate wording for a row's target, and how much authority it carries.
 *
 * `complete` marks a wording the LABEL ITSELF delimited: the whole target
 * cell, or a segment the label separated with "/", "," or ";". Those may match
 * a register claim with prefix latitude, which is what makes the cell
 * "Botrytis" correspond to the register's "BOTRYTIS CINEREA".
 *
 * Everything else is a FRAGMENT — a run of printed lines carved out of a cell
 * by nothing more than where the column happened to wrap. A fragment must
 * name its target exactly.
 */
export interface TargetCandidate {
  text: string;
  complete: boolean;
}

/**
 * Candidate wordings for the row's targets.
 *
 * Line RUNS, not individual lines: a cell that prints "Botryosphaeria" above
 * "dieback" is one target split by the column width, and only the run of both
 * lines names it. Taking each line alone was how "Leaf spot", the tail of
 * "Phomopsis Cane and Leaf spot", came to look like a target in its own right.
 */
export function targetCandidates(row: DfuRow): TargetCandidate[] {
  const byText = new Map<string, boolean>();
  const push = (raw: string, complete: boolean): void => {
    const text = raw.replace(/\s+/g, " ").trim();
    if (!text) return;
    // A wording offered as complete stays complete even if a later, weaker
    // derivation produces the same string.
    byText.set(text, (byText.get(text) ?? false) || complete);
    const stripped = text.replace(/\([^)]*\)/g, " ").replace(/\s+/g, " ").trim();
    if (stripped && stripped !== text) {
      byText.set(stripped, (byText.get(stripped) ?? false) || complete);
    }
  };

  const lines = row.target_lines;
  const whole = lines.join(" ");

  // Label-delimited wordings: the whole cell and its separator segments.
  push(whole, true);
  for (const segment of whole.split(/[/,;]/)) push(segment, true);

  // Wrap-derived wordings: every run of consecutive printed lines.
  for (let i = 0; i < lines.length; i++) {
    for (let j = i; j < lines.length; j++) {
      const run = lines.slice(i, j + 1).join(" ");
      push(run, false);
      for (const segment of run.split(/[/,;]/)) push(segment, false);
    }
  }

  return Array.from(byText, ([text, complete]) => ({ text, complete }));
}

/**
 * Whether this row's targets name the register claim's target.
 *
 * The two tiers are the whole point: a label-delimited wording may correspond
 * by prefix, a wrap fragment must be exactly equivalent. Without that split,
 * one printed rate cell binds to two unrelated register claims.
 */
export function rowNamesTarget(
  candidates: TargetCandidate[],
  claimTargetRaw: string,
): boolean {
  return candidates.some((c) =>
    c.complete
      ? targetsCorrespond(c.text, claimTargetRaw)
      : targetsAreEquivalent(c.text, claimTargetRaw)
  );
}

export interface DfuBinding {
  /** Rates per claim index (only unambiguous bindings). */
  ratesByClaim: Map<number, WireLabelRate[]>;
  /** Verbatim critical comments per claim index (bound rows only). */
  commentsByClaim: Map<number, string[]>;
  /**
   * The complete target set of the PRINTED DIRECTION each claim bound to.
   *
   * Populated for every claim a row bound, so the claims that came from one
   * printed direction can be recognised as one direction downstream. Where a
   * claim bound rows from more than one printed direction the entry is
   * omitted — an ambiguous grouping is worse than none, and the row's own
   * targets remain a correct (if narrower) identity input.
   */
  /**
   * The withholding period the table's own WHP COLUMN printed for each claim.
   *
   * The column was already parsed and captured — it had to be, to keep a
   * withholding period from being swallowed into a rate cell — but nothing
   * ever read it, so a table that plainly printed "14 weeks" beside a
   * grapevine direction still served "withholding period: not stated".
   *
   * Carries the verbatim cell text beside the day count: the wording is what
   * the label says, the number is only a projection for scheduling.
   */
  whpByClaim: Map<number, { days: number; text: string }>;
  unbound: UnboundDfuRow[];
}

function toUnbound(row: DfuRow, reason: UnboundDfuRow["reason"]): UnboundDfuRow {
  const rateTexts = [row.rate_text, row.rate_ha_text].filter((t) => t.length > 0);
  const unbound: UnboundDfuRow = {
    crop_text: row.crop_text,
    target_texts: row.target_lines,
    rate_texts: rateTexts,
    comments_text: row.comments_text,
    reason,
  };
  if (row.whp_text) unbound.whp_text = row.whp_text;
  return unbound;
}

/**
 * Every rate this row states, read from its own columns.
 *
 * Each rate column is parsed SEPARATELY, with the basis its heading states.
 * Two columns are never concatenated: that is precisely how "30 days (H)"
 * ended up glued to "150 to 200 g" and served as authoritative evidence.
 */
function rowRates(row: DfuRow): WireLabelRate[] {
  return [
    ...parseRateCell(row.rate_text, row.rate_basis),
    ...parseRateCell(row.rate_ha_text, "per_hectare"),
  ];
}

/**
 * The longest CRITICAL COMMENTS cell that still reads as a rate condition.
 *
 * "Early season" qualifies a rate. Four sentences of spray-programme guidance
 * do not — promoting that to a rate's condition would make the rate list
 * unreadable and imply a precision the table does not have.
 */
const ROW_CONDITION_MAX_LENGTH = 80;

/**
 * Attach parsed DFU rows to register claims — THE fail-closed join.
 * A row binds only where `cropsCorrespond` AND at least one target
 * candidate corresponds. Rows that bind nowhere, and rows whose rates
 * disagree on the same basis for the same claim, serve NOTHING: they are
 * preserved verbatim in `unbound` and every affected gap stays listed.
 */
export function bindDfuRows(rows: DfuRow[], claims: LabelUseClaim[]): DfuBinding {
  interface Contribution {
    rowIndex: number;
    rates: WireLabelRate[];
    comments: string;
    /** The row's own WHP cell, verbatim. */
    whpText: string;
  }
  const contributions = new Map<number, Contribution[]>();
  const unbound: UnboundDfuRow[] = [];
  const conflictedRows = new Set<number>();

  rows.forEach((row, rowIndex) => {
    if (!row.crop_text) {
      unbound.push(toUnbound(row, "no_corresponding_claim"));
      return;
    }
    const candidates = targetCandidates(row);
    const matched: number[] = [];
    claims.forEach((claim, claimIndex) => {
      if (!cropsCorrespond(row.crop_text, claim.crop)) return;
      if (!rowNamesTarget(candidates, claim.target_raw)) return;
      matched.push(claimIndex);
    });
    if (!matched.length) {
      unbound.push(toUnbound(row, "no_corresponding_claim"));
      return;
    }
    // §10 — a rate cell holding a withholding period crossed a column
    // boundary. Serving it as manufacturer_label evidence would publish a
    // number the label never printed in that column, so the row serves
    // NOTHING and is preserved for review instead. A missing rate is a gap;
    // a corrupt rate is a lie.
    if (
      rateCellCrossesColumns(row.rate_text) ||
      rateCellCrossesColumns(row.rate_ha_text)
    ) {
      unbound.push(toUnbound(row, "column_geometry_uncertain"));
      return;
    }
    const rates = rowRates(row);
    for (const claimIndex of matched) {
      const list = contributions.get(claimIndex) ?? [];
      list.push({
        rowIndex,
        rates,
        comments: row.comments_text,
        whpText: row.whp_text,
      });
      contributions.set(claimIndex, list);
    }
  });

  // Several rows binding ONE claim is the normal shape of a conditional
  // label: an early-season row and a late-season row, or a dilute row and a
  // concentrate row, all registered against the same crop and target.
  //
  // This used to be treated as a conflict — the same basis with different
  // numbers from different rows made the claim serve NOTHING, and both rows
  // were filed as `conflicting_rates`. That is the cross-row form of the
  // collapse repaired in `parseRateCell`: it threw away two correct label
  // rates because it could not choose between them, when the label never
  // asked anyone to choose — it stated both, under different conditions.
  //
  // Every rate is now kept. The row's own CRITICAL COMMENTS cell is the
  // condition the label prints for that rate, so it becomes the rate's
  // condition where the rate does not already carry one from its own cell.
  // Where rows cannot be told apart that way, the rates are kept and flagged
  // `condition_ambiguous` — never discarded, never guessed.
  const ratesByClaim = new Map<number, WireLabelRate[]>();
  const commentsByClaim = new Map<number, string[]>();
  const whpByClaim = new Map<number, { days: number; text: string }>();
  for (const [claimIndex, list] of contributions) {
    const rates: WireLabelRate[] = [];
    const comments: string[] = [];
    for (const contribution of list) {
      for (const rate of contribution.rates) {
        // The rate cell's own qualifier wins; the row's comment is the
        // fallback condition. Only a SHORT comment reads as a qualifier — a
        // paragraph of critical comments is guidance, not a rate condition,
        // and it stays in the claim statements where it belongs.
        //
        // A `basis: "other"` rate is unparsed verbatim wording, NOT a
        // structured rate. Giving it a condition would dress a quote up as an
        // attributable rate and imply the grammar understood something it
        // explicitly did not.
        const condition = rate.basis === "other" ? rate.label : (rate.label ||
          (contribution.comments.length <= ROW_CONDITION_MAX_LENGTH
            ? contribution.comments
            : ""));
        const withCondition = condition && condition !== rate.label
          ? { ...rate, label: condition }
          : rate;
        const dup = rates.some(
          (r) =>
            sameRateReading(r, withCondition) &&
            r.label === withCondition.label &&
            r.raw_text === withCondition.raw_text,
        );
        if (!dup) rates.push(withCondition);
      }
      if (contribution.comments && !comments.includes(contribution.comments)) {
        comments.push(contribution.comments);
      }
    }
    if (rates.length) ratesByClaim.set(claimIndex, flagAmbiguousConditions(rates));
    if (comments.length) commentsByClaim.set(claimIndex, comments);

    // The table's WHP column, read only where every row backing this claim
    // agrees. Two printed rows stating DIFFERENT withholding periods for one
    // claim is a table this parser has no right to adjudicate, so it serves
    // nothing and the gap stays honestly reported.
    const readings = list
      .map((c) => ({ text: c.whpText, days: whpDaysFromCell(c.whpText) }))
      .filter((r): r is { text: string; days: number } => r.days !== null);
    if (readings.length) {
      const distinct = new Set(readings.map((r) => r.days));
      if (distinct.size === 1) {
        whpByClaim.set(claimIndex, { days: readings[0].days, text: readings[0].text });
      }
    }
  }
  for (const rowIndex of Array.from(conflictedRows).sort((a, b) => a - b)) {
    unbound.push(toUnbound(rows[rowIndex], "conflicting_rates"));
  }
  return { ratesByClaim, commentsByClaim, whpByClaim, unbound };
}

// ---------------------------------------------------------------------------
// Evidence application (rates + WHP/REI corroboration + gap accounting)
// ---------------------------------------------------------------------------

const DOCUMENT_SOURCE = "manufacturer_label (label document)";
const REGISTER_STATEMENTS_SOURCE = "manufacturer_label (register label statements)";

/**
 * Apply a successfully extracted label document to Stage 4 evidence.
 * Returns a NEW LabelEvidence — the input is never mutated, so any throw
 * leaves the register result byte-identical (the caller contains errors).
 *
 * Effects (all fail-closed):
 *   * unambiguously bound DFU rates land on their claims (verbatim
 *     `raw_text` on every entry); `rates:<crop>` clears ONLY where a
 *     structured (non-"other") rate was bound;
 *   * bound rows' critical comments append verbatim to claim statements;
 *   * document WHP/re-entry parsed with the Stage 4 strict patterns fill
 *     ONLY missing claim values (clearing their gaps); a disagreement with
 *     a register-stated value is recorded in `document_conflicts` and the
 *     register value stands;
 *   * unmatched/ambiguous rows land verbatim in `unbound_rows`.
 */
export function applyLabelDocumentExtraction(
  evidence: LabelEvidence,
  items: PdfTextItem[],
  doc: LabelDocumentDiscovery,
): LabelEvidence {
  if (!doc.document) return evidence;

  const lines = assembleTextLines(items);
  const statements = parseLabelStatements(lines.map((l) => l.text).join("\n"));
  const dfu = parseDirectionsForUse(items);
  const binding = bindDfuRows(dfu.rows, evidence.claims);
  // Stage LD-3 — wording only. Derived from the SAME parsed rows, and
  // deliberately AFTER the rate join so it cannot influence it.
  const wordings = deriveLabelTargetWordings(dfu.rows, evidence.claims);

  const unresolved = new Set<string>(evidence.unresolved);
  const documentConflicts: WireConflict[] = [];

  // Does this label scope its withholding periods per crop? APVMA labels that
  // list "Bananas: …", "Grapevines: …" have NO product-wide WHP: every entry
  // belongs to the crops it names. Reading an unscoped one as product-wide is
  // how a banana's "NOT REQUIRED" became the grapevine WHP of 0 days.
  const hasCropScopedWhp = statements.some(
    (s) => s.crop !== null && whpDaysFromStatement(s.statement, s.section) !== null,
  );

  // Document-side WHP/re-entry readings (strict Stage 4 patterns only).
  const cropWhp = (crop: string): { days: number; statement: string } | null => {
    for (const s of statements) {
      if (s.crop === null || !cropsCorrespond(crop, s.crop)) continue;
      const days = whpDaysFromStatement(s.statement, s.section);
      if (days !== null) return { days, statement: `${s.crop}: ${s.statement}` };
    }
    // The product-wide fallback exists for labels that state ONE withholding
    // period for the whole product. Where the label speaks per crop and this
    // crop was not among them, the honest answer is "not stated" — never
    // another crop's number.
    if (hasCropScopedWhp) return null;
    for (const s of statements) {
      if (s.crop !== null) continue;
      const days = whpDaysFromStatement(s.statement, s.section);
      if (days !== null) return { days, statement: s.statement };
    }
    return null;
  };
  const productReentry = (): { hours: number; statement: string } | null => {
    for (const s of statements) {
      if (!isReentryStatement(s.statement)) continue;
      const hours = reentryHoursFromStatement(s.statement);
      if (hours !== null) {
        return { hours, statement: s.crop ? `${s.crop}: ${s.statement}` : s.statement };
      }
    }
    return null;
  };
  const reentry = productReentry();

  const mapped: LabelUseClaim[] = evidence.claims.map((claim, index) => {
    const next: LabelUseClaim = { ...claim, statements: [...claim.statements] };

    // The label's own printed wording supersedes the register's pest
    // vocabulary as the authoritative target, and the register wording is
    // kept beside it, non-authoritative, for search.
    const printed = wordings.wordingByClaim.get(index);
    if (printed) {
      if (printed !== claim.target_raw) next.register_target_raw = claim.target_raw;
      next.target_raw = printed;
    }

    const rates = binding.ratesByClaim.get(index);
    if (rates?.length) next.rates = rates;
    for (const comment of binding.commentsByClaim.get(index) ?? []) {
      if (!next.statements.includes(comment)) next.statements.push(comment);
    }

    // The table's OWN withholding column for this claim, which is the most
    // specific statement a label can make: it is printed on the very row the
    // direction lives on. Consulted only where the crop-scoped statements did
    // not already answer, so a WITHHOLDING PERIODS block always outranks it.
    const tableWhp = binding.whpByClaim.get(index);
    const docWhp = cropWhp(claim.crop) ??
      (tableWhp ? { days: tableWhp.days, statement: tableWhp.text } : null);
    if (docWhp) {
      // Preserve the label's own words alongside the day-count projection.
      // "14 weeks" is what the registrant wrote; 98 is only what scheduling
      // needs. A client shows the wording and calculates with the number.
      if (next.withholding_statement === undefined) {
        next.withholding_statement = docWhp.statement;
      }
      if (next.withholding_period_days === undefined) {
        next.withholding_period_days = docWhp.days;
        if (!next.statements.includes(docWhp.statement)) {
          next.statements.push(docWhp.statement);
        }
        unresolved.delete(`withholding_period:${claim.crop}`);
      } else if (next.withholding_period_days !== docWhp.days) {
        const dup = documentConflicts.some(
          (c) =>
            c.field === "withholding_period_days" &&
            c.extracted_value.includes(claim.crop),
        );
        if (!dup) {
          documentConflicts.push({
            field: "withholding_period_days",
            extracted_value: `${docWhp.days} days (${claim.crop}) — ${docWhp.statement}`,
            authoritative_value: `${next.withholding_period_days} days — register label statements`,
            extracted_source: DOCUMENT_SOURCE,
            authoritative_source: REGISTER_STATEMENTS_SOURCE,
          });
        }
      }
    }

    if (reentry) {
      if (next.re_entry_period_hours === undefined) {
        next.re_entry_period_hours = reentry.hours;
        if (!next.statements.includes(reentry.statement)) {
          next.statements.push(reentry.statement);
        }
      } else if (next.re_entry_period_hours !== reentry.hours) {
        const dup = documentConflicts.some((c) => c.field === "re_entry_period_hours");
        if (!dup) {
          documentConflicts.push({
            field: "re_entry_period_hours",
            extracted_value: `${reentry.hours} hours — ${reentry.statement}`,
            authoritative_value: `${next.re_entry_period_hours} hours — register label statements`,
            extracted_source: DOCUMENT_SOURCE,
            authoritative_source: REGISTER_STATEMENTS_SOURCE,
          });
        }
      }
    }
    return next;
  });

  // One printed row, one registered use. Where the label's own target cell
  // already names another register pest code, that code is not served as a
  // separate use — its wording joins the printed use as a synonym, with its
  // statements preserved. A claim that BOUND A RATE is never absorbed: rate
  // ownership is decided by the join above and nothing here may disturb it.
  const absorbed = new Set<number>();
  for (const [absorbedIndex, ownerIndex] of wordings.absorbedInto) {
    if ((binding.ratesByClaim.get(absorbedIndex) ?? []).length) continue;
    const owner = mapped[ownerIndex];
    const source = mapped[absorbedIndex];
    if (!owner || !source || absorbed.has(ownerIndex)) continue;
    const synonyms = owner.target_synonyms ?? [];
    const registerWording = evidence.claims[absorbedIndex].target_raw;
    if (registerWording && !synonyms.includes(registerWording)) synonyms.push(registerWording);
    if (synonyms.length) owner.target_synonyms = synonyms;
    for (const statement of source.statements) {
      if (!owner.statements.includes(statement)) owner.statements.push(statement);
    }
    absorbed.add(absorbedIndex);
  }
  const claims: LabelUseClaim[] = mapped.filter((_, index) => !absorbed.has(index));

  // `rates:<crop>` clears ONLY where a structured rate was bound — a
  // verbatim-only ("other") reading keeps the structured gap honestly listed.
  for (const claim of claims) {
    const structured = (claim.rates ?? []).some((r) => r.basis !== "other");
    if (structured) unresolved.delete(`rates:${claim.crop}`);
  }
  if (
    claims.length && claims.every((c) => c.re_entry_period_hours !== undefined)
  ) {
    unresolved.delete("re_entry_period_hours");
  }

  return {
    ...evidence,
    claims,
    unresolved: Array.from(unresolved).sort(),
    document: {
      url: doc.url,
      sha256: doc.document.sha256,
      byte_size: doc.document.byte_size,
      retrieved_at: doc.retrieved_at,
      extraction: "pdf_text_layer",
      parser_version: LABEL_PARSER_VERSION,
    },
    unbound_rows: binding.unbound,
    document_conflicts: documentConflicts,
  };
}
