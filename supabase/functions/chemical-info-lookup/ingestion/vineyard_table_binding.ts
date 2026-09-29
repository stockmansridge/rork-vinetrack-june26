import type { PdfTextItem, WireLabelRate } from "./contract.ts";
import { parseRateCell } from "./label_extract.ts";
import { manufacturerUsesToRegisteredUses, type ManufacturerLabelUse } from "./manufacturer_label.ts";
import type { RateIdentityProduct } from "../rate_identity.ts";

const joined = (items: PdfTextItem[]): string => items.sort((a, b) => b.y - a.y || a.x - b.x)
  .map((item) => item.str.trim()).filter(Boolean).join(" ").replace(/\s+/g, " ").trim();
const within = (items: PdfTextItem[], page: number, left: number, right: number, top: number, bottom: number) =>
  items.filter((item) => item.page === page && item.x >= left && item.x < right && item.y <= top && item.y > bottom);

/** Fail-closed crop/table link: the crop cell, both references, and the vineyard-only caveat must all be on the same physical situation row. */
export function bindVineyardReferencedTables(items: PdfTextItem[], product: RateIdentityProduct | null,
  withholdingStatement: string | null): { uses: Record<string, unknown>[]; unresolved: string[] } {
  const crop = joined(within(items, 9, 9, 85, 281, 200));
  const references = joined(within(items, 9, 85, 183, 281, 200));
  const common = joined(within(items, 9, 183, 550, 281, 265.5));
  const vineyard = joined(within(items, 9, 183, 550, 266, 257.5));
  if (!/TREE AND VINE CROPS:/.test(crop) || !/\bVineyards\b/.test(crop) ||
    !/Table 2\. ANNUAL WEED CONTROL\./.test(references) ||
    !/Table 3\. PERENNIAL WEED CONTROL\./.test(references) ||
    !/directed or shielded spray, or using wiper equipment/i.test(common) ||
    !/Vineyards: DO NOT allow spray or spray drift to contact green bark or stems, canes, laterals, suckers, fresh wounds, foliage or fruit\./i.test(vineyard) ||
    within(items, 9, 165, 183, 281, 200).some((item) => /\d\s*(?:L|mL)\//.test(item.str)))
    return { uses: [], unresolved: ["vineyard_situation_or_table_reference_unconfirmed"] };
  const generalRestraints = joined(within(items, 2, 9, 550, 385, 350))
    .replace(/DO NOT use prior to sowing tomatoes\.?/i, "").trim();
  const restrictions = `${common} ${vineyard} ${generalRestraints}`.trim();
  const source = "PDF physical page 9 TREE AND VINE CROPS: Vineyards → ";
  const uses: Record<string, unknown>[] = [];
  const unresolved: string[] = [];
  const add = (target: string, page: number, table: string, methodRates: Array<[string, string]>, comments: string) => {
    const applicable = methodRates.flatMap(([method, raw]): WireLabelRate[] => {
      const parsed = parseRateCell(raw);
      // A printed mL/15L dose is label information, but basis "other" must
      // never be projected as a /100L calculation. Non-dose prose is unresolved.
      return parsed.length === 1 && (parsed[0].basis !== "other" || /^\d/.test(raw))
        ? [{ ...parsed[0], label: method }] : [];
    });
    if (!applicable.length) { unresolved.push(`${table}:${target}:rates_unresolved`); return; }
    const reference = `${source}${table}, physical page ${page}, ${target}`;
    const direction: ManufacturerLabelUse = { crop: "Vineyards", targets: [target], condition: `${table}; ${comments}`,
      rates: applicable, restrictions: `${restrictions} ${comments}`.trim() };
    for (const row of manufacturerUsesToRegisteredUses([direction], {
      product, withholdingPeriodDays: null, reEntryPeriodHours: null, preserveRateLabels: true,
    })) {
      row.source_refs = [reference];
      row.conditions = `${table}; ${comments}`;
      row.withholding_statement = withholdingStatement;
      row.rates = (row.rates as Array<Record<string, unknown>>).map((rate) => ({ ...rate, source_refs: [reference] }));
      uses.push(row);
    }
    for (const [method, raw] of methodRates) if (!applicable.some((rate) => rate.label === method))
      unresolved.push(`${table}:${target}:${method}:${raw}`);
  };
  const annualHeader = joined(within(items, 2, 0, 550, 310, 299));
  const situation = joined(within(items, 2, 9, 47, 295, 275));
  const annualRates = joined(within(items, 2, 240, 318, 295, 210));
  const annualComments = joined(within(items, 2, 318, 550, 295, 230));
  const boom = annualRates.match(/BOOM:\s*([\d.\s-]+L\/ha)\s*HANDGUN:/i)?.[1]?.trim();
  const handgun = annualRates.match(/HANDGUN:\s*([\d.\s-]+mL\/100L)\s*KNAPSACK:/i)?.[1]?.trim();
  const knapsack = annualRates.match(/KNAPSACK:\s*([\d.\s-]+mL\/15L)\s*WIPER/i)?.[1]?.trim();
  if (/ANNUAL WEED CONTROL/.test(annualHeader) && /Non- Cultivated Situations/.test(situation) && boom && handgun && knapsack &&
    /Use the lower rate on weeds up to 15 cm tall/i.test(annualComments)) {
    // The single rate cell spans this non-cultivated weed group on the printed page.
    // Do not copy adjacent general-control or cultivated-situation rates.
    const targets = within(items, 2, 47, 128, 295, 15).filter((item) => Math.abs(item.x - 47.58) < 1 && item.str.trim());
    for (const target of targets) add(target.str.trim(), 2, "Table 2 ANNUAL WEED CONTROL / Non-Cultivated Situations",
      [["Boom", boom], ["Handgun", handgun], ["Knapsack", knapsack]], annualComments);
    unresolved.push("Table 2 wiper and controlled-droplet rates: See Application section; no standalone calculable product dose");
  } else unresolved.push("Table 2 shared non-cultivated rate cell unconfirmed");

  // Table 3 contains mixed aquatic, tank-mix and continuation rows. Only a
  // standalone row whose three method cells and comments can be bounded by its
  // own target and the next target is eligible; the remainder stay unresolved.
  const table3 = joined(within(items, 3, 0, 550, 391, 380));
  if (/PERENNIAL WEED CONTROL/.test(table3)) {
    const target = within(items, 3, 9, 85, 340, 335).find((item) => /^(?:Bent grass)$/.test(item.str.trim()));
    const boomCell = joined(within(items, 3, 85, 130, 340, 335));
    const handgunCell = joined(within(items, 3, 130, 168, 340, 335));
    const knapsackCell = joined(within(items, 3, 168, 213, 340, 335));
    const comments = joined(within(items, 3, 213, 550, 340, 315));
    if (target && /\b2\.5 L\/ha\b/.test(boomCell) && /500 mL\/100L/.test(handgunCell) &&
      /75 mL\/15L/.test(knapsackCell) && /Bent grass should NOT be heavily grazed/.test(comments))
      add(target.str.trim(), 3, "Table 3 PERENNIAL WEED CONTROL", [["Boom", boomCell], ["Handgun", handgunCell],
        ["Knapsack", knapsackCell]], comments);
    else unresolved.push("Table 3 standalone Bent grass row could not be bounded");
  } else unresolved.push("Table 3 heading unconfirmed");
  unresolved.push("Remaining Table 3 perennial rows require individual shared-cell, aquatic and method exception review");
  return { uses, unresolved };
}
