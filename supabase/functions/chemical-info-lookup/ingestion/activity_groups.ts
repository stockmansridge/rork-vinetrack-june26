// Authoritative activity-group classification for common viticultural actives.
//
// MOVED OUT of index.ts in Stage 3 so the authoritative ingestion module and
// its deno tests can consult the SAME table the AI cross-check uses. The
// function is deployed with `supabase functions deploy chemical-info-lookup`
// (scripts/deploy-edge-functions.ps1 / .sh), which bundles the full local
// module graph — the same mechanism that already ships
// `vinetrack-webhook-dispatch/lib.ts` and the `_shared/email` imports.
// Single-file dashboard pastes are NOT supported for this function any more.
//
// This is the server-side twin of the iOS `AuthoritativeActivityGroups` and
// the Android `AuthoritativeActivityGroups` object. All three MUST agree — the
// whole point is that a product's activity group has one answer, not three.
// When you change one, change all three and bump ACTIVITY_GROUP_TABLE_VERSION.
//
// It exists so no extraction is ever the only opinion in the room. Whatever a
// model or a register document says an active's group is, it is checked
// against this table before the response leaves the server, and a
// disagreement is returned as an explicit conflict rather than silently
// overwritten.
//
// Activity group is a property of the ACTIVE, not of a brand, and it does not
// vary by country — which is why this table has no country dimension while
// product identity emphatically does.

/** Bump whenever the table changes. Stamped onto every verification. */
export const ACTIVITY_GROUP_TABLE_VERSION = 1;

export type ActivityGroupScheme = "frac" | "hrac" | "irac" | "not_applicable";

export interface ActivityGroup {
  scheme: ActivityGroupScheme;
  code: string;
  common_name?: string | null;
}

const frac = (code: string, name: string): ActivityGroup => ({
  scheme: "frac",
  code,
  common_name: name,
});
const hrac = (code: string, name: string): ActivityGroup => ({
  scheme: "hrac",
  code,
  common_name: name,
});
const irac = (code: string, name: string): ActivityGroup => ({
  scheme: "irac",
  code,
  common_name: name,
});

