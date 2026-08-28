// Manufacturer-label Directions-for-Use extraction.
//
// # Why this is NOT `parseDirectionsForUse`
//
// `label_extract.ts` was built for APVMA eLabels: a single-column document
// whose DFU table owns the full page width. Its column geometry is
// reconstructed by chaining measured text extents, and its last column runs to
// the right page margin because on an eLabel nothing else is there.
//
// A registrant's own label is typeset for a printed bottle panel. The measured
// acceptance document (Vicchem VICOL WINTER OIL, APVMA 33182) puts the DFU
// table in the LEFT half of page 2 and an unrelated newsletter column —
// COMPATIBILITY, STORAGE AND DISPOSAL, SAFETY DIRECTIONS — in the right half,
// at the SAME y positions. Run through the eLabels parser it yields three
// rows in which:
//
//   * `crop_text` is "Pome FruitBryobia Mites, Stone FruitEuropean Red Mites"
//     — the crop and pest columns chained together, because the label sets
//     them 4pt apart;
//   * `comments_text` is the entire STORAGE AND DISPOSAL section from the
//     OTHER page column;
//   * the grapevine `rate_text` is
//     "2 L / 1OO L Apply as a post pruning application. Spray in mid winter to
//     ensure that vines are fully dormant. 3 L / 1OO L 2 L / 1OO L" — four
//     separate conditional rates and their critical comments concatenated into
//     one cell.
//
// That last string is precisely the defect this stage exists to remove, so the
// eLabels parser is left EXACTLY as it is (it is correct for the documents it
// was measured on, and four acceptance suites depend on it) and manufacturer
// labels get geometry rules of their own.
//
// # The three rules that make a printed panel readable
//
//   1. ANCHOR assignment, not extent chaining. Every column's x is taken from
//      its own heading and each text item is assigned to the nearest heading
//      at or left of it. Tight 4pt column gutters stop mattering, because the
//      heading positions — not the gaps between words — define the columns.
//
//   2. A right BOUNDARY. Text belonging to a different page column is
//      excluded by position. The boundary is derived from the document, never
//      assumed: see `deriveTableRightBoundary`.
//
//   3. A STATE column. Australian labels condition rates by state, and the
//      state IS the condition that distinguishes 2 L/100 L from 3 L/100 L.
//      Dropping it (as `classifyHeader` does — it returns "ignored") is what
//      would force four real rates to collapse into one ambiguous range.
//
// Identity is NEVER touched here. This module reads a document; it does not
// decide which product the document is about. That decision is made before a
// single byte is fetched, by the register.

import type { PdfTextItem, WireLabelRate } from "./contract.ts";
import {
  DIRECTION_SEED_KEY,
  isLockedProduct,
  mintDirectionId,
  mintRateIdForDirection,
  type RateIdentityProduct,
} from "../rate_identity.ts";
import { parseRateCell } from "./label_extract.ts";

/** Bumped whenever the geometry or binding rules below change. */
export const MANUFACTURER_LABEL_PARSER_VERSION = 1;

/** Columns this parser understands. Anything else is positional noise. */
export type ManufacturerColumnKind =
  | "crop"
  | "target"
  | "state"
  | "rate"
  | "comments";

interface ColumnAnchor {
  kind: ManufacturerColumnKind;
  x: number;
}

/** Heading wordings, as printed on registrant labels (Title Case is normal). */
const HEADING_PATTERNS: { kind: ManufacturerColumnKind; re: RegExp }[] = [
  { kind: "crop", re: /^(crops?|situations?)$/i },
  {
    kind: "target",
    re: /^(pests?|diseases?|weeds?|insects?|pests?\s*\/\s*diseases?|diseases?\s*\/\s*pests?)$/i,
  },
  { kind: "state", re: /^(states?|regions?)$/i },
  { kind: "rate", re: /^rates?\b.*$/i },
  {
    kind: "comments",
    re: /^(critical\s+comments?|critical\s+use\s+comments?|comments?)\b.*$/i,
  },
];

