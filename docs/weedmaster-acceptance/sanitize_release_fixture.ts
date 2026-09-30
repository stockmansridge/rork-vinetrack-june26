// Local fixture importer only. Never submits review evidence or contacts a backend.
import { assertEquals } from "jsr:@std/assert";

const input = Deno.args[0];
if (!input) throw new Error("Supply the private applied snapshot path.");
const bytes = await Deno.readFile(input);
const digest = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)))
  .map((byte) => byte.toString(16).padStart(2, "0")).join("");
assertEquals(digest, "6daee0d6d2502a897cac988123ead3f6a1db07ec3f75ad5032be6ed40ac4c3a6");
const original = JSON.parse(new TextDecoder().decode(bytes));
const row = structuredClone(original);
// Only personal reviewer identity is substituted. All timestamps, amounts,
// directions, sources/order, versions, hashes, chemistry and warnings are exact.
const visual = row.verification_sources[6].reviewed_visual_declaration;
visual.reviewed_by = "TEST-ONLY-REDACTED-EXISTING-REVIEWER-NOT-AN-ATTESTATION";
const restored = structuredClone(row);
restored.verification_sources[6].reviewed_visual_declaration.reviewed_by =
  original.verification_sources[6].reviewed_visual_declaration.reviewed_by;
assertEquals(restored, original);
await Deno.writeTextFile(new URL("./revision-2-shared/master-revision-2.sanitized-fixture.json", import.meta.url),
  JSON.stringify({ fixture_notice: "Actual applied snapshot derivative; ONLY verification_sources[6].reviewed_visual_declaration.reviewed_by redacted. NOT a new review or approval.",
    original_sha256: digest, row }, null, 2) + "\n");
console.log("Fixture generated; only reviewer identity redacted, all other fields/order unchanged.");
