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
  targetsCorrespond,
  whpDaysFromStatement,
} from "./label.ts";

/** Bumped whenever the deterministic grammar changes (refresh comparability). */
export const LABEL_PARSER_VERSION = 1;

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
 * Parse one DFU rate cell into wire rates. Bounded grammar over measured
 * label forms ("Mix 30 mL of X per 100 litres of water", "35 or 54 mL/100 L",
 * "540 mL/ha", ranges with –/to/or). Every entry carries the verbatim cell
 * text. Unparseable wording → ONE `basis:"other"` verbatim entry. Two
 * DIFFERENT numbers on the SAME basis in one cell → the whole cell fails
 * closed to verbatim (a dilute/concentrate distinction the grammar cannot
 * prove is never guessed). An empty cell → no rates at all.
 */
export function parseRateCell(rawCell: string): WireLabelRate[] {
  const cell = rawCell.replace(/\s+/g, " ").trim();
  if (!cell) return [];
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
    return [{ label: "", basis: "other", unit: "", raw_text: cell }];
  }

  // Dedupe identical readings; fail the WHOLE cell closed when the same
  // basis carries different numbers (nothing in the grammar can prove which
  // applies where).
  const byBasis = new Map<string, WireLabelRate>();
  for (const { rate } of matches.sort((a, b) => a.start - b.start)) {
    const existing = byBasis.get(rate.basis);
    if (!existing) {
      byBasis.set(rate.basis, rate);
      continue;
    }
    const same = existing.value === rate.value &&
      existing.min_value === rate.min_value &&
      existing.max_value === rate.max_value &&
      existing.unit === rate.unit;
    if (!same) {
      return [{ label: "", basis: "other", unit: "", raw_text: cell }];
    }
  }
  return Array.from(byBasis.values());
}

// ---------------------------------------------------------------------------
// Directions-for-Use table parsing (measured layouts: single table WITH a
// CROP column — Sprayseal; per-crop "Table N. <Crop>" tables WITHOUT one —
// Custodia Forte. Columns are reconstructed from header anchor x-positions;
// wrapped cells are reassembled from the y-ordered lines of each column.)
// ---------------------------------------------------------------------------

export interface DfuRow {
  crop_text: string;
  /** The target cell's visual lines, verbatim (wrap-aware candidates). */
  target_lines: string[];
  rate_text: string;
  comments_text: string;
}

const DFU_HEADING = /DIRECTIONS\s+FOR\s+USE/i;
const DFU_FOOTER = /NOT\s+TO\s+BE\s+USED\s+FOR\s+ANY\s+PURPOSE/i;
const TABLE_TITLE = /^Table\s+\d+\s*[.:]?\s+(.+)$/i;

type ColumnKind = "crop" | "target" | "rate" | "comments" | "ignored";

const HEADER_TOKENS: ReadonlyArray<{ re: RegExp; kind: ColumnKind }> = [
  { re: /^(CROP|CROPS|SITUATION)$/i, kind: "crop" },
  {
    re: /^(DISEASE|DISEASES|PEST|PESTS|DISEASE\/PEST|DISEASES\/PESTS|WEED|WEEDS|INSECT|INSECTS)$/i,
    kind: "target",
  },
  { re: /^RATE(?:\/HA)?$/i, kind: "rate" },
  { re: /^(CRITICAL\s+COMMENTS|CRITICAL\s+USE\s+COMMENTS|COMMENTS)$/i, kind: "comments" },
  { re: /^(STATE|STATES|WHP)$/i, kind: "ignored" },
];

interface HeaderColumn {
  kind: ColumnKind;
  anchorX: number;
}

/** Header detection runs on RAW items — the header row's wide justification
 * spacers would otherwise chain its tokens into one cell. */
function detectHeader(line: TextLine): HeaderColumn[] | null {
  const anchors: HeaderColumn[] = [];
  for (const item of line.items) {
    const text = item.str.trim();
    if (!text) continue;
    const token = HEADER_TOKENS.find((t) => t.re.test(text));
    if (token) anchors.push({ kind: token.kind, anchorX: item.x });
  }
  const hasRate = anchors.some((a) => a.kind === "rate");
  const hasTarget = anchors.some((a) => a.kind === "target");
  if (!hasRate || !hasTarget) return null;
  anchors.sort((a, b) => a.anchorX - b.anchorX);
  return anchors;
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

/** Vertical gap beyond which a trigger-column line starts a NEW row (the
 * measured intra-cell wrap pitch is 10–12pt; inter-row gaps are ≥50pt). */
const ROW_GAP = 18;

interface RowAccumulator {
  cropLines: string[];
  targetLines: string[];
  rateLines: string[];
  commentLines: string[];
  titleCrop: string | null;
  lastTriggerY: number;
  page: number;
}

function finishRow(acc: RowAccumulator | null, rows: DfuRow[]): void {
  if (!acc) return;
  const crop = acc.cropLines.join(" ").replace(/\s+/g, " ").trim() ||
    (acc.titleCrop ?? "");
  const targets = acc.targetLines.map((t) => t.replace(/\s+/g, " ").trim()).filter(Boolean);
  const rate = acc.rateLines.join(" ").replace(/\s+/g, " ").trim();
  const comments = acc.commentLines.join(" ").replace(/\s+/g, " ").trim();
  if (!crop && !targets.length && !rate) return;
  rows.push({ crop_text: crop, target_lines: targets, rate_text: rate, comments_text: comments });
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

  for (const line of lines) {
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
    const header = detectHeader(line);
    if (header) {
      finishRow(acc, rows);
      acc = null;
      geometry = { columns: header, learned: null };
      continue;
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
          rateLines: [],
          commentLines: [],
          titleCrop,
          lastTriggerY: line.y,
          page: line.page,
        };
      } else {
        acc.lastTriggerY = line.y;
        acc.page = line.page;
      }
    }
    if (!acc) continue;

    const crop = cellText("crop");
    if (crop) acc.cropLines.push(crop);
    const target = cellText("target");
    if (target) acc.targetLines.push(target);
    const rate = cellText("rate");
    if (rate) acc.rateLines.push(rate);
    const comments = cellText("comments");
    if (comments) acc.commentLines.push(comments);
  }
  finishRow(acc, rows);
  return { found: inSection, rows };
}