const DFU_HEADING = /DIRECTIONS\s+FOR\s+USE/i;
const DFU_FOOTER = /NOT\s+TO\s+BE\s+USED\s+FOR\s+ANY\s+PURPOSE/i;

/** Items within this many points of one baseline are one visual line. */
const LINE_TOLERANCE = 2.2;

/** How far left of a heading anchor an item may sit and still belong to it. */
const ANCHOR_TOLERANCE = 4;

/**
 * Minimum horizontal gap between the table's last column and a DIFFERENT page
 * column. Smaller separations are ordinary intra-table whitespace.
 */
const PAGE_COLUMN_GAP = 20;

/**
 * Digit glyphs a label's embedded font maps to letters.
 *
 * The measured document prints its rates as "2 L / 1OO L" — capital letter O,
 * not zero. This is not OCR error; it is what the PDF's own text layer
 * contains, and it is why every rate on this label parses as `basis:"other"`
 * with the verbatim cell as its text: `SINGLE_100L_RE` looks for `100`.
 *
 * The repair is deliberately narrow. Only a run that ALREADY STARTS WITH A
 * DIGIT has its O/o characters folded to zero, so "1OO" becomes "100" while
 * "SA", "Qld", "Oystershell" and "CO2" are untouched — no run that starts with
 * a letter is eligible.
 */
export function normaliseDigitGlyphs(text: string): string {
  return text.replace(/\b\d[\dOo]*\b/g, (run) => run.replace(/[Oo]/g, "0"));
}

/**
 * Does this document positively present a STATE-AWARE Directions-for-Use
 * table (Gate D4A.3)?
 *
 * # Why the answer must come from the document, not its URL
 *
 * The routing decision this answers must never be made from a host name. The
 * APVMA-hosted eLabel for 33182 is a full-width five-column table, the
 * registrant-hosted label for the same registration is a narrow printed bottle
 * panel, and NEITHER host predicts which geometry arrives — a regulator can
 * publish a re-typeset table and a registrant can publish a wide one.
 *
 * What actually matters is a single structural property: the table prints an
 * explicit STATE column. That column is the condition distinguishing 2 L/100 L
 * from 3 L/100 L, and `classifyHeader` in `label_extract.ts` deliberately
 * returns "ignored" for it — which is exactly how four printed directions
 * collapse into one cell. So a document is eligible for the state-aware parser
 * when, and only when, it prints the column that parser exists to read.
 *
 * Requires a real Directions-for-Use table: a rate anchor, a crop or target
 * anchor, a state anchor, AND the DFU heading. A marketing panel listing a
 * "Rate" beside a "Region" is not a DFU table and must not route here.
 */
export interface StateAwareDfuGeometry {
  present: boolean;
  /** The page the table was found on, for diagnostics. */
  page: number | null;
  /** Column kinds the heading row positively named, sorted by x. */
  columns: ManufacturerColumnKind[];
}

export function detectStateAwareDfu(items: PdfTextItem[]): StateAwareDfuGeometry {
  const byPage = new Map<number, PdfTextItem[]>();
  for (const item of items) {
    const list = byPage.get(item.page) ?? [];
    list.push(item);
    byPage.set(item.page, list);
  }
  for (const [page, pageItems] of [...byPage].sort((a, b) => a[0] - b[0])) {
    const lines = groupIntoLines(pageItems);
    const header = findHeaderLine(lines);
    if (!header) continue;
    if (!header.anchors.some((a) => a.kind === "state")) continue;
    const hasDfuHeading = lines.some(
      (l) => l.y >= header.y && DFU_HEADING.test(l.items.map((i) => i.str).join(" ")),
    );
    if (!hasDfuHeading) continue;
    return { present: true, page, columns: header.anchors.map((a) => a.kind) };
  }
  return { present: false, page: null, columns: [] };
}

/** One visual line of the table: its baseline and the items on it. */
interface VisualLine {
  y: number;
  items: PdfTextItem[];
}

