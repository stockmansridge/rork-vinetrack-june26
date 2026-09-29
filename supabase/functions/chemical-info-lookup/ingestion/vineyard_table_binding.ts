import type { PdfTextItem, WireLabelRate } from "./contract.ts";
import { parseRateCell } from "./label_extract.ts";
import { manufacturerUsesToRegisteredUses, type ManufacturerLabelUse } from "./manufacturer_label.ts";
import type { RateIdentityProduct } from "../rate_identity.ts";

const joined = (items: PdfTextItem[]): string => [...items].sort((a, b) => b.y - a.y || a.x - b.x)
  .map((item) => item.str.trim()).filter(Boolean).join(" ").replace(/\s+/g, " ").trim();
const within = (items: PdfTextItem[], page: number, left: number, right: number, top: number, bottom: number): PdfTextItem[] =>
  items.filter((item) => item.page === page && item.x >= left && item.x < right && item.y <= top && item.y > bottom);

export interface VineyardBindingDecision {
  page: number;
  target: string;
  state: "mapped" | "excluded" | "unresolved";
  reason: string;
}

/** Bind only the physically referenced weed tables to the Vineyard situation, retaining an audit of every perennial row. */
export function bindVineyardReferencedTables(items: PdfTextItem[], product: RateIdentityProduct | null,
  withholdingStatement: string | null): { uses: Record<string, unknown>[]; unresolved: string[]; reconciliation: VineyardBindingDecision[] } {
  const crop = joined(within(items, 9, 9, 85, 281, 200));
  const references = joined(within(items, 9, 85, 183, 281, 200));
  const common = joined(within(items, 9, 183, 550, 281, 265.5));
  const vineyard = joined(within(items, 9, 183, 550, 266, 257.5));
  const empty = (reason: string) => ({ uses: [], unresolved: [reason], reconciliation: [] as VineyardBindingDecision[] });
  if (!/TREE AND VINE CROPS:/.test(crop) || !/\bVineyards\b/.test(crop) ||
    !/Table 2\. ANNUAL WEED CONTROL\./.test(references) ||
    !/Table 3\. PERENNIAL WEED CONTROL\./.test(references) ||
    !/directed or shielded spray, or using wiper equipment/i.test(common) ||
    !/Vineyards: DO NOT allow spray or spray drift to contact green bark or stems, canes, laterals, suckers, fresh wounds, foliage or fruit\./i.test(vineyard) ||
    within(items, 9, 165, 183, 281, 200).some((item) => /\d\s*(?:L|mL)\//.test(item.str)))
    return empty("vineyard_situation_or_table_reference_unconfirmed");

  // These are *visual lines*, not a strip of x>=9 text: the bold DO NOT is a
  // separate glyph run at x=7.1. Read every run on each bounded baseline first.
  const restraintLines = [375.2, 368, 360.8, 353.6].map((y) =>
    joined(items.filter((item) => item.page === 2 && item.x >= 7 && item.x < 550 && Math.abs(item.y - y) < 1)));
  if (!/^DO NOT disturb treated weeds by cultivation, sowing or grazing for 1 day after treatment of annual weeds and 7 days for perennial weeds\.$/i.test(restraintLines[0]) ||
    !/^DO NOT treat weeds under poor growing or dormant conditions.*Reduced control may also occur when treating weeds heavily covered with dust or silt\.$/i.test(restraintLines[1]) ||
    !/^Rainfall occurring up to 6 hours.*repeat treatment may be required\.$/i.test(restraintLines[2]) ||
    !/^DO NOT use prior to sowing tomatoes\.$/i.test(restraintLines[3]))
    return empty("general_restraint_complete_lines_unconfirmed");
  // Tomato sowing is a separate, complete non-vineyard statement; never strip
  // its prefix and leave an imperative fragment in the vineyard restrictions.
  const restrictions = [common, vineyard, ...restraintLines.slice(0, 3)].join(" ");
  const source = "PDF physical page 9 TREE AND VINE CROPS: Vineyards → ";
  const uses: Record<string, unknown>[] = [];
  const unresolved: string[] = [];
  const reconciliation: VineyardBindingDecision[] = [
    { page: 2, target: "Tomato sowing restraint", state: "excluded", reason: `Physical page 2 RESTRAINTS: ${restraintLines[3]} This sowing condition is not a vineyard use.` },
  ];
  const add = (target: string, page: number, table: string, methodRates: Array<[string, string]>, comments: string): void => {
    const applicable = methodRates.flatMap(([method, raw]): WireLabelRate[] => {
      const parsed = parseRateCell(raw);
      // Non-numeric label instructions still belong to their method. Never
      // convert a per-15L or a wiper mixture into a calculator-supported basis.
      if (/^Wiper$/i.test(method) || /^Knapsack\b/i.test(method) || /^Low volume\b/i.test(method) || /^Cut stump$/i.test(method))
        return [{ label: method, basis: "other", unit: "", raw_text: raw } as WireLabelRate];
      if (/^9 L\/ha plus Pulse® Penetrant 500mL\/ 100L spray$/.test(raw) && method === "Boom")
        return [{ ...parseRateCell("9 L/ha")[0], label: method, raw_text: raw }];
      if (parsed.length === 1 && !parsed[0].condition_ambiguous && parsed[0].basis !== "other" &&
        !/\bplus\b/i.test(raw)) return [{ ...parsed[0], label: method }];
      return raw && raw !== "-" ? [{ label: method, basis: "other", unit: "", raw_text: raw } as WireLabelRate] : [];
    });
    if (!applicable.length) { unresolved.push(`${table}:${target}:no_printed_dose_or_method`); return; }
    const reference = `${source}${table}, physical page ${page}, ${target}`;
    const direction: ManufacturerLabelUse = { crop: "Vineyards", targets: [target], condition: `${table}; ${comments}`,
      rates: applicable, restrictions: `${restrictions} ${comments}`.trim() };
    for (const row of manufacturerUsesToRegisteredUses([direction], {
      product, withholdingPeriodDays: null, reEntryPeriodHours: null, preserveRateLabels: true,
    })) {
      row.source_refs = [reference];
      row.conditions = `${table}; ${comments}`;
      row.withholding_statement = withholdingStatement;
      row.rates = (row.rates as Array<Record<string, unknown>>).map((rate) => ({ ...rate,
        source_refs: String(rate.label ?? "") === "Wiper" ? [reference, "PDF physical page 13 APPLICATION: Wiper equipment, RATE"] : [reference] }));
      uses.push(row);
    }
  };
  const annualHeader = joined(within(items, 2, 0, 550, 310, 299));
  const situation = joined(within(items, 2, 9, 47, 295, 275));
  const annualRates = joined(within(items, 2, 240, 318, 295, 210));
  const annualCommentCell = joined(within(items, 2, 318, 550, 295, 230));
  if (!annualCommentCell.includes("For residual control of ANNUAL weeds") || !annualCommentCell.includes("For annual weed control in cultivated situations"))
    return empty("Table 2 annual critical-comment scope boundary unconfirmed");
  const annualComments = annualCommentCell.split("For residual control of ANNUAL weeds")[0].trim();
  const boom = annualRates.match(/BOOM:\s*([\d.\s-]+L\/ha)\s*HANDGUN:/i)?.[1]?.trim();
  const handgun = annualRates.match(/HANDGUN:\s*([\d.\s-]+mL\/100L)\s*KNAPSACK:/i)?.[1]?.trim();
  const knapsack = annualRates.match(/KNAPSACK:\s*([\d.\s-]+mL\/15L)\s*WIPER/i)?.[1]?.trim();
  const wiperLines = [382.4, 375.2, 368, 360.8, 353.6, 346.4, 339.2].map((y) =>
    joined(items.filter((item) => item.page === 13 && item.x >= 7 && item.x < 550 && Math.abs(item.y - y) < 1)));
  const wiperText = wiperLines.join(" ");
  const wiperRate = wiperLines[5]?.match(/^RATE: Mix 1 L of this product with 2 L clean water to prepare 33% solution\./)?.[0];
  const wiperUse = /tree and vine crops specified in this label/.test(wiperText) &&
    /DO NOT store mixed solution for more than a few days\./.test(wiperText) && wiperRate;
  const wiperInstructions = wiperText.slice(wiperText.indexOf("Avoid contact with desirable vegetation."), wiperText.indexOf("RATE:")).trim();
  const wiperLabel = `${wiperRate} Wiper equipment: ${wiperInstructions}`;
  if (!wiperUse) return empty("Table 2 references Wiper Application section, but its printed page 13 mixture RATE or tree/vine scope is unconfirmed");
  if (/ANNUAL WEED CONTROL/.test(annualHeader) && /Non- Cultivated Situations/.test(situation) && boom && handgun && knapsack &&
    /Use the lower rate on weeds up to 15 cm tall/i.test(annualComments)) {
    const targets = within(items, 2, 47, 128, 295, 15).filter((item) => Math.abs(item.x - 47.58) < 1 && item.str.trim());
    for (const target of targets) {
      add(target.str.trim(), 2, "Table 2 ANNUAL WEED CONTROL / Non-Cultivated Situations",
        [["Boom", boom], ["Handgun", handgun], ["Knapsack", knapsack], ["Wiper", wiperLabel]], annualComments);
      reconciliation.push({ page: 2, target: target.str.trim(), state: "mapped",
        reason: `Physical page 2 Non-Cultivated Situations printed annual target sharing Boom ${boom}, Handgun ${handgun}, Knapsack ${knapsack}, Wiper physical page 13 RATE mixture; comments: ${annualComments}` });
    }
    reconciliation.push({ page: 2, target: "Non-Cultivated Situations annual shared cell", state: "mapped",
      reason: `Physical page 2: ${targets.length} printed targets share Boom, Handgun and Knapsack; physical page 13 Wiper RATE ${wiperUse ? "bound as unsupported mixture basis" : "unresolved"}.` });
    reconciliation.push({ page: 2, target: "Residual tank mixtures / cultivated annual situations", state: "excluded",
      reason: "Physical page 2 Table 2 critical-comment continuation refers to separate TANK MIXTURES and CONSERVATION TILLAGE USES directions; these permissions are not established for the page 9 Vineyard situation." });
    reconciliation.push({ page: 2, target: "Controlled droplet applicators", state: "unresolved",
      reason: "Physical page 2 references the Application section; the device/mixture delivery table is not a per-ha or per-100L product dose bound to each annual target." });
  } else return empty("Table 2 shared non-cultivated rate cell unconfirmed");

  const heading = joined(within(items, 3, 0, 550, 391, 380));
  if (!/PERENNIAL WEED CONTROL/.test(heading)) return empty("Table 3 heading unconfirmed");
  // Each rate cell starts at x=85.4. Its next start bounds ALL continuation
  // lines, including the shared 3- and 4-target blocks on pages 3 and 4.
  for (const page of [3, 4, 5]) {
    const floor = page === 5 ? 218 : 22;
    if (!/WEEDS RATE CRITICAL COMMENTS/.test(joined(within(items, page, 9, 550, 391, 380)))) {
      return empty(`Table 3 page ${page}:continuation heading unconfirmed`);
    }
    const starts = within(items, page, 84, 88, 377, floor).filter((item) => Math.abs(item.x - 85.44) < 0.5 &&
      /^(?:-|\d)/.test(item.str.trim()) &&
      within(items, page, 9, 84, item.y + 1, item.y - 1).some((label) => Math.abs(label.x - 10) < 1 &&
        !!label.str.trim() && !/^(?:\(|spp\.|Does not|as nutgrass\.)/i.test(label.str.trim())));
    if (page === 3) {
      const cumbungi = within(items, 3, 9, 84, 183, 181).find((item) => /Cumbungi/.test(item.str));
      if (cumbungi) starts.push({ ...cumbungi, x: 85.44 });
    }
    starts.sort((a, b) => b.y - a.y);
    for (let index = 0; index < starts.length; index++) {
      const top = starts[index].y + 1;
      const bottom = (starts[index + 1]?.y ?? floor) + 0.8;
      const cell = (left: number, right: number): string => joined(within(items, page, left, right, top, bottom));
      const names = within(items, page, 9, 84, top, bottom).filter((item) => Math.abs(item.x - 10) < 1 &&
        item.str.trim() && !/^(?:\(|spp\. which|as nutgrass\.|Does not refer|\^)/i.test(item.str.trim()) &&
        !/^\d/.test(item.str.trim())).map((item) => item.str.trim().replace(/\s*\^$/, "").replace(/\s+\($/, ""));
      const boomCell = cell(84, 130);
      const handgunCell = cell(130, 168);
      const knapsackCell = cell(168, 213);
      const comments = cell(213, 550);
      const targets = names.filter((name) => !/^[.)]$/.test(name));
      if (!targets.length) return empty(`Table 3 page ${page} at ${top}:target continuation unbound`);
      for (const target of targets) {
        const aquatic = /^(?:Alligator weed|Cumbungi|Glyceria|Ludwigia peruviana|Phragmites|Water couch|Water hyacinth|Water lettuce|Waterlily)/i.test(target);
        if (aquatic) {
          const evidenced = /^Alligator weed/.test(target) ? "floating form only" : /^Glyceria/.test(target) ? "only allowable in dry drains/channels and dry margins" :
            /^Water couch/.test(target) ? "submerged-weed condition" : /^Waterlily/.test(target) ? "express reference to Table 6 Aquatic Weed Control" :
            /^Water (?:hyacinth|lettuce)/.test(target) ? "aquatic floating-plant situation" : null;
          const state = evidenced ? "excluded" : "unresolved";
          reconciliation.push({ page, target, state, reason: `Physical page ${page}: ${evidenced ?? "aquatic/wetland target without a separately established Vineyard situation"}; page 9 Vineyard reference does not establish that situation. Printed row: ${comments}` });
          continue;
        }
        if (!comments) {
          reconciliation.push({ page, target, state: "unresolved", reason: `Physical page ${page} prints Boom ${boomCell}, Handgun ${handgunCell}, Knapsack ${knapsackCell}, but no separate critical comment; whether the preceding Paragrass growth-stage comment applies to this Paspalum row cannot be established. Rates withheld pending that relationship.` });
          unresolved.push(`Table 3 page ${page}:${target}:shared critical comment relationship unconfirmed`);
          continue;
        }
        let rates: Array<[string, string]> = ([["Boom", boomCell], ["Handgun", handgunCell], ["Knapsack", knapsackCell]] as Array<[string, string]>)
          .filter(([, raw]) => !!raw && raw !== "-");
        if (/^Nutgrass/i.test(target)) {
          // Only the first cell belongs to NON-CULTIVATED; 3 + 3 and 700 +
          // 700 belong to the subsequent ARABLE LAND two-application block.
          rates = [["Boom", "6 L/ha"], ["Handgun", "1 L/100L"], ["Knapsack", "150 mL/15L"]];
        }
        if (target === "Pampas grass") rates = [
          ["Handgun — plants up to 1 m", "1 L/100L"], ["Handgun — plants over 1 m", "1.3 L/100L"],
          ["Knapsack — plants up to 1 m", "150 mL/15L"], ["Knapsack — plants over 1 m", "200 mL/15L"],
        ];
        if (target === "Sedge, tall") rates = [
          ["Boom — slashed stand", "2 L/ha"], ["Boom — unslashed stand", "4 L/ha"],
          ["Handgun — slashed stand", "500 mL/100L"], ["Handgun — unslashed stand", "1 L/100L"],
          ["Knapsack — slashed stand", "75 mL/15L"], ["Knapsack — unslashed stand", "150 mL/15L"]];
        if (target === "Bamboo") reconciliation.push({ page, target: "Bamboo — cut stump", state: "unresolved",
          reason: "Physical page 3 prints Cut stump: Dilute 1:6 (one part product plus six parts water); page 9 Vineyard situation names directed/shielded spray or wiper, not cut-stump treatment. No vineyard cut-stump permission established." });
        if (target === "Pampas grass") reconciliation.push({ page, target: "Pampas grass — low volume", state: "unresolved",
          reason: "Physical page 4 prints LOW VOLUME APPLICATION: Use 1:9 product:water, Apply 2x2mL per 0.5 m height. Page 9 does not establish low-volume equipment as a Vineyard method; no /ha or /100L projection." });
        if (wiperUse && (/\bWIPER\b/i.test(comments) && !/^(?:Kangaroo grass|Kikuyu grass)$/.test(target) || /^Rushes$/i.test(target)))
          rates.push(["Wiper", wiperLabel]);
        if (!rates.length) {
          reconciliation.push({ page, target, state: "unresolved", reason: `Physical page ${page} prints no Boom/Handgun/Knapsack dose; Wiper relation or mixture not established.` });
          unresolved.push(`Table 3 page ${page}:${target}:method dose unbound`);
          continue;
        }
        const scopedComments = /^Nutgrass/i.test(target) ? comments.split("ARABLE LAND:")[0].trim() : comments;
        if (/^Sorrel$/i.test(target) && /In Conservation Tillage situations/.test(scopedComments))
          reconciliation.push({ page, target: "Sorrel — Conservation Tillage seasonal suppression", state: "excluded", reason: "Physical page 4 expressly scopes 1.5 L/ha seasonal suppression to Conservation Tillage; not a Vineyard rate." });
        if (/^Soursob$/i.test(target) && /In Conservation Tillage/.test(scopedComments))
          reconciliation.push({ page, target: "Soursob — Conservation Tillage prior-to-sowing", state: "excluded", reason: "Physical page 5 expressly scopes May-July immediately prior to sowing to Conservation Tillage; not a Vineyard instruction." });
        const vineyardComments = /^(?:Kangaroo grass|Kikuyu grass)$/.test(target) ? scopedComments.split("For application by wiper equipment on Johnson grass")[0].trim() :
          target === "Sorrel" ? scopedComments.split("In Conservation Tillage situations")[0].trim() :
          target === "Soursob" ? scopedComments.split("In Conservation Tillage")[0].trim() :
          target === "Bamboo" ? scopedComments.split("Cut stump:")[0].trim() :
          target === "Pampas grass" ? scopedComments.split("LOW VOLUME APPLICATION:")[0].trim() : scopedComments;
        add(target, page, "Table 3 PERENNIAL WEED CONTROL", rates, vineyardComments);
        reconciliation.push({ page, target, state: "mapped", reason: `Physical page ${page} bounded weed row; ${rates.map(([method, raw]) => `${method}: ${raw.slice(0, 95)}`).join("; ")}; applicable comments: ${vineyardComments}` });
        if (/^Nutgrass/i.test(target)) reconciliation.push({ page, target: "Nutgrass — arable land", state: "excluded",
          reason: "Physical page 4 explicitly labels the 3 L/ha plus 3 L/ha and 700 mL/100L plus 700 mL/100L as ARABLE LAND first/second applications, not the non-cultivated vineyard direction." });
      }
    }
  }
  unresolved.push("re_entry_period:GRAPEVINE: no stated re-entry interval established in this PDF; hours unknown");
  unresolved.push("application_basis:GRAPEVINE: Wiper 1 L product + 2 L water is printed on physical page 13 and bound as label information; mixture basis not supported by the /ha or /100 L calculator");
  unresolved.push("application_basis:GRAPEVINE: Knapsack /15 L is printed in Tables 2 and 3; basis not supported by the /ha or /100 L calculator");
  for (const decision of reconciliation.filter((entry) => entry.state === "unresolved"))
    unresolved.push(`Table ${decision.page === 2 ? "2" : "3"} page ${decision.page}:${decision.target}:${decision.reason}`);
  return { uses, unresolved: [...new Set(unresolved)], reconciliation };
}