export const ACTIVITY_GROUP_TABLE: Record<string, ActivityGroup> = {
  // ---- Fungicides (FRAC) ----
  "tebuconazole": frac("3", "DMI / Triazole"),
  "myclobutanil": frac("3", "DMI / Triazole"),
  "penconazole": frac("3", "DMI / Triazole"),
  "triadimenol": frac("3", "DMI / Triazole"),
  "tetraconazole": frac("3", "DMI / Triazole"),
  "difenoconazole": frac("3", "DMI / Triazole"),
  "propiconazole": frac("3", "DMI / Triazole"),
  "flutriafol": frac("3", "DMI / Triazole"),
  "triflumizole": frac("3", "DMI / Imidazole"),
  "prochloraz": frac("3", "DMI / Imidazole"),
  "fenarimol": frac("3", "DMI / Pyrimidine"),
  "metalaxyl": frac("4", "Phenylamide"),
  "metalaxyl m": frac("4", "Phenylamide"),
  "mefenoxam": frac("4", "Phenylamide"),
  "benalaxyl": frac("4", "Phenylamide"),
  "spiroxamine": frac("5", "Amine / Morpholine"),
  "dimethomorph": frac("40", "CAA"),
  "mandipropamid": frac("40", "CAA"),
  "benthiavalicarb": frac("40", "CAA"),
  "iprovalicarb": frac("40", "CAA"),
  "carbendazim": frac("1", "MBC / Benzimidazole"),
  "thiophanate methyl": frac("1", "MBC / Thiophanate"),
  "iprodione": frac("2", "Dicarboximide"),
  "procymidone": frac("2", "Dicarboximide"),
  "cyprodinil": frac("9", "Anilinopyrimidine"),
  "pyrimethanil": frac("9", "Anilinopyrimidine"),
  "mepanipyrim": frac("9", "Anilinopyrimidine"),
  "azoxystrobin": frac("11", "QoI / Strobilurin"),
  "trifloxystrobin": frac("11", "QoI / Strobilurin"),
  "pyraclostrobin": frac("11", "QoI / Strobilurin"),
  "kresoxim methyl": frac("11", "QoI / Strobilurin"),
  "famoxadone": frac("11", "QoI"),
  "fenamidone": frac("11", "QoI"),
  "fludioxonil": frac("12", "Phenylpyrrole"),
  "quinoxyfen": frac("13", "Aza-naphthalene"),
  "boscalid": frac("7", "SDHI"),
  "fluopyram": frac("7", "SDHI"),
  "fluxapyroxad": frac("7", "SDHI"),
  "penthiopyrad": frac("7", "SDHI"),
  "isopyrazam": frac("7", "SDHI"),
  "benzovindiflupyr": frac("7", "SDHI"),
  "pydiflumetofen": frac("7", "SDHI"),
  "fenhexamid": frac("17", "Hydroxyanilide"),
  "cyazofamid": frac("21", "QiI"),
  "amisulbrom": frac("21", "QiI"),
  "metrafenone": frac("U8", "Aryl-phenyl-ketone"),
  "pyriofenone": frac("U8", "Aryl-phenyl-ketone"),
  "cyflufenamid": frac("U6", "Phenyl-acetamide"),
  "proquinazid": frac("13", "Quinazolinone"),
  "fluazinam": frac("29", "Uncoupler"),
  "ametoctradin": frac("45", "QoSI"),
  "oxathiapiprolin": frac("49", "OSBPI"),
  "fluopicolide": frac("43", "Benzamide"),
  "zoxamide": frac("22", "Benzamide"),
  "phosphorous acid": frac("P07", "Host defence induction"),
  "phosphonic acid": frac("P07", "Host defence induction"),
  "potassium phosphonate": frac("P07", "Host defence induction"),
  "fosetyl aluminium": frac("P07", "Host defence induction"),
  "fosetyl al": frac("P07", "Host defence induction"),
  "sulfur": frac("M2", "Multi-site / Inorganic"),
  "sulphur": frac("M2", "Multi-site / Inorganic"),
  "copper hydroxide": frac("M1", "Multi-site / Copper"),
  "copper oxychloride": frac("M1", "Multi-site / Copper"),
  "cuprous oxide": frac("M1", "Multi-site / Copper"),
  "tribasic copper sulfate": frac("M1", "Multi-site / Copper"),
  "mancozeb": frac("M3", "Multi-site / Dithiocarbamate"),
  "metiram": frac("M3", "Multi-site / Dithiocarbamate"),
  "propineb": frac("M3", "Multi-site / Dithiocarbamate"),
  "ziram": frac("M3", "Multi-site / Dithiocarbamate"),
  "thiram": frac("M3", "Multi-site / Dithiocarbamate"),
  "captan": frac("M4", "Multi-site / Phthalimide"),
  "folpet": frac("M4", "Multi-site / Phthalimide"),
  "chlorothalonil": frac("M5", "Multi-site / Chloronitrile"),
  "dithianon": frac("M9", "Multi-site / Quinone"),

  // ---- Herbicides (HRAC) ----
  "glyphosate": hrac("G", "EPSP synthase inhibitor"),
  "glufosinate": hrac("H", "Glutamine synthetase inhibitor"),
  "glufosinate ammonium": hrac("H", "Glutamine synthetase inhibitor"),
  "paraquat": hrac("D", "PSI electron diverter"),
  "diquat": hrac("D", "PSI electron diverter"),
  "simazine": hrac("C1", "PSII inhibitor"),
  "diuron": hrac("C2", "PSII inhibitor"),
  "amitrole": hrac("F3", "Carotenoid biosynthesis inhibitor"),
  "oxyfluorfen": hrac("E", "PPO inhibitor"),
  "carfentrazone": hrac("E", "PPO inhibitor"),
  "flumioxazin": hrac("E", "PPO inhibitor"),
  "haloxyfop": hrac("A", "ACCase inhibitor"),
  "clethodim": hrac("A", "ACCase inhibitor"),
  "fluazifop": hrac("A", "ACCase inhibitor"),
  "sethoxydim": hrac("A", "ACCase inhibitor"),
  "propyzamide": hrac("K1", "Microtubule assembly inhibitor"),
  "pendimethalin": hrac("K1", "Microtubule assembly inhibitor"),
  "trifluralin": hrac("K1", "Microtubule assembly inhibitor"),
  "isoxaben": hrac("L", "Cellulose synthesis inhibitor"),
  "indaziflam": hrac("L", "Cellulose synthesis inhibitor"),
  "metsulfuron methyl": hrac("B", "ALS inhibitor"),
  "chlorsulfuron": hrac("B", "ALS inhibitor"),
  "imazapyr": hrac("B", "ALS inhibitor"),
  "2,4 d": hrac("O", "Synthetic auxin"),
  "mcpa": hrac("O", "Synthetic auxin"),
  "triclopyr": hrac("O", "Synthetic auxin"),
  "clopyralid": hrac("O", "Synthetic auxin"),
  "pelargonic acid": hrac("Z", "Unknown / non-selective contact"),

  // ---- Insecticides & miticides (IRAC) ----
  "chlorpyrifos": irac("1B", "Organophosphate"),
  "methomyl": irac("1A", "Carbamate"),
  "alpha cypermethrin": irac("3A", "Pyrethroid"),
  "bifenthrin": irac("3A", "Pyrethroid"),
  "lambda cyhalothrin": irac("3A", "Pyrethroid"),
  "deltamethrin": irac("3A", "Pyrethroid"),
  "esfenvalerate": irac("3A", "Pyrethroid"),
  "imidacloprid": irac("4A", "Neonicotinoid"),
  "thiamethoxam": irac("4A", "Neonicotinoid"),
  "acetamiprid": irac("4A", "Neonicotinoid"),
  "clothianidin": irac("4A", "Neonicotinoid"),
  "spinetoram": irac("5", "Spinosyn"),
  "spinosad": irac("5", "Spinosyn"),
  "abamectin": irac("6", "Avermectin"),
  "emamectin benzoate": irac("6", "Avermectin"),
  "buprofezin": irac("16", "Chitin biosynthesis inhibitor"),
  "methoxyfenozide": irac("18", "Diacylhydrazine"),
  "tebufenozide": irac("18", "Diacylhydrazine"),
  "etoxazole": irac("10B", "Mite growth inhibitor"),
  "clofentezine": irac("10A", "Mite growth inhibitor"),
  "hexythiazox": irac("10A", "Mite growth inhibitor"),
  "propargite": irac("12C", "METI / Sulfite ester"),
  "fenbutatin oxide": irac("12B", "Organotin miticide"),
  "bifenazate": irac("20D", "Mitochondrial complex III inhibitor"),
  "chlorantraniliprole": irac("28", "Diamide"),
  "cyantraniliprole": irac("28", "Diamide"),
  "flubendiamide": irac("28", "Diamide"),
  "sulfoxaflor": irac("4C", "Sulfoximine"),
  "spirotetramat": irac("23", "Tetramic acid"),
  "spirodiclofen": irac("23", "Tetronic acid"),
  "pyriproxyfen": irac("7C", "Juvenile hormone mimic"),
  "indoxacarb": irac("22A", "Oxadiazine"),
  "bacillus thuringiensis": irac("11A", "Bt / Microbial disruptor"),
};