function groupIntoLines(items: PdfTextItem[]): VisualLine[] {
  const sorted = [...items].sort((a, b) => b.y - a.y || a.x - b.x);
  const lines: VisualLine[] = [];
  for (const item of sorted) {
    const line = lines.find((l) => Math.abs(l.y - item.y) <= LINE_TOLERANCE);
    if (line) {
      line.items.push(item);
    } else {
      lines.push({ y: item.y, items: [item] });
    }
  }
  for (const line of lines) line.items.sort((a, b) => a.x - b.x);
  return lines;
}

/**
 * Locate the DFU column headings on a page.
 *
 * Requires a RATE column and at least one of crop/target: a stray line reading
 * "Comments" is not a table, and promoting it to one would invent geometry for
 * every paragraph beneath it.
 */
function findHeaderLine(
  lines: VisualLine[],
): { anchors: ColumnAnchor[]; y: number } | null {
  for (const line of lines) {
    const anchors: ColumnAnchor[] = [];
    for (const item of line.items) {
      const text = item.str.trim();
      if (!text) continue;
      const match = HEADING_PATTERNS.find((p) => p.re.test(text));
      if (match && !anchors.some((a) => a.kind === match.kind)) {
        anchors.push({ kind: match.kind, x: item.x });
      }
    }
    const hasRate = anchors.some((a) => a.kind === "rate");
    const hasSubject = anchors.some((a) => a.kind === "crop" || a.kind === "target");
    if (hasRate && hasSubject && anchors.length >= 3) {
      anchors.sort((a, b) => a.x - b.x);
      return { anchors, y: line.y };
    }
  }
  return null;
}

/**
 * Where the table stops and the rest of the page begins.
 *
 * # Why this is derived rather than configured
 *
 * A hard-coded "the table ends at x=230" would be a Vicchem patch. The rule
 * used instead is a property of page layout in general:
 *
 *   Text that was ALREADY FLOWING at an x to the right of the table, BEFORE
 *   the table's heading row began, belongs to a different page column.
 *
 * A genuine table column cannot start above its own heading. So the boundary
 * is the leftmost x among items that sit above the heading row (larger y, PDF
 * coordinates count upward) and clear of the last heading anchor. On the
 * measured document that is x=237 — the "Protection of Wildlife…" and
 * "COMPATIBILITY" column, which starts higher up the page than the DFU
 * heading — and it correctly excludes the entire STORAGE AND DISPOSAL block.
 *
 * When a page has no second column, nothing qualifies and the table keeps the
 * full width (`Infinity`), which is the eLabels case.
 */
export function deriveTableRightBoundary(
  items: PdfTextItem[],
  headerY: number,
  lastAnchorX: number,
): number {
  let boundary = Number.POSITIVE_INFINITY;
  for (const item of items) {
    if (!item.str.trim()) continue;
    if (item.y <= headerY) continue;
    if (item.x < lastAnchorX + PAGE_COLUMN_GAP) continue;
    if (item.x < boundary) boundary = item.x;
  }
  return boundary;
}

/** Assign an item to the nearest heading anchor at or to its left. */
function columnFor(
  anchors: ColumnAnchor[],
  x: number,
): ManufacturerColumnKind | null {
  let chosen: ColumnAnchor | null = null;
  for (const anchor of anchors) {
    if (x >= anchor.x - ANCHOR_TOLERANCE) chosen = anchor;
  }
  return chosen?.kind ?? null;
}

/** The text of one line, split into the columns it occupies. */
interface LineCells {
  y: number;
  crop: string;
  target: string;
  state: string;
  rate: string;
  comments: string;
}

function cellsForLine(line: VisualLine, anchors: ColumnAnchor[]): LineCells {
  const buckets: Record<ManufacturerColumnKind, string[]> = {
    crop: [],
    target: [],
    state: [],
    rate: [],
    comments: [],
  };
  for (const item of line.items) {
    const text = item.str.trim();
    if (!text) continue;
    const kind = columnFor(anchors, item.x);
    if (kind) buckets[kind].push(text);
  }
  const join = (parts: string[]): string => parts.join(" ").replace(/\s+/g, " ").trim();
  return {
    y: line.y,
    crop: join(buckets.crop),
    target: join(buckets.target),
    state: join(buckets.state),
    rate: join(buckets.rate),
    comments: join(buckets.comments),
  };
}

