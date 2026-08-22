// Shared fixtures for the research tests.
//
// These are HAND-WRITTEN representations of what the model could plausibly
// return. They are NOT captured production payloads: this sandbox has no
// OpenAI key, so no test here should be read as evidence of what the live
// model actually says about any product.

import type { ChemicalResearchResult } from "./schema.ts";

export interface FakeCallLog {
  url: string;
  init: RequestInit;
  body: Record<string, unknown>;
}

/** Wrap a research payload in a Responses API envelope. */
export function responsesEnvelope(
  payload: unknown,
  opts: {
    id?: string;
    model?: string;
    searchQueries?: string[];
    sources?: string[];
    usage?: { input_tokens: number; output_tokens: number };
    status?: string;
    includeResults?: boolean;
  } = {},
): Record<string, unknown> {
  const queries = opts.searchQueries ?? ["dithane rainshield apvma registration"];
  const sources = opts.sources ?? [];
  return {
    id: opts.id ?? "resp_test_1",
    object: "response",
    model: opts.model ?? "gpt-5.6-terra",
    status: opts.status ?? "completed",
    output: [
      ...queries.map((q, i) => ({
        type: "web_search_call",
        id: `ws_${i}`,
        status: "completed",
        action: {
          type: "search",
          query: q,
          sources: sources.map((url) => ({ url })),
        },
        ...(opts.includeResults ? { results: [{ url: sources[0] ?? "", title: "t" }] } : {}),
      })),
      {
        type: "message",
        id: "msg_1",
        role: "assistant",
        content: [
          {
            type: "output_text",
            text: JSON.stringify(payload),
            annotations: sources.slice(0, 2).map((url) => ({
              type: "url_citation",
              url,
              title: "cited",
            })),
          },
        ],
      },
    ],
    usage: opts.usage ?? { input_tokens: 1200, output_tokens: 800, total_tokens: 2000 },
  };
}

/** A fetch stand-in that records calls and replays queued responses. */
export function fakeFetch(
  responses: (Response | (() => Response | Promise<Response>))[],
): { fn: typeof fetch; calls: FakeCallLog[] } {
  const calls: FakeCallLog[] = [];
  let i = 0;
  const fn = (async (url: string | URL | Request, init?: RequestInit) => {
    let body: Record<string, unknown> = {};
    try {
      body = JSON.parse(String(init?.body ?? "{}"));
    } catch {
      body = {};
    }
    calls.push({ url: String(url), init: init ?? {}, body });
    const next = responses[Math.min(i, responses.length - 1)];
    i += 1;
    if (typeof next === "function") return await next();
    return next;
  }) as unknown as typeof fetch;
  return { fn, calls };
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/**
 * A Dithane-shaped research payload.
 *
 * The registration number here is a LEAD the tests feed to a FAKE register
 * adapter. Nothing about this fixture asserts what APVMA actually holds.
 */
export const DITHANE_RESEARCH_PAYLOAD: ChemicalResearchResult = {
  product: {
    searched_name: "Dithane Rainshield",
    canonical_name: "Dithane Rainshield Neo Tec Fungicide",
    manufacturer: "BASF",
    registrant: "BASF Australia Ltd",
    category: "fungicide",
    form_type: "solid",
    country: "AU",
    source_refs: ["https://portal.apvma.gov.au/pubcris?p_id=1"],
  },
  registration_candidates: [
    {
      scheme: "apvma",
      number: "59688",
      registered_product_name: "Dithane Rainshield Neo Tec Fungicide",
      country: "AU",
      source_url: "https://portal.apvma.gov.au/pubcris?p_id=1",
      source_domain: "portal.apvma.gov.au",
      confidence: "high",
      reason: "PubCRIS entry matches the searched product name",
    },
  ],
  active_ingredients: [
    {
      name: "Mancozeb",
      concentration: 750,
      concentration_unit: "g/kg",
      suggested_scheme: "frac",
      suggested_group: "M5",
      source_refs: ["https://portal.apvma.gov.au/pubcris?p_id=1"],
    },
  ],
  registered_uses: [
    {
      crop: "Grapevines",
      targets: ["Downy Mildew", "Black Spot"],
      rates: [
        {
          label: "Protectant programme",
          basis: "per_100_litres",
          value: 200,
          min_value: null,
          max_value: null,
          unit: "g",
          raw_text: "200 g/100 L",
          source_refs: ["https://elabels.apvma.gov.au/59688.pdf"],
        },
        {
          label: "Protectant programme",
          basis: "per_hectare",
          value: 2,
          min_value: null,
          max_value: null,
          unit: "kg",
          raw_text: "2 kg/ha",
          source_refs: ["https://elabels.apvma.gov.au/59688.pdf"],
        },
      ],
      whp: "Not required when used as directed",
      rei: "24 hours",
      restrictions: ["Do not apply after E-L 31"],
      source_refs: ["https://elabels.apvma.gov.au/59688.pdf"],
    },
  ],
  documents: {
    official_label_candidates: [
      {
        url: "https://elabels.apvma.gov.au/59688.pdf",
        title: "Approved label",
        domain: "elabels.apvma.gov.au",
        reason: "APVMA eLabels approved label document",
      },
    ],
    product_page_candidates: [
      {
        url: "https://crop-solutions.basf.com.au/products/dithane-rainshield",
        title: "Dithane Rainshield | BASF",
        domain: "crop-solutions.basf.com.au",
        reason: "Registrant product page",
      },
    ],
    sds_candidates: [
      {
        url: "https://crop-solutions.basf.com.au/sds/dithane-rainshield-sds.pdf",
        title: "SDS",
        domain: "crop-solutions.basf.com.au",
        reason: "Safety data sheet",
      },
    ],
  },
  sources: [
    {
      url: "https://portal.apvma.gov.au/pubcris?p_id=1",
      domain: "portal.apvma.gov.au",
      title: "PubCRIS",
      source_type: "official_register",
      supports_fields: ["registration.number"],
    },
    {
      url: "https://elabels.apvma.gov.au/59688.pdf",
      domain: "elabels.apvma.gov.au",
      title: "Approved label",
      source_type: "manufacturer_label",
      supports_fields: ["registered_uses", "active_ingredients"],
    },
  ],
  unresolved: [],
  notes: null,
};

/** Deep clone so a test mutating a fixture cannot leak into the next test. */
export function cloneResearch(r: ChemicalResearchResult = DITHANE_RESEARCH_PAYLOAD) {
  return JSON.parse(JSON.stringify(r)) as ChemicalResearchResult;
}
