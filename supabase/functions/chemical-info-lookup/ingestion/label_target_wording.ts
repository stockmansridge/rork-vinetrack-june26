// Stage LD-3 — authoritative TARGET WORDING from the label document.
//
// THE DEFECT THIS CLOSES
//   The register names pests from its own vocabulary (PubCRIS pest.csv), and
//   that vocabulary carries a scientific taxonomy the approved label never
//   printed. The grapevine row of APVMA 59688 reads "Blackspot"; the register
//   calls the same claim "BLACK SPOT - COLLETOTRICHUM ACUTATUM". The register
//   splits the one printed row "Phomopsis Cane and Leaf spot" into two pest
//   codes, the second of which it words "LEAF SPOT - ALTERNARIA CERCOSPORA".
//   Serving those as the registered uses made VineTrack state, inside the
//   operator's own Chemical Store, that an approved label said something it
//   does not say.
//
//   So where the label DOCUMENT prints its own wording for a claim, that
//   wording IS the registered use's target. The register wording is kept
//   beside it as a non-authoritative synonym: never discarded, never
//   displayed as label text.
//
// WHAT THIS MODULE WILL NEVER DO
//   * Touch rate ownership. `bindDfuRows` is untouched — which use owns which
//     printed rate cell is still decided by the fail-closed two-tier join,
//     and a wording match here can never move, mint or inherit a rate.
//   * Cross a crop. Every comparison is scoped by `cropsCorrespond`, so one
//     crop's disease wording can never re-word another crop's use.
//   * Invent a wording. Every string served is a verbatim run of printed
//     lines from the document's own target cell.

import type { LabelUseClaim } from "./contract.ts";
import type { DfuRow } from "./label_extract.ts";
import { cropsCorrespond, targetsCorrespond } from "./label.ts";

/** Conjunctions that join two printed lines into ONE target wording. */
const TARGET_CONJUNCTION_TAIL = /\b(?:and|or|&|plus)\s*$/i;
const TARGET_CONJUNCTION_HEAD = /^\s*(?:and|or|&|plus)\b/i;

/**
 * The register's common-name head: the part before its taxonomy separator.
 * "BLACK SPOT - COLLETOTRICHUM ACUTATUM" → "BLACK SPOT".
 *
 * Deterministic string work on the register's own "<common> - <scientific>"
 * convention. No vocabulary, no inference, no AI.
 */
export function registerTargetHead(targetRaw: string): string {
  const head = String(targetRaw).split(/\s+[-–—]\s+/)[0]?.trim() ?? "";
  return head || String(targetRaw).trim();
}

/** Letters and digits only — "Blackspot" and "BLACK SPOT" are one word split. */
function squashed(text: string): string {
  return text.toUpperCase().replace(/[^A-Z0-9]+/g, "");
}

/**
 * Whether a printed line RUN names this claim closely enough to mark where in
 * the target cell the claim's wording begins.
 *
 * Spacing-insensitive equality against the register's common-name head, so
 * the label's "Blackspot" anchors the register's "BLACK SPOT - COLLETOTRICHUM
 * ACUTATUM". This latitude exists ONLY for wording, and is deliberately
 * absent from the rate join, where a tail fragment matching a longer register
 * target is exactly the defect §12.5 pins shut.
 */
function runAnchorsClaim(runText: string, claimTargetRaw: string): boolean {
  const run = squashed(runText);
  if (!run) return false;
  return run === squashed(registerTargetHead(claimTargetRaw));
}

interface TargetAnchor {
  claimIndex: number;
  start: number;
  end: number;
}

interface WordingSpan {
  claimIndex: number;
  crop: string;
  lines: string[];
}

export interface LabelTargetWordings {
  /** Claim index → the label document's own printed wording for that claim. */
  wordingByClaim: Map<number, string>;
  /**
   * Claim index → the claim index whose ONE printed target cell already names
   * it. The label printed one row, so VineTrack serves one registered use.
   */
  absorbedInto: Map<number, number>;
}

/** Whether any run of a span's printed lines names this register target. */
function spanNamesTarget(lines: string[], claimTargetRaw: string): boolean {
  for (let i = 0; i < lines.length; i++) {
    for (let j = i; j < lines.length; j++) {
      const run = lines.slice(i, j + 1).join(" ");
      if (runAnchorsClaim(run, claimTargetRaw)) return true;
      if (targetsCorrespond(run, claimTargetRaw)) return true;
    }
  }
  return false;
}