/**
 * One rate the label states, with the condition that governs it and the
 * targets it applies to. Verbatim throughout — nothing is converted.
 */
export interface ManufacturerLabelUse {
  crop: string;
  targets: string[];
  /** The label's own condition wording ("Tas", "NSW, Vic, SA"), or null. */
  condition: string | null;
  rates: WireLabelRate[];
  /** Critical comments for this crop block, verbatim. */
  restrictions: string | null;
}

export interface ManufacturerLabelParse {
  /** Whether a DIRECTIONS FOR USE table was located at all. */
  found: boolean;
  uses: ManufacturerLabelUse[];
  /** Derived table boundary, surfaced for diagnostics. */
  rightBoundary: number | null;
}

/** Split a joined target cell into the individual pests the label lists. */
function splitTargets(lines: string[]): string[] {
  const joined = lines.join(" ").replace(/\s+/g, " ").trim();
  if (!joined) return [];
  return joined
    .split(/\s*,\s*/)
    .map((t) => t.replace(/[,;]+$/, "").trim())
    .filter((t) => t.length > 0);
}

/** Join a state cell and its wrapped continuations into one condition. */
function joinCondition(parts: string[]): string | null {
  const joined = parts.join(" ")
    .replace(/\s+/g, " ")
    .replace(/\s*,\s*/g, ", ")
    .replace(/[,\s]+$/, "")
    .trim();
  return joined.length > 0 ? joined : null;
}

/**
 * Extract every rate the manufacturer's DFU table states.
 *
 * # The binding rule
 *
 * The table prints one rate per LINE, and a rate's targets may be printed on
 * the lines BELOW it (a wrapped target cell), while its condition may continue
 * on the lines below too. So:
 *
 *   * every line carrying a rate cell opens a rate record;
 *   * a rate line that also carries target text starts a NEW target group;
 *   * a rate line with no target text of its own INHERITS the target group
 *     above it — this is how "Grapevine Scale / Tas / 2 L per 100 L" keeps its
 *     pest when the label prints the pest only once and then varies the state;
 *   * state text on a line with NO rate continues the previous record's
 *     condition, which is how "NSW, Vic," + "Qld, SA, WA" becomes one
 *     five-state condition rather than two half-conditions.
 *
 * Nothing is merged across bases and no range is synthesised: 2 L/100 L and
 * 3 L/100 L stay two records, because the label prints two rates, not a range.
 */
