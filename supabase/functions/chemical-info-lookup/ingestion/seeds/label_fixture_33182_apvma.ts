// Deterministic fixture: the text layer of the AUTHORITATIVE APVMA-hosted
// eLabel for APVMA 33182 (VICOL WINTER OIL INSECTICIDE), extracted by this
// project's own PDF text extractor (`extractPdfTextItems`, unpdf).
//
//   source:  https://elabels.apvma.gov.au/33182ELBL.pdf
//   sha256:  b55905a2612b0c938b44a656c6fa419715eb80468aabc842e667a4fa62c17111
//   pages:   4 (this fixture captures PAGE 3 — the DIRECTIONS FOR USE page)
//
// # Why this is a SECOND 33182 fixture
//
// `label_fixture_33182.ts` is the MANUFACTURER-hosted label (vicchem.com):
// page 2, a narrow printed bottle panel in the left half of the page with an
// unrelated newsletter column beside it. This document is a DIFFERENT
// typesetting of the same registered label — full page width, five well-spread
// columns, DFU on page 3 — and NOT ONE of that fixture's 144 measured items
// appears here. They are two documents, so they are two fixtures.
//
// # The production defect this fixture pins
//
// Two independent faults, both visible below:
//
//   1. The embedded font emits the rate as "1OO" (capital letter O, not zero):
//      see every `"L / 1OO"` item at x=383.26. `SINGLE_100L_RE` looks for a
//      literal "100", so every rate on this label fell through to
//      `basis: "other"`.
//
//   2. The table prints an explicit STATE column (heading "State" at x=297.17)
//      and `classifyHeader` in `label_extract.ts` returns "ignored" for it. The
//      state IS the condition separating 2 L/100 L from 3 L/100 L, so dropping
//      it collapsed the four printed grapevine directions into one cell:
//      "2 L / 1OO L 3 L / 1OO L 3 L / 1OO L 2 L / 1OO L".
//
// The raw "1OO" text is preserved EXACTLY as measured. Do not "clean" it to
// "100" — the uncleaned glyph is the entire point of the regression.
//
// Note also that the rate cell arrives as SEPARATE items ("2", " ", "L / 1OO",
// " ", "L"), which is why a cell must be reassembled positionally before any
// rate grammar is applied to it.

import type { PdfTextItem } from "../contract.ts";

