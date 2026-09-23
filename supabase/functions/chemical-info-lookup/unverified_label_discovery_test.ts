import { assertEquals } from "jsr:@std/assert";
import { cloneResearch } from "./research/test_fixtures.ts";
import { discoverUnverifiedLabel } from "./unverified_label_discovery.ts";

const noFetch = (async () => { throw new Error("Network should not be called"); }) as typeof fetch;

Deno.test("a numeric APVMA lead never becomes an unverified product", async () => {
  assertEquals(await discoverUnverifiedLabel("59688", cloneResearch(), noFetch), null);
});

Deno.test("research without a registrant product page cannot mint a label or chemistry", async () => {
  const research = cloneResearch();
  research.documents.product_page_candidates = [];
  research.documents.official_label_candidates = [];
  assertEquals(await discoverUnverifiedLabel("Dithane Rainshield", research, noFetch), null);
});

Deno.test("a registrant page for a competing variant cannot mint a label for the query", async () => {
  const research = cloneResearch();
  research.documents.product_page_candidates = [{
    url: "https://www.basf.com/au/dithane-neo-tec", title: "Dithane Neo Tec",
    domain: "basf.com", reason: "product page", linked_from_url: null,
  }];
  research.documents.official_label_candidates = [];
  const fetchFn = (async () => new Response(
    '<html><h1>Dithane Rainshield Neo Tec Fungicide</h1><a href="/label.pdf">Product Label</a></html>',
    { headers: { "content-type": "text/html" } },
  )) as typeof fetch;
  assertEquals(await discoverUnverifiedLabel("Dithane Rainshield", research, fetchFn), null);
});