export function extractManufacturerLabelUses(
  items: PdfTextItem[],
): ManufacturerLabelParse {
  const byPage = new Map<number, PdfTextItem[]>();
  for (const item of items) {
    const list = byPage.get(item.page) ?? [];
    list.push(item);
    byPage.set(item.page, list);
  }

  const uses: ManufacturerLabelUse[] = [];
  let found = false;
  let rightBoundary: number | null = null;

  for (const [, pageItems] of [...byPage].sort((a, b) => a[0] - b[0])) {
    const lines = groupIntoLines(pageItems);
    const header = findHeaderLine(lines);
    if (!header) continue;
    // The heading must actually be a Directions-for-Use table, not a
    // rate summary in a marketing panel.
    const hasDfuHeading = lines.some(
      (l) => l.y >= header.y && DFU_HEADING.test(l.items.map((i) => i.str).join(" ")),
    );
    if (!hasDfuHeading) continue;
    found = true;

    const lastAnchorX = header.anchors[header.anchors.length - 1].x;
    const boundary = deriveTableRightBoundary(pageItems, header.y, lastAnchorX);
    rightBoundary = Number.isFinite(boundary) ? boundary : null;
    const firstAnchorX = header.anchors[0].x;

    // Body lines: below the heading, inside the table's own column band.
    const body: LineCells[] = [];
    for (const line of lines) {
      if (line.y >= header.y) continue;
      const inBand = line.items.filter(
        (i) => i.x >= firstAnchorX - ANCHOR_TOLERANCE && i.x < boundary,
      );
      if (!inBand.length) continue;
      const text = inBand.map((i) => i.str).join(" ");
      if (DFU_FOOTER.test(text)) break;
      body.push(cellsForLine({ y: line.y, items: inBand }, header.anchors));
    }

    // ---- Crop blocks -----------------------------------------------------
    // A crop cell opens a block; every line until the next crop cell belongs
    // to it. Critical comments are collected per block, because that is the
    // scope at which the label writes them.
    interface Block {
      crop: string;
      lines: LineCells[];
    }
    const blocks: Block[] = [];
    for (const cells of body) {
      if (cells.crop) {
        blocks.push({ crop: cells.crop, lines: [cells] });
      } else if (blocks.length) {
        blocks[blocks.length - 1].lines.push(cells);
      }
    }

    const joinComments = (lines: LineCells[]): string =>
      lines
        .map((l) => l.comments)
        .filter((c) => c.length > 0)
        .join(" ")
        .replace(/\s+/g, " ")
        .trim();

    for (const block of blocks) {
      // The whole block's comments, which is the scope most labels write at.
      const blockRestrictions = joinComments(block.lines) || null;

      // Index the rate-bearing lines; everything binds relative to them.
      const rateLineIndexes = block.lines
        .map((l, i) => (l.rate ? i : -1))
        .filter((i) => i >= 0);

      // ---- Comment scope: block-level, unless the label PROVES otherwise ---
      //
      // Critical comments are collected per block because that is the scope
      // the label usually writes them at, and one comment governing four
      // directions is completely ordinary. But a block CAN hold materially
      // separate directions with separate comment scopes, and concatenating
      // those onto every direction is exactly the defect that made one
      // grapevine row read as another direction's restriction.
      //
      // So the scope is decided from POSITIVE typographic evidence rather
      // than assumed. Each rate line opens a span running to the next rate
      // line, mirroring the binding rule targets and conditions already use.
      // When TWO OR MORE spans carry comment text of their own, the label is
      // demonstrably writing comments per direction and each direction takes
      // its own span. When only one span (or none) does, the association is
      // unproven — a single comment might govern the block or just its first
      // direction — and the existing block-level behaviour stands unchanged.
      //
      // Never guessed: a comment is only ever narrowed when the document
      // itself distinguishes the scopes, and the ambiguous case fails to the
      // conservative reading rather than to a clean-looking one.
      const spanComments = rateLineIndexes.map((start, n) => {
        const end = n + 1 < rateLineIndexes.length ? rateLineIndexes[n + 1] : block.lines.length;
        return joinComments(block.lines.slice(start, end));
      });
      // Comment lines above the first rate line belong to no single direction.
      const prefixComments = rateLineIndexes.length > 0
        ? joinComments(block.lines.slice(0, rateLineIndexes[0]))
        : "";
      const spansWithComments = spanComments.filter((c) => c.length > 0).length;
      const commentsAreDirectionScoped = rateLineIndexes.length > 1 && spansWithComments > 1;

      let lastTargets: string[] = [];
      for (let n = 0; n < rateLineIndexes.length; n++) {
        const start = rateLineIndexes[n];
        const line = block.lines[start];

        // Targets: this rate line's own target text plus the wrapped target
        // lines beneath it, stopping at the next rate line that introduces a
        // target of its own.
        let targets: string[];
        if (line.target) {
          const targetLines = [line.target];
          for (let i = start + 1; i < block.lines.length; i++) {
            const next = block.lines[i];
            if (next.rate && next.target) break;
            if (next.target) targetLines.push(next.target);
            if (next.rate && !next.target) break;
          }
          targets = splitTargets(targetLines);
          lastTargets = targets;
        } else {
          // No target of its own: the label varied only the condition.
          targets = lastTargets;
        }

        // Condition: this line's state cell plus state-only continuations.
        const stateParts = line.state ? [line.state] : [];
        for (let i = start + 1; i < block.lines.length; i++) {
          const next = block.lines[i];
          if (next.rate) break;
          if (next.state) stateParts.push(next.state);
        }

        const textLayerRate = line.rate;
        const rawRate = normaliseDigitGlyphs(textLayerRate);
        const rates = parseRateCell(rawRate).map((r) => ({
          ...r,
          // The repaired, human-readable label wording — what the printed page
          // actually reads, and what a reviewer compares it against.
          raw_text: rawRate,
          // When a glyph WAS repaired, the unrepaired TEXT-LAYER extraction
          // travels beside it so the repair stays auditable (Gate D4A.3 §12K).
          // Absent when nothing was repaired, so no existing row changes shape.
          ...(textLayerRate !== rawRate ? { text_layer_text: textLayerRate } : {}),
        }));

        const restrictions = commentsAreDirectionScoped
          ? ([prefixComments, spanComments[n]]
            .filter((c) => c.length > 0)
            .join(" ")
            .replace(/\s+/g, " ")
            .trim() || null)
          : blockRestrictions;

        uses.push({
          crop: block.crop,
          targets,
          condition: joinCondition(stateParts),
          rates,
          restrictions,
        });
      }
    }
  }

  return { found, uses, rightBoundary };
}

