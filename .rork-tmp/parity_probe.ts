// Local, offline reproduction of the SERVER's deterministic search tiers for
// the Hortitrol parity investigation. No network: this exercises the exact
// shipped matcher + ranker against the register rows the query could return.
import {
  discoveryMatchRank,
  nameCorresponds,
  retrievalQueryVariants,
} from "../supabase/functions/chemical-info-lookup/ingestion/matching.ts";
import { rankCandidates } from "../supabase/functions/chemical-info-lookup/ranking.ts";

const QUERY = "Hortitrol Winter Oil";

// The two products the two platforms actually landed on, plus the rows an
// APVMA free-text retrieval for these tokens plausibly returns.
const REGISTER_NAMES = [
  "VICOL WINTER OIL INSECTICIDE",
  "SYNERTROL HORTI BOTANICAL OIL CONCENTRATE",
  "BIOPEST PARAFFINIC SPRAY OIL",
  "WINTER OIL",
];

console.log("QUERY:", JSON.stringify(QUERY));
console.log("retrievalQueryVariants:", retrievalQueryVariants(QUERY));
console.log("");
console.log("discoveryMatchRank (null = DROPPED, never becomes a candidate):");
for (const name of REGISTER_NAMES) {
  console.log(
    `  ${JSON.stringify(name).padEnd(46)} corresponds=${
      String(nameCorresponds(QUERY, name)).padEnd(5)
    } rank=${discoveryMatchRank(QUERY, name)}`,
  );
}

console.log("");
console.log("--- If the register HAD returned both rows, how would ranking order them? ---");
const ranked = rankCandidates(
  [
    {
      name: "VICOL WINTER OIL INSECTICIDE",
      source: "official_register",
      registration_number: "33182",
    },
    {
      name: "SYNERTROL HORTI BOTANICAL OIL CONCENTRATE",
      source: "official_register",
      registration_number: "50067",
    },
  ],
  QUERY,
  "AU",
);
for (const r of ranked.results as Record<string, unknown>[]) {
  console.log(
    `  ${String(r.registration_number).padEnd(6)} ${String(r.rank_tier).padEnd(18)} ${
      String(r.rank_relevance).padEnd(18)
    } score=${r.rank_score}`,
  );
}
console.log("  summary:", JSON.stringify(ranked.summary));

console.log("");
console.log("--- Same two rows, but arriving from RESEARCH (no source field) ---");
const researched = rankCandidates(
  [
    { name: "SYNERTROL HORTI BOTANICAL OIL CONCENTRATE", registration_number: "50067" },
    { name: "VICOL WINTER OIL INSECTICIDE", registration_number: "33182" },
  ],
  QUERY,
  "AU",
);
for (const r of researched.results as Record<string, unknown>[]) {
  console.log(
    `  ${String(r.registration_number).padEnd(6)} ${String(r.rank_tier).padEnd(18)} ${
      String(r.rank_relevance).padEnd(18)
    } score=${r.rank_score}`,
  );
}
console.log("  summary:", JSON.stringify(researched.summary));
