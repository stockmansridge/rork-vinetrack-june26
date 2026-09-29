// Local, non-network export of the retained, hash-locked document and review materials.
import { extractManufacturerDocumentText } from "../supabase/functions/chemical-info-lookup/ingestion/manufacturer_document.ts";
import { bindVineyardReferencedTables } from "../supabase/functions/chemical-info-lookup/ingestion/vineyard_table_binding.ts";
import { WEEDMASTER_LABEL_LEAD } from "../supabase/functions/chemical-info-lookup/ingestion/documented_label_lead.ts";

const destination = new URL("../docs/weedmaster-acceptance/", import.meta.url);
const pdf = await Deno.readFile(new URL("weedmaster_duo_documented.pdf", destination));
const sha = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", pdf)))
  .map((n) => n.toString(16).padStart(2, "0")).join("");
if (sha !== "69213c077e191e99682e515884d7667156367ea7ab927ecdac2882f4d0ec39b8")
  throw Error("retained source PDF bytes changed; do not export");
const items = await extractManufacturerDocumentText({ now: () => new Date(),
  fetchFn: (() => { throw Error("network forbidden"); }) as typeof fetch }, pdf);
if (!items) throw Error("document text extraction failed");
const mapping = bindVineyardReferencedTables(items, { country: "AU", scheme: "apvma", registration_number: "53576" },
  "WITHHOLDING PERIOD: NOT REQUIRED WHEN USED AS DIRECTED");
await Deno.writeTextFile(new URL("vineyard_mapping.json", destination), JSON.stringify({
  source_url: WEEDMASTER_LABEL_LEAD, document_sha256: sha,
  status: "unsigned candidate mapping; all referenced perennial rows individually reconciled; explicit exceptions remain",
  mapped_directions: mapping.uses, reconciliation: mapping.reconciliation, unresolved_exceptions: mapping.unresolved,
}, null, 2));
await Deno.writeTextFile(new URL("visual_review_candidate.json", destination), JSON.stringify({
  status: "awaiting_authenticated_admin_review", document_sha256: sha,
  source_url: WEEDMASTER_LABEL_LEAD, physical_page: 1,
  location: "orange band near top of physical cover page, left side",
  verbatim: "ACTIVE CONSTITUENT: 360 g/L GLYPHOSATE present as the isopropylamine and mono-ammonium salts",
  active: { name: "GLYPHOSATE", salt_form: "isopropylamine and mono-ammonium salts", concentration: 360, unit: "g/L" },
  formulation: "SL soluble concentrate", method: "human_visual_transcription", document_version: "08-09-2022",
  confirm_review: false, reviewed_by: null, reviewed_at: null,
  printed_approval_reference_from_text_layer: "53576/136340",
  printed_approval_date_from_text_layer: "08-09-2022",
  cover_attachment: "weedmaster_page_1.png",
}, null, 2));
console.log(JSON.stringify({ destination: destination.pathname, document_sha256: sha,
  bound_rows: mapping.uses.length, unresolved: mapping.unresolved.length,
  actual_review_status: "awaiting_authenticated_admin_review", network_calls: 0 }));