/** Page 3 (DIRECTIONS FOR USE) of the authoritative APVMA eLabel, verbatim. */
export const VICOL_33182_APVMA_LABEL_ITEMS: PdfTextItem[] = [
  { page: 3, x: 72, y: 523.54, width: 21.64, str: "Crop" },
  { page: 3, x: 93.64, y: 523.54, width: 40.42, str: " " },
  { page: 3, x: 134.06, y: 523.54, width: 19.66, str: "Pest" },
  { page: 3, x: 153.72, y: 523.54, width: 143.45, str: " " },
  { page: 3, x: 297.17, y: 523.54, width: 23.89, str: "State" },
  { page: 3, x: 321.06, y: 523.54, width: 54.11, str: " " },
  { page: 3, x: 375.17, y: 523.54, width: 21.05, str: "Rate" },
  { page: 3, x: 396.22, y: 523.54, width: 42.67, str: " " },
  { page: 3, x: 438.89, y: 523.54, width: 83.43, str: "Critical Comments" },
  { page: 3, x: 72, y: 509.5, width: 0, str: "" },
  { page: 3, x: 72, y: 509.5, width: 49.17, str: "Pome Fruit" },
  { page: 3, x: 72, y: 496.18, width: 0, str: "" },
  { page: 3, x: 72, y: 496.18, width: 49.29, str: "Stone Fruit" },
  { page: 3, x: 134.06, y: 509.5, width: 0, str: "" },
  { page: 3, x: 134.06, y: 509.5, width: 130.09, str: "Bryobia Mites, European Red" },
  { page: 3, x: 134.06, y: 496.18, width: 25.56, str: "Mites" },
  { page: 3, x: 297.17, y: 509.5, width: 0, str: "" },
  { page: 3, x: 297.17, y: 509.5, width: 50.39, str: "Vic, SA, Tas" },
  { page: 3, x: 347.56, y: 509.5, width: 27.61, str: " " },
  { page: 3, x: 375.17, y: 509.5, width: 5.6, str: "2" },
  { page: 3, x: 380.77, y: 509.5, width: 2.5, str: " " },
  { page: 3, x: 383.26, y: 509.5, width: 33.99, str: "L / 1OO" },
  { page: 3, x: 417.25, y: 509.5, width: 2.5, str: " " },
  { page: 3, x: 419.75, y: 509.5, width: 4.64, str: "L" },
  { page: 3, x: 424.38, y: 509.5, width: 14.51, str: " " },
  { page: 3, x: 438.89, y: 509.5, width: 207.05, str: "Application in winter when trees are dormant." },
  { page: 3, x: 438.89, y: 496.12, width: 203.16, str: "Still sunny days represent the best conditions" },
  { page: 3, x: 438.89, y: 482.74, width: 56.11, str: "for spraying." },
  { page: 3, x: 438.89, y: 469.36, width: 126.67, str: "Do not spray after bud swell" },
  { page: 3, x: 565.54, y: 469.36, width: 2.78, str: "." },
  { page: 3, x: 297.17, y: 495.58, width: 0, str: "" },
  { page: 3, x: 297.17, y: 495.58, width: 42.99, str: "NSW, Qld" },
  { page: 3, x: 340.16, y: 495.58, width: 35.01, str: " " },
  { page: 3, x: 375.17, y: 495.58, width: 5.6, str: "3" },
  { page: 3, x: 380.77, y: 495.58, width: 2.5, str: " " },
  { page: 3, x: 383.26, y: 495.58, width: 33.99, str: "L / 1OO" },
  { page: 3, x: 417.25, y: 495.58, width: 2.5, str: " " },
  { page: 3, x: 419.75, y: 495.58, width: 4.64, str: "L" },
  { page: 3, x: 134.06, y: 481.66, width: 0, str: "" },
  { page: 3, x: 134.06, y: 481.66, width: 62.11, str: "Bryobia Mites" },
  { page: 3, x: 196.17, y: 481.66, width: 101, str: " " },
  { page: 3, x: 297.17, y: 481.66, width: 16.23, str: "WA" },
  { page: 3, x: 313.4, y: 481.66, width: 61.77, str: " " },
  { page: 3, x: 375.17, y: 481.66, width: 5.6, str: "2" },
  { page: 3, x: 380.77, y: 481.66, width: 2.5, str: " " },
  { page: 3, x: 383.26, y: 481.66, width: 33.99, str: "L / 1OO" },
  { page: 3, x: 417.25, y: 481.66, width: 2.5, str: " " },
  { page: 3, x: 419.75, y: 481.66, width: 4.64, str: "L" },
  { page: 3, x: 134.06, y: 467.74, width: 0, str: "" },
  { page: 3, x: 134.06, y: 467.74, width: 84.69, str: "Two Spotted Mites" },
  { page: 3, x: 218.75, y: 467.74, width: 78.42, str: " " },
  { page: 3, x: 297.17, y: 467.74, width: 51.63, str: "Vic, SA, WA" },
  { page: 3, x: 348.8, y: 467.74, width: 26.37, str: " " },
  { page: 3, x: 375.17, y: 467.74, width: 5.6, str: "2" },
  { page: 3, x: 380.77, y: 467.74, width: 2.5, str: " " },
  { page: 3, x: 383.26, y: 467.74, width: 33.99, str: "L / 1OO" },
  { page: 3, x: 417.25, y: 467.74, width: 2.5, str: " " },
  { page: 3, x: 419.75, y: 467.74, width: 4.64, str: "L" },
  { page: 3, x: 297.17, y: 453.82, width: 0, str: "" },
  { page: 3, x: 297.17, y: 453.82, width: 21.97, str: "NSW" },
  { page: 3, x: 319.14, y: 453.82, width: 56.03, str: " " },
  { page: 3, x: 375.17, y: 453.82, width: 5.6, str: "3" },
  { page: 3, x: 380.77, y: 453.82, width: 2.5, str: " " },
  { page: 3, x: 383.26, y: 453.82, width: 33.99, str: "L / 1OO" },
  { page: 3, x: 417.25, y: 453.82, width: 2.5, str: " " },
  { page: 3, x: 419.75, y: 453.82, width: 4.64, str: "L" },
  { page: 3, x: 134.06, y: 439.9, width: 0, str: "" },
  { page: 3, x: 134.06, y: 439.9, width: 63.24, str: "San Jose Scale" },
  { page: 3, x: 197.3, y: 439.9, width: 99.87, str: " " },
  { page: 3, x: 297.17, y: 439.9, width: 51.63, str: "Vic, SA, WA" },
  { page: 3, x: 348.8, y: 439.9, width: 26.37, str: " " },
  { page: 3, x: 375.17, y: 439.9, width: 5.6, str: "2" },
  { page: 3, x: 380.77, y: 439.9, width: 2.5, str: " " },
  { page: 3, x: 383.26, y: 439.9, width: 33.99, str: "L / 1OO" },
  { page: 3, x: 417.25, y: 439.9, width: 2.5, str: " " },
  { page: 3, x: 419.75, y: 439.9, width: 4.64, str: "L" },
  { page: 3, x: 297.17, y: 425.98, width: 0, str: "" },
  { page: 3, x: 297.17, y: 425.98, width: 42.99, str: "NSW, Qld" },
  { page: 3, x: 340.16, y: 425.98, width: 35.01, str: " " },
  { page: 3, x: 375.17, y: 425.98, width: 5.6, str: "3" },
  { page: 3, x: 380.77, y: 425.98, width: 2.5, str: " " },
  { page: 3, x: 383.26, y: 425.98, width: 33.99, str: "L / 1OO" },
  { page: 3, x: 417.25, y: 425.98, width: 2.5, str: " " },
  { page: 3, x: 419.75, y: 425.98, width: 4.64, str: "L" },
  { page: 3, x: 134.06, y: 412.06, width: 0, str: "" },
  { page: 3, x: 134.06, y: 412.06, width: 135.71, str: "Oystershell Scale, Prune Scale," },
  { page: 3, x: 134.06, y: 398.59, width: 45.83, str: "Pear Scale" },
  { page: 3, x: 297.17, y: 412.06, width: 0, str: "" },
  { page: 3, x: 297.17, y: 412.06, width: 14.98, str: "Tas" },
  { page: 3, x: 312.15, y: 412.06, width: 63.02, str: " " },
  { page: 3, x: 375.17, y: 412.06, width: 5.6, str: "2" },
  { page: 3, x: 380.77, y: 412.06, width: 2.5, str: " " },
  { page: 3, x: 383.26, y: 412.06, width: 33.99, str: "L / 1OO" },
  { page: 3, x: 417.25, y: 412.06, width: 2.5, str: " " },
  { page: 3, x: 419.75, y: 412.06, width: 4.64, str: "L" },
  { page: 3, x: 72, y: 384.67, width: 0, str: "" },
  { page: 3, x: 72, y: 384.67, width: 39.46, str: "Almonds" },
  { page: 3, x: 111.46, y: 384.67, width: 22.6, str: " " },
  { page: 3, x: 134.06, y: 384.67, width: 130.4, str: "Bryobia Mites, San Jose Scale" },
  { page: 3, x: 264.46, y: 384.67, width: 32.71, str: " " },
  { page: 3, x: 297.17, y: 384.67, width: 60.11, str: "SA, Vic, NSW," },
  { page: 3, x: 297.17, y: 371.23, width: 16.23, str: "WA" },
  { page: 3, x: 375.17, y: 384.67, width: 0, str: "" },
  { page: 3, x: 375.17, y: 384.67, width: 5.6, str: "2" },
  { page: 3, x: 380.77, y: 384.67, width: 2.5, str: " " },
  { page: 3, x: 383.26, y: 384.67, width: 33.99, str: "L / 1OO" },
  { page: 3, x: 417.25, y: 384.67, width: 2.5, str: " " },
  { page: 3, x: 419.75, y: 384.67, width: 4.64, str: "L" },
  { page: 3, x: 424.38, y: 384.67, width: 14.51, str: " " },
  { page: 3, x: 438.89, y: 384.67, width: 197.45, str: "Monitor for infestation while pruning. Apply" },
  { page: 3, x: 438.89, y: 371.23, width: 186.12, str: "on sunny still days during dormant period" },
  { page: 3, x: 438.89, y: 357.79, width: 195.47, str: "between first water after pruning up to bud" },
  { page: 3, x: 438.89, y: 344.35, width: 192.89, str: "swell. Apply in high volume until run-off to" },
  { page: 3, x: 438.89, y: 330.91, width: 75.41, str: "ensure complete" },
  { page: 3, x: 72, y: 316.99, width: 0, str: "" },
  { page: 3, x: 72, y: 316.99, width: 31.65, str: "Grapes" },
  { page: 3, x: 103.65, y: 316.99, width: 30.41, str: " " },
  { page: 3, x: 134.06, y: 316.99, width: 151.09, str: "Grapeleaf Blister Mites, European" },
  { page: 3, x: 134.06, y: 303.55, width: 135.04, str: "Red Mites, Two Spotted Mites" },
  { page: 3, x: 297.17, y: 316.99, width: 0, str: "" },
  { page: 3, x: 297.17, y: 316.99, width: 14.98, str: "Tas" },
  { page: 3, x: 312.15, y: 316.99, width: 63.02, str: " " },
  { page: 3, x: 375.17, y: 316.99, width: 5.6, str: "2" },
  { page: 3, x: 380.77, y: 316.99, width: 2.5, str: " " },
  { page: 3, x: 383.26, y: 316.99, width: 33.99, str: "L / 1OO" },
  { page: 3, x: 417.25, y: 316.99, width: 2.5, str: " " },
  { page: 3, x: 419.75, y: 316.99, width: 4.64, str: "L" },
  { page: 3, x: 424.38, y: 316.99, width: 14.51, str: " " },
  { page: 3, x: 438.89, y: 316.99, width: 159.99, str: "Apply as a post pruning application." },
  { page: 3, x: 438.89, y: 303.61, width: 195.99, str: "Spray in mid winter to ensure that vines are" },
  { page: 3, x: 438.89, y: 290.23, width: 60.83, str: "fully dormant" },
  { page: 3, x: 499.72, y: 290.23, width: 2.78, str: "." },
  { page: 3, x: 134.06, y: 289.63, width: 90.8, str: "European Red Mites" },
  { page: 3, x: 224.86, y: 289.63, width: 72.31, str: " " },
  { page: 3, x: 297.17, y: 289.63, width: 57.41, str: "NSW, Vic, SA" },
  { page: 3, x: 354.58, y: 289.63, width: 20.59, str: " " },
  { page: 3, x: 375.17, y: 289.63, width: 5.6, str: "3" },
  { page: 3, x: 380.77, y: 289.63, width: 2.5, str: " " },
  { page: 3, x: 383.26, y: 289.63, width: 33.99, str: "L / 1OO" },
  { page: 3, x: 417.25, y: 289.63, width: 2.5, str: " " },
  { page: 3, x: 419.75, y: 289.63, width: 4.64, str: "L" },
  { page: 3, x: 134.06, y: 275.71, width: 0, str: "" },
  { page: 3, x: 134.06, y: 275.71, width: 71.63, str: "Grapevine Scale" },
  { page: 3, x: 205.69, y: 275.71, width: 91.48, str: " " },
  { page: 3, x: 297.17, y: 275.71, width: 43.51, str: "NSW, Vic," },
  { page: 3, x: 297.17, y: 262.25, width: 15.77, str: "Qld" },
  { page: 3, x: 312.94, y: 262.25, width: 2.76, str: "," },
  { page: 3, x: 315.7, y: 262.25, width: 2.5, str: " " },
  { page: 3, x: 318.19, y: 262.25, width: 30.44, str: "SA,WA" },
  { page: 3, x: 375.17, y: 275.71, width: 0, str: "" },
  { page: 3, x: 375.17, y: 275.71, width: 5.6, str: "3" },
  { page: 3, x: 380.77, y: 275.71, width: 2.5, str: " " },
  { page: 3, x: 383.26, y: 275.71, width: 33.99, str: "L / 1OO" },
  { page: 3, x: 417.25, y: 275.71, width: 2.5, str: " " },
  { page: 3, x: 419.75, y: 275.71, width: 4.64, str: "L" },
  { page: 3, x: 297.17, y: 248.33, width: 0, str: "" },
  { page: 3, x: 297.17, y: 248.33, width: 14.98, str: "Tas" },
  { page: 3, x: 312.15, y: 248.33, width: 63.02, str: " " },
  { page: 3, x: 375.17, y: 248.33, width: 5.6, str: "2" },
  { page: 3, x: 380.77, y: 248.33, width: 2.5, str: " " },
  { page: 3, x: 383.26, y: 248.33, width: 33.99, str: "L / 1OO" },
  { page: 3, x: 417.25, y: 248.33, width: 2.5, str: " " },
  { page: 3, x: 419.75, y: 248.33, width: 4.64, str: "L" },
  { page: 3, x: 68.07, y: 538.82, width: 0, str: "" },
  { page: 3, x: 68.07, y: 538.82, width: 109.04, str: "DIRECTIONS FOR USE:" },
  { page: 3, x: 158.57, y: 215.93, width: 423.86, str: "NOT TO BE USED FOR ANY PURPOSE, OR IN ANY MANNER, CONTRARY TO THIS LABEL" },
  { page: 3, x: 227.53, y: 201.53, width: 285.92, str: "UNLESS AUTHORIZED UNDER APPROPRIATE LEGISLATION" },
];
