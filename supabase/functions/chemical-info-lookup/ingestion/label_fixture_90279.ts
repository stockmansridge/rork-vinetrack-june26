import type { PdfTextItem } from "./contract.ts";

function item(page: number, x: number, y: number, str: string): PdfTextItem {
  return { page, x, y, width: Math.max(1, str.length * 5), str };
}

/**
 * Compact layout fixture reproducing the APVMA 90279 tree-and-vine table.
 * The header typography and grapevine cells mirror the production eLabel:
 * Rate/ + 100 L and WITHHOLDING + PERIOD are vertically wrapped columns.
 */
export const GREENSHIELD_90279_ITEMS: PdfTextItem[] = [
  item(1, 70, 790, "CROPSURE GREENSHIELD 750 WG FUNGICIDE"),
  item(1, 70, 775, "APVMA Approval No: 90279"),
  item(2, 70, 700, "WITHHOLDING PERIODS (WHP)"),
  item(2, 70, 680, "GRAPEVINES: DO NOT HARVEST FOR 30 DAYS AFTER APPLICATION."),
  item(2, 70, 660, "DO NOT allow entry into treated areas until spray has dried."),
  item(10, 70, 790, "DIRECTIONS FOR USE"),
  item(10, 70, 770, "TREE AND VINE CROPS"),
  item(10, 70, 750, "In the following table all rates are given for dilute spraying."),
  item(10, 70, 730, "Crop"),
  item(10, 138, 730, "Disease"),
  item(10, 225, 730, "Rate/"),
  item(10, 273, 730, "WITHHOLDING"),
  item(10, 360, 730, "Critical Comments"),
  item(10, 225, 718, "100 L"),
  item(10, 273, 718, "PERIOD"),
  item(10, 70, 500, "Grapevines"),
  item(10, 138, 500, "Black spot"),
  item(10, 225, 500, "200 g"),
  item(10, 273, 500, "30 days"),
  item(10, 360, 500, "For black spot control spray commencing at bud burst."),
  item(10, 138, 488, "Downy mildew"),
  item(10, 360, 488, "Continue the program at intervals of 10 to 14 days."),
  item(10, 138, 440, "Phomopsis"),
  item(10, 225, 440, "150 to 200 g"),
  item(10, 138, 428, "Cane and Leaf spot"),
  item(10, 360, 440, "Spray at bud burst and repeat 7 to 10 days later."),
  item(10, 70, 400, "NOT TO BE USED FOR ANY PURPOSE"),
];