export function normaliseActiveName(raw: string): string {
  return raw.trim().toLowerCase().replace(/-/g, " ").replace(/\s+/g, " ");
}

/**
 * Strips the noise humans, AI, and register documents put around a code so
 * "Group 3", "group3" and "11 (QoI / Strobilurin)" all reduce to a bare code.
 */
export function normaliseCode(raw: string): string {
  let value = String(raw ?? "").trim().toUpperCase();
  for (const prefix of ["GROUP ", "GROUP", "FRAC ", "HRAC ", "IRAC ", "MOA ", "CODE "]) {
    if (value.startsWith(prefix)) value = value.slice(prefix.length).trim();
  }
  const paren = value.indexOf("(");
  if (paren >= 0) value = value.slice(0, paren).trim();
  return value.replace(/\s+/g, "");
}

/**
 * Look up an active's authoritative group.
 *
 * Returns null when the active is not in the table — which means UNKNOWN,
 * never "the extraction must be right". Callers must not read null as
 * permission to trust an unverified extraction.
 */
export function authoritativeGroup(activeName: string): ActivityGroup | null {
  const key = normaliseActiveName(activeName);
  if (!key) return null;
  if (ACTIVITY_GROUP_TABLE[key]) return ACTIVITY_GROUP_TABLE[key];
  // Salt/ester forms are written many ways ("glyphosate isopropylamine").
  // Match the longest known active contained in the string so a formulation
  // suffix does not lose the classification.
  const candidates = Object.keys(ACTIVITY_GROUP_TABLE)
    .filter((k) => k.length >= 5 && key.includes(k))
    .sort((a, b) => b.length - a.length);
  return candidates.length ? ACTIVITY_GROUP_TABLE[candidates[0]] : null;
}

export interface GroupConflict {
  field: string;
  active_ingredient_name: string;
  extracted_value: string;
  authoritative_value: string;
  extracted_source: string;
  authoritative_source: string;
}

export interface Reconciliation {
  group: ActivityGroup | null;
  /** Which source the returned group may be attributed to. */
  source: string | null;
  conflict: GroupConflict | null;
}

export function displayLabel(g: ActivityGroup): string {
  const scheme = g.scheme === "frac"
    ? "FRAC"
    : g.scheme === "hrac"
    ? "HRAC"
    : g.scheme === "irac"
    ? "IRAC"
    : "Not applicable";
  return g.common_name ? `${scheme} ${g.code} (${g.common_name})` : `${scheme} ${g.code}`;
}

/**
 * Cross-check an extracted group against the authoritative table.
 *
 * This is the source-disagreement gate:
 *  - No authoritative opinion  -> keep the extraction, but it stays attributed
 *                                 to the AI, so it can never read as verified.
 *  - Agreement                 -> the authoritative group wins (same code,
 *                                 better source).
 *  - Disagreement              -> return the AUTHORITATIVE group PLUS a
 *                                 conflict. The extracted value never silently
 *                                 survives, and the product cannot be Verified
 *                                 until a human resolves it.
 */
export function reconcileGroup(
  activeName: string,
  extracted: ActivityGroup | null,
): Reconciliation {
  const authoritative = authoritativeGroup(activeName);
  if (!authoritative) {
    return {
      group: extracted,
      source: extracted ? "ai_interpretation" : null,
      conflict: null,
    };
  }
  if (!extracted || !extracted.code) {
    return { group: authoritative, source: "authoritative_classification", conflict: null };
  }
  if (extracted.scheme === authoritative.scheme && extracted.code === authoritative.code) {
    return { group: authoritative, source: "authoritative_classification", conflict: null };
  }
  return {
    group: authoritative,
    source: "authoritative_classification",
    conflict: {
      field: "activity_group",
      active_ingredient_name: activeName,
      extracted_value: displayLabel(extracted),
      authoritative_value: displayLabel(authoritative),
      extracted_source: "ai_interpretation",
      authoritative_source: "authoritative_classification",
    },
  };
}