/**
 * Which printed wording belongs to which register claim.
 *
 * Per row: find each claim's ANCHOR (the run of printed lines that names it),
 * then give each anchor the slice of the cell running up to the next anchor.
 * A cell printing "Blackspot / Downy / mildew" splits into "Blackspot" and
 * "Downy mildew"; a cell printing "Phomopsis / Cane and / Leaf spot" does not
 * split at all, because "Leaf spot" is conjoined to the wording before it.
 */
export function deriveLabelTargetWordings(
  rows: DfuRow[],
  claims: LabelUseClaim[],
): LabelTargetWordings {
  const candidates = new Map<number, string[]>();
  const spans: WordingSpan[] = [];

  for (const row of rows) {
    if (!row.crop_text) continue;
    const lines = row.target_lines
      .map((line) => line.replace(/\s+/g, " ").trim())
      .filter((line) => line.length > 0);
    if (!lines.length) continue;

    const wholeCell = lines.join(" ");
    const anchors: TargetAnchor[] = [];

    claims.forEach((claim, claimIndex) => {
      if (!cropsCorrespond(row.crop_text, claim.crop)) return;

      // The whole cell is a wording the LABEL itself delimited, so it may name
      // the claim with the same prefix latitude the rate join allows it.
      if (targetsCorrespond(wholeCell, claim.target_raw)) {
        anchors.push({ claimIndex, start: 0, end: lines.length - 1 });
        return;
      }

      // Otherwise the claim must be named by a run of printed lines that is
      // not conjoined to the text before it — "Leaf spot" following "Cane
      // and" is the tail of one wording, not a target in its own right.
      let best: TargetAnchor | null = null;
      for (let i = 0; i < lines.length; i++) {
        if (TARGET_CONJUNCTION_TAIL.test(lines.slice(0, i).join(" "))) continue;
        if (TARGET_CONJUNCTION_HEAD.test(lines[i])) continue;
        for (let j = i; j < lines.length; j++) {
          if (!runAnchorsClaim(lines.slice(i, j + 1).join(" "), claim.target_raw)) continue;
          if (!best || j - i < best.end - best.start) {
            best = { claimIndex, start: i, end: j };
          }
        }
      }
      if (best) anchors.push(best);
    });

    if (!anchors.length) continue;
    anchors.sort((a, b) => a.start - b.start || a.end - b.end);

    anchors.forEach((anchor, i) => {
      const start = i === 0 ? 0 : anchor.start;
      const end = i === anchors.length - 1 ? lines.length - 1 : anchors[i + 1].start - 1;
      // Two claims anchored on the same line: the cell cannot be divided
      // between them, so neither takes a printed wording (fail closed).
      if (start > end) return;
      const slice = lines.slice(start, end + 1);
      const text = slice.join(" ").trim();
      if (!text) return;
      const list = candidates.get(anchor.claimIndex) ?? [];
      list.push(text);
      candidates.set(anchor.claimIndex, list);
      spans.push({ claimIndex: anchor.claimIndex, crop: claims[anchor.claimIndex].crop, lines: slice });
    });
  }

  // One claim, one printed wording. Two rows wording the same claim
  // differently is an ambiguity this parser refuses to resolve.
  const wordingByClaim = new Map<number, string>();
  for (const [claimIndex, texts] of candidates) {
    const distinct = Array.from(new Set(texts.map((t) => squashed(t))));
    if (distinct.length === 1) wordingByClaim.set(claimIndex, texts[0]);
  }

  // A register pest code that the printed cell of ANOTHER claim already names
  // is not a second registered use: the label printed one row for both.
  const absorbedInto = new Map<number, number>();
  claims.forEach((claim, claimIndex) => {
    if (wordingByClaim.has(claimIndex)) return;
    const owners: number[] = [];
    for (const span of spans) {
      if (span.claimIndex === claimIndex) continue;
      if (!wordingByClaim.has(span.claimIndex)) continue;
      if (!cropsCorrespond(span.crop, claim.crop)) continue;
      if (!spanNamesTarget(span.lines, claim.target_raw)) continue;
      if (!owners.includes(span.claimIndex)) owners.push(span.claimIndex);
    }
    if (owners.length === 1) absorbedInto.set(claimIndex, owners[0]);
  });

  return { wordingByClaim, absorbedInto };
}