// ---------------------------------------------------------------------------
// Projection into the served contract
// ---------------------------------------------------------------------------

/**
 * Map extracted label uses into the EXISTING registered-use contract rows.
 *
 * The state condition travels in TWO places, deliberately:
 *
 *   * `registered_use.condition` — the direction-level field, which is where
 *     the fact actually belongs. A condition governs a DIRECTION (its crop,
 *     targets, rates, restrictions and periods together), not an individual
 *     rate, so duplicating it onto every rate would teach clients a second
 *     shape for one fact and let the copies disagree.
 *   * `WireLabelRate.label` — kept populated exactly as before, because
 *     shipping iOS and Android builds read the condition from there today.
 *     Removing it the moment the direction-level field appeared would break
 *     every client that has not migrated yet, so both are written during the
 *     transition and clients move at their own pace.
 *
 * Both are additive and optional: historical rows omit `condition` entirely
 * and old clients ignore an unknown key.
 *
 * One row PER TARGET, matching the multi-target rule the research projection
 * already follows: the contract carries one target per row, so a direction
 * naming three mites becomes three rows sharing a crop, a condition and a
 * rate. Nothing is dropped and no "primary target" is invented.
 */
export function manufacturerUsesToRegisteredUses(
  uses: ManufacturerLabelUse[],
  opts: {
    withholdingPeriodDays?: number | null;
    reEntryPeriodHours?: number | null;
    /**
     * The LOCKED registered product, for identity minting.
     *
     * Optional, and identities are minted only when it is genuinely locked
     * (country + scheme + number). The extractor also runs in tests and
     * diagnostics with no resolved identity, and binding an id to an
     * unconfirmed product is worse than serving none (Gate D1.3 §2).
     */
    product?: RateIdentityProduct | null;
  } = {},
): Record<string, unknown>[] {
  const product = opts.product ?? null;
  // Product-bound identity, or none at all. An unlocked product still carries
  // its grouping forward through a seed, so the ids can be minted later once
  // the register confirms which product this label belongs to.
  const locked = isLockedProduct(product);

  const rows: Record<string, unknown>[] = [];
  for (const use of uses) {
    // Identity is minted HERE, while the direction still holds its COMPLETE
    // target set — before the fan-out below destroys it. Deriving it after the
    // fan-out, from each row's single surviving pest, would mint three
    // identities for one printed direction (Gate D1.2).
    const directionId = locked
      ? mintDirectionId(product, {
        crop: use.crop,
        targets: use.targets,
        condition: use.condition,
      })
      : null;

    const rates = use.rates.map((r) => ({
      ...r,
      // The condition the label prints for this rate. Without it, 2 L/100 L
      // and 3 L/100 L are two unexplained numbers and a client has no honest
      // way to show which applies.
      label: use.condition ?? r.label,
    }));
    const rateIds = directionId
      ? rates.map((r) => mintRateIdForDirection(product, directionId, r))
      : null;

    const targets = use.targets.length > 0 ? use.targets : [""];
    for (const target of targets) {
      rows.push({
        crop: use.crop,
        target,
        // Direction-level condition. Omitted entirely when the label states
        // none, so a row without a condition keeps its historical shape.
        ...(use.condition ? { condition: use.condition } : {}),
        // Every projected row of one printed direction carries that
        // direction's identity — or, until the product locks, the seed that
        // lets it be minted correctly later.
        ...(directionId
          ? { direction_id: directionId }
          : {
            [DIRECTION_SEED_KEY]: {
              crop: use.crop,
              targets: [...use.targets],
              condition: use.condition,
            },
          }),
        // Each row gets its OWN rate objects carrying the SAME ids. Sharing
        // one object across rows is what let a later in-place stamp overwrite
        // the identity of every sibling row — "last write wins" on a value
        // that must not depend on processing order at all.
        rates: rates.map((r, i) => (rateIds ? { ...r, rate_id: rateIds[i] } : { ...r })),
        withholding_period_days: opts.withholdingPeriodDays ?? null,
        re_entry_period_hours: opts.reEntryPeriodHours ?? null,
        restrictions: use.restrictions,
      });
    }
  }
  return rows;
}