// ---------------------------------------------------------------------------
// Fail-closed binding (document rows → register claims)
// ---------------------------------------------------------------------------

/** Candidate wordings for the row's targets: cell, lines, separator splits,
 * and parenthetical-stripped variants (Latin names in brackets). */
export function targetCandidates(row: DfuRow): string[] {
  const out = new Set<string>();
  const push = (raw: string): void => {
    const text = raw.replace(/\s+/g, " ").trim();
    if (text) {
      out.add(text);
      const stripped = text.replace(/\([^)]*\)/g, " ").replace(/\s+/g, " ").trim();
      if (stripped) out.add(stripped);
    }
  };
  const whole = row.target_lines.join(" ");
  push(whole);
  for (const line of row.target_lines) push(line);
  for (const source of [whole, ...row.target_lines]) {
    for (const segment of source.split(/[/,;]/)) push(segment);
  }
  return Array.from(out);
}

export interface DfuBinding {
  /** Rates per claim index (only unambiguous bindings). */
  ratesByClaim: Map<number, WireLabelRate[]>;
  /** Verbatim critical comments per claim index (bound rows only). */
  commentsByClaim: Map<number, string[]>;
  unbound: UnboundDfuRow[];
}

function toUnbound(row: DfuRow, reason: UnboundDfuRow["reason"]): UnboundDfuRow {
  return {
    crop_text: row.crop_text,
    target_texts: row.target_lines,
    rate_texts: row.rate_text ? [row.rate_text] : [],
    comments_text: row.comments_text,
    reason,
  };
}

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
      if (!candidates.some((c) => targetsCorrespond(c, claim.target_raw))) return;
      matched.push(claimIndex);
    });
    if (!matched.length) {
      unbound.push(toUnbound(row, "no_corresponding_claim"));
      return;
    }
    const rates = parseRateCell(row.rate_text);
    for (const claimIndex of matched) {
      const list = contributions.get(claimIndex) ?? [];
      list.push({ rowIndex, rates, comments: row.comments_text });
      contributions.set(claimIndex, list);
    }
  });

  // Cross-row ambiguity per claim: the same basis with different numbers
  // from different rows → the claim serves nothing from the document.
  const ratesByClaim = new Map<number, WireLabelRate[]>();
  const commentsByClaim = new Map<number, string[]>();
  for (const [claimIndex, list] of contributions) {
    const seen = new Map<string, WireLabelRate>();
    let conflicted = false;
    for (const contribution of list) {
      for (const rate of contribution.rates) {
        const existing = seen.get(rate.basis);
        if (!existing) {
          seen.set(rate.basis, rate);
          continue;
        }
        const same = existing.value === rate.value &&
          existing.min_value === rate.min_value &&
          existing.max_value === rate.max_value &&
          existing.unit === rate.unit;
        if (!same) conflicted = true;
      }
    }
    if (conflicted) {
      for (const contribution of list) conflictedRows.add(contribution.rowIndex);
      continue;
    }
    const rates: WireLabelRate[] = [];
    const comments: string[] = [];
    for (const contribution of list) {
      for (const rate of contribution.rates) {
        const dup = rates.some(
          (r) =>
            r.basis === rate.basis && r.value === rate.value &&
            r.min_value === rate.min_value && r.max_value === rate.max_value &&
            r.unit === rate.unit && r.raw_text === rate.raw_text,
        );
        if (!dup) rates.push(rate);
      }
      if (contribution.comments && !comments.includes(contribution.comments)) {
        comments.push(contribution.comments);
      }
    }
    if (rates.length) ratesByClaim.set(claimIndex, rates);
    if (comments.length) commentsByClaim.set(claimIndex, comments);
  }
  for (const rowIndex of Array.from(conflictedRows).sort((a, b) => a - b)) {
    unbound.push(toUnbound(rows[rowIndex], "conflicting_rates"));
  }
  return { ratesByClaim, commentsByClaim, unbound };
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

  const unresolved = new Set<string>(evidence.unresolved);
  const documentConflicts: WireConflict[] = [];

  // Document-side WHP/re-entry readings (strict Stage 4 patterns only).
  const cropWhp = (crop: string): { days: number; statement: string } | null => {
    for (const s of statements) {
      if (s.crop === null || !cropsCorrespond(crop, s.crop)) continue;
      const days = whpDaysFromStatement(s.statement, s.section);
      if (days !== null) return { days, statement: `${s.crop}: ${s.statement}` };
    }
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

  const claims: LabelUseClaim[] = evidence.claims.map((claim, index) => {
    const next: LabelUseClaim = { ...claim, statements: [...claim.statements] };

    const rates = binding.ratesByClaim.get(index);
    if (rates?.length) next.rates = rates;
    for (const comment of binding.commentsByClaim.get(index) ?? []) {
      if (!next.statements.includes(comment)) next.statements.push(comment);
    }

    const docWhp = cropWhp(claim.crop);
    if (docWhp) {
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
