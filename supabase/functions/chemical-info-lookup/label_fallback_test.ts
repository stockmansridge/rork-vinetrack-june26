import { assertEquals } from "jsr:@std/assert";
import { chooseLabelCandidate, confirmedOCRName, directOfficialLabelURL } from "./label_fallback.ts";
import type { RegisterCandidate } from "./ingestion/contract.ts";

const candidate: RegisterCandidate = {
  registration_number: "59688", registered_product_name: "DITHANE RAINSHIELD",
  registrant: "Corteva", product_category: "fungicide", register_status: "registered",
  actives_summary: "Mancozeb", activity_groups: [], match_rank: 0,
};

Deno.test("photo identity uses the whole label rather than WARNING or CAUTION", () => {
  for (const heading of ["WARNING", "CAUTION"]) {
    const ocr = `${heading}\nDITHANE RAINSHIELD\nFUNGICIDE\nSAFETY DIRECTIONS`;
    assertEquals(confirmedOCRName("DITHANE RAINSHIELD", ocr), "DITHANE RAINSHIELD");
    assertEquals(confirmedOCRName(heading, ocr), null);
    assertEquals(confirmedOCRName("SAFETY DIRECTIONS", ocr), null);
    assertEquals(confirmedOCRName("Invented chemical name", ocr), null);
  }
  assertEquals(confirmedOCRName("DITHANE RAINSHIELD", "WARNING\nDITHANE RAINSHIELD"), null);
  assertEquals(confirmedOCRName("CAUTION WARNING", "CAUTION WARNING\nFUNGICIDE"), null);
  assertEquals(confirmedOCRName("UNKNOWN FUNGICIDE", "CAUTION\nFUNGICIDE"), null);
});

Deno.test("only unambiguous APVMA identities and direct official PDFs pass", () => {
  assertEquals(chooseLabelCandidate("APVMA 59688", [candidate]), candidate);
  assertEquals(chooseLabelCandidate("Dithane Rainshield", [candidate]), candidate);
  assertEquals(chooseLabelCandidate("Dithane Rainshield", [candidate, { ...candidate, registration_number: "12345" }]), null);
  assertEquals(directOfficialLabelURL("https://elabels.apvma.gov.au/59688ELBL.pdf", "59688"), "https://elabels.apvma.gov.au/59688ELBL.pdf");
  for (const url of ["https://example.com/59688.pdf", "https://elabels.apvma.gov.au/", "https://elabels.apvma.gov.au/other.pdf", "https://portal.apvma.gov.au/"]) {
    assertEquals(directOfficialLabelURL(url, "59688"), null);
  }
  assertEquals(directOfficialLabelURL(null, "59688"), null);
});