/** Which source supplied the practical grapevine data actually served. */
export type PracticalSource =
  | "manufacturer_label"
  | "regulator_label"
  | "manufacturer_product_page"
  | "none";

export interface PracticalSelection {
  uses: Record<string, unknown>[];
  source: PracticalSource;
  reason: string;
}

/** Whether a set of contract use rows states any usable rate at all. */
function statesAnyRate(uses: Record<string, unknown>[]): boolean {
  return uses.some((u) => {
    const rates = Array.isArray(u.rates) ? u.rates : [];
    return rates.some((r: { basis?: string }) => r?.basis && r.basis !== "other");
  });
}

/**
 * Choose the practical use/rate set: manufacturer label first, regulator
 * label second (VineTrack product policy, task Phase 6).
 *
 * # Why this is not simply "prefer the manufacturer"
 *
 * A manufacturer document that yielded NO parsable rate must not displace a
 * regulator document that did. Priority expresses which source is more useful
 * when BOTH have something to say; it was never a licence to serve a worse
 * answer from a preferred source. So the manufacturer wins only when it
 * actually carries a rate, and the regulator's rows are kept whenever it does
 * not.
 *
 * Identity is untouched either way. This function chooses between two
 * readings of the SAME registered product; nothing here can change which
 * product that is.
 */
export function selectPracticalUses(input: {
  manufacturerUses: Record<string, unknown>[];
  regulatorUses: Record<string, unknown>[];
}): PracticalSelection {
  const manufacturerHasRates = statesAnyRate(input.manufacturerUses);
  const regulatorHasRates = statesAnyRate(input.regulatorUses);

  if (manufacturerHasRates) {
    return {
      uses: input.manufacturerUses,
      source: "manufacturer_label",
      reason:
        "the registrant's current approved label states rates; it is the label " +
        "the grower physically holds and is VineTrack's primary practical source",
    };
  }
  if (regulatorHasRates) {
    return {
      uses: input.regulatorUses,
      source: "regulator_label",
      reason:
        "the manufacturer label produced no parsable rate, so the regulator's " +
        "approved label carries the practical data rather than serving nothing",
    };
  }
  if (input.manufacturerUses.length > 0) {
    return {
      uses: input.manufacturerUses,
      source: "manufacturer_label",
      reason: "manufacturer label rows exist but state no parsable rate",
    };
  }
  if (input.regulatorUses.length > 0) {
    return {
      uses: input.regulatorUses,
      source: "regulator_label",
      reason: "only the regulator label produced use rows",
    };
  }
  return { uses: [], source: "none", reason: "no label produced use rows" };
}
