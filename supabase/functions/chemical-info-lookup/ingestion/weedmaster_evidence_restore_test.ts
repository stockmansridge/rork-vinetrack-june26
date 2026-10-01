// deno-lint-ignore-file no-explicit-any require-await
// deno-lint-ignore no-import-prefix no-unversioned-import -- Reuse the repository's locked test assertion dependency.
import { assert, assertEquals, assertThrows } from "jsr:@std/assert";
import { mergeRefreshEvidence, trustedRetainedManufacturerDocument } from "./retained_manufacturer_evidence.ts";
import { buildWeedmasterEvidenceRestorePatch, storeWeedmasterEvidenceRestorePreview, WEEDMASTER_ID } from "./weedmaster_evidence_restore.ts";
import { applyCandidateRefreshPatchAtRevision } from "./refresh.ts";
import { masterHasExactHydrationReadiness } from "./master_lookup.ts";
const fixture = JSON.parse(await Deno.readTextFile(new URL(
  "../../../../docs/weedmaster-acceptance/revision-2-shared/master-revision-2.sanitized-fixture.json", import.meta.url,
)));
const row: any = fixture.row ?? fixture;
const manufacturer = row.verification_sources[6];
const regulator = "https://elabels.apvma.gov.au/53576ELBL.pdf";
const NOW = "2026-10-01T18:00:00.000Z";

Deno.test("refresh evidence: distinct roles, no source invention, weaker rediscovery cannot strip review", () => {
  const old = { ...row, verification_sources: [manufacturer,
    { kind: "manufacturer_product", name: "Product", reference: "https://nufarm.com/au/product/weedmaster-duo/" },
    { kind: "ai_interpretation", name: "Other evidence" }] };
  const fresh = [{ kind: "manufacturer_label", name: "eLabel", reference: regulator },
    { kind: "manufacturer_label", name: "Register claims", reference: "https://data.gov.au/data/api/3/action/datastore_search?resource_id=claims" },
    { kind: "manufacturer_label", name: "Rediscovered without review", reference: manufacturer.reference }];
  const merged = mergeRefreshEvidence(old, fresh);
  assertEquals(merged.find((s) => s.reference === manufacturer.reference), manufacturer);
  assertEquals(merged.find((s) => s.reference === regulator)?.kind, "regulator_label");
  assertEquals(merged.find((s) => s.name === "Register claims")?.kind, "official_register");
  assert(merged.some((s) => s.kind === "manufacturer_product"));
  assert(merged.some((s) => s.kind === "ai_interpretation"));
  const onlyRegulator = mergeRefreshEvidence({ ...old, verification_sources: [] }, fresh.slice(0, 2));
  assert(!onlyRegulator.some((s) => s.kind.startsWith("manufacturer")));
  assert(masterHasExactHydrationReadiness({ ...old, verification_sources: onlyRegulator,
    registered_uses: [], label_reference: regulator, verification_unresolved_fields: [] }));
});

Deno.test("refresh evidence: untrusted historical manufacturer roles are not protected", () => {
  const sources = [
    { kind: "manufacturer_label", name: "Regulator", reference: regulator },
    { kind: "manufacturer_label", name: "API", reference: "https://data.gov.au/data/api/3/action/datastore_search" },
    { kind: "manufacturer_label", name: "SDS", reference: "https://cdn.nufarm.com/weedmaster-sds.pdf" },
    { kind: "manufacturer_label", name: "Reseller", reference: "https://random-reseller.com/label.pdf" },
    { ...manufacturer, reviewed_visual_declaration: { ...manufacturer.reviewed_visual_declaration, source_url: "https://cdn.nufarm.com/different.pdf" } },
  ];
  assertEquals(mergeRefreshEvidence({ ...row, verification_sources: sources }, []).map((s) => s.kind), ["regulator_label", "official_register"]);
});

Deno.test("refresh evidence: invalidation survives, rediscovery never restores rejected manufacturer evidence", () => {
  for (const tombstone of [{ invalidated: true }, { invalidated_at: NOW }, { status: "revoked" }, { review_status: "rejected" }]) {
    const rejected = { ...manufacturer, ...tombstone };
    const merged = mergeRefreshEvidence({ ...row, verification_sources: [rejected] }, [manufacturer]);
    assertEquals(merged, [rejected]);
    assertEquals(trustedRetainedManufacturerDocument(row, merged[0]), false);
    for (const links of [{}, { label_reference: manufacturer.reference }, { manufacturer_label_url: manufacturer.reference }])
      assertEquals(masterHasExactHydrationReadiness({ ...row, ...links, verification_sources: merged }), false);
  }
});

Deno.test("refresh evidence: incoming rejection dominates and a newly reviewed source can upgrade an unreviewed one", () => {
  const rejected = { ...manufacturer, invalidated: true };
  assertEquals(mergeRefreshEvidence({ ...row, verification_sources: [manufacturer] }, [rejected]), [rejected]);
  const unreviewed = { kind: "manufacturer_label", name: "Label", reference: manufacturer.reference };
  assertEquals(mergeRefreshEvidence({ ...row, verification_sources: [unreviewed] }, [manufacturer]), [manufacturer]);
});

Deno.test("candidate refresh CAS: stale evidence patch cannot erase a concurrent repair or invalidation", async () => {
  const patch = { verification_sources: [] };
  for (const responseRows of [[], [{ id: row.id }]]) {
    const result = await applyCandidateRefreshPatchAtRevision(row, patch, "https://catalogue.test/rest/v1/master_chemicals", {}, (async (input: string | URL | Request, init?: RequestInit) => {
      const url = new URL(String(input));
      assertEquals(url.searchParams.get("catalogue_version"), "eq.2");
      assertEquals(url.searchParams.get("review_status"), "eq.candidate");
      assertEquals(init?.method, "PATCH");
      assertEquals(JSON.parse(String(init?.body)), patch);
      return Response.json(responseRows);
    }) as typeof fetch);
    assertEquals(result, responseRows.length === 1);
  }
});

function lostRow(): any {
  return { ...structuredClone(row), catalogue_version: 3,
    verification_sources: row.verification_sources.filter((source: any) => source.reference !== manufacturer.reference)
      .map((source: any) => source.kind === "manufacturer_label" ? { ...source, kind: "official_register" } : source) };
}
function historyFor(current: any): any[] {
  return [{ master_chemical_id: WEEDMASTER_ID, catalogue_version: 2, snapshot: structuredClone(row) },
    { master_chemical_id: WEEDMASTER_ID, catalogue_version: 3, snapshot: structuredClone(current) }];
}

Deno.test("Weedmaster evidence repair: exact old declaration appended only, current data retained, CAS/admin-bound preview", async () => {
  const current = lostRow();
  const history = historyFor(current);
  const before = structuredClone({ current, history });
  assertEquals(masterHasExactHydrationReadiness(current), false);
  const patch = buildWeedmasterEvidenceRestorePatch(current, history, 2);
  assertEquals(Object.keys(patch), ["verification_sources"]);
  assertEquals(patch.verification_sources.slice(0, -1), current.verification_sources);
  assertEquals(patch.verification_sources.at(-1), manufacturer);
  const misclassifiedCurrent = structuredClone(current);
  misclassifiedCurrent.verification_sources.push({ kind: "manufacturer_label", name: "eLabel", reference: regulator });
  const corrected = buildWeedmasterEvidenceRestorePatch(misclassifiedCurrent, historyFor(misclassifiedCurrent), 2);
  assertEquals(corrected.verification_sources.find((source: any) => source.reference === regulator)?.kind, "regulator_label");
  assertEquals(corrected.verification_sources.at(-1), manufacturer);
  const repaired = { ...current, ...patch };
  assertEquals(repaired.registered_uses, current.registered_uses);
  assertEquals(repaired.review_status, "candidate");
  assert(masterHasExactHydrationReadiness(repaired));
  let stored: any = null;
  const preview = await storeWeedmasterEvidenceRestorePreview(current, history, 2, "current-admin", {
    insertPreview: async (payload) => { stored = payload; return { id: "preview-only", expires_at: NOW }; },
    purgeExpired: async () => {},
  });
  assertEquals(stored.base_revision, 3);
  assertEquals(stored.requested_by, "current-admin");
  assertEquals(stored.proposed_patch, patch);
  assertEquals(preview.master_mutated, false);
  assertEquals({ current, history }, before);
});

Deno.test("Weedmaster evidence repair: no rollback, invented reviewer, invalidation or incomplete/mismatched history", () => {
  const current = lostRow();
  for (const change of [{ review_status: "approved" }, { id: "other" }, { registration_number: "99999" },
    { active_ingredients: [{ name: "other", concentration: 360, concentration_unit: "g/L" }] }]) {
    assertThrows(() => buildWeedmasterEvidenceRestorePatch({ ...current, ...change }, historyFor(current), 2));
  }
  assertThrows(() => buildWeedmasterEvidenceRestorePatch(current, [], 2));
  for (const change of [{ document_sha256: "b".repeat(64) }, { document_version: "new" }, { reviewed_by: "" }]) {
    const history = historyFor(current);
    Object.assign(history[0].snapshot.verification_sources[6].reviewed_visual_declaration, change);
    assertThrows(() => buildWeedmasterEvidenceRestorePatch(current, history, 2));
  }
  const rejected = lostRow();
  rejected.verification_sources.push({ ...manufacturer, invalidated: true });
  assertThrows(() => buildWeedmasterEvidenceRestorePatch(rejected, historyFor(rejected), 2));
  const noSource = historyFor(current);
  noSource[0].snapshot.verification_sources.pop();
  assertThrows(() => buildWeedmasterEvidenceRestorePatch(current, noSource, 2));
});

Deno.test("real handler: lost evidence 503, repaired/refreshed candidate exact preview 200; explicit repair is preview-only", async (t) => {
  type Handler = (request: Request) => Promise<Response>;
  const originalServe = Deno.serve;
  const originalGet = Deno.env.get;
  const originalFetch = globalThis.fetch;
  let captured: Handler | null = null;
  let current = lostRow();
  let admin = true;
  let authenticated = true;
  let previewInserts = 0;
  const calls: string[] = [];
  const history = historyFor(current);
  try {
    Deno.env.get = (key: string) => ({ SUPABASE_URL: "https://catalogue.test",
      SUPABASE_SERVICE_ROLE_KEY: "mock-service", SUPABASE_ANON_KEY: "mock-anon" } as Record<string, string>)[key];
    Deno.serve = ((handler: Handler) => { captured = handler; return {}; }) as unknown as typeof Deno.serve;
    globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
      const url = new URL(input instanceof Request ? input.url : String(input));
      calls.push(url.pathname);
      assertEquals(url.origin, "https://catalogue.test", "no discovery, substitution or extraction");
      if (url.pathname === "/auth/v1/user") return Response.json(authenticated ? { id: "current-admin" } : {}, { status: authenticated ? 200 : 401 });
      if (url.pathname === "/rest/v1/rpc/is_system_admin") return Response.json(admin);
      if (url.pathname === "/rest/v1/master_chemical_versions") { assertEquals(init?.method ?? "GET", "GET"); return Response.json(history); }
      if (url.pathname === "/rest/v1/master_review_previews") {
        assertEquals(init?.method, "POST");
        const payload = JSON.parse(String(init?.body));
        assertEquals(payload.requested_by, "current-admin");
        assertEquals(payload.base_revision, 3);
        assertEquals(Object.keys(payload.proposed_patch), ["verification_sources"]);
        previewInserts++;
        return Response.json([{ id: "mock-preview", expires_at: NOW }]);
      }
      assertEquals(url.pathname, "/rest/v1/master_chemicals");
      assertEquals(init?.method ?? "GET", "GET", "no Master writes");
      assertEquals(url.searchParams.get("id"), `eq.${WEEDMASTER_ID}`);
      return Response.json([current]);
    }) as typeof fetch;
    await import("../index.ts");
    const handler = captured as Handler | null;
    assert(handler);
    const request = (body: any) => handler(new Request("https://function.test/chemical-info-lookup", {
      method: "POST", headers: { Authorization: "Bearer mock-admin", "content-type": "application/json" }, body: JSON.stringify(body),
    }));
    const previewBody = { action: "structured_master_preview", master_chemical_id: WEEDMASTER_ID };
    const repairBody = { action: "master_evidence_restore_preview", master_chemical_id: WEEDMASTER_ID,
      source_revision: 2, expected_current_revision: 3 };
    await t.step("current lost evidence still fails readiness with the existing 503", async () => {
      const response = await request(previewBody);
      assertEquals(response.status, 503);
      assertEquals((await response.json()).code, "catalogue_preview_unavailable");
    });
    await t.step("dry-run derives history-only patch, creates no preview or Master write", async () => {
      const response = await request(repairBody);
      assertEquals(response.status, 200);
      assertEquals((await response.json()).preview_stored, false);
      assertEquals(previewInserts, 0);
    });
    await t.step("non-admin/session, stale base and injected patches are refused", async () => {
      admin = false;
      assertEquals((await request(repairBody)).status, 403);
      assertEquals((await request(previewBody)).status, 403);
      admin = true;
      authenticated = false;
      assertEquals((await request(repairBody)).status, 401);
      authenticated = true;
      assertEquals((await request({ ...repairBody, expected_current_revision: 4 })).status, 409);
      assertEquals((await request({ ...repairBody, patch: {} })).status, 400);
      assertEquals((await request({ ...repairBody, dryRun: false })).status, 400);
    });
    await t.step("explicit confirmation stores only a review preview, does not apply", async () => {
      const response = await request({ ...repairBody, dryRun: false, confirm_accidental_evidence_loss: true });
      assertEquals(response.status, 200);
      assertEquals((await response.json()).master_mutated, false);
      assertEquals(previewInserts, 1);
      assertEquals(current, lostRow());
    });
    await t.step("after evidence-only proposed repair, canonical serving succeeds read-only", async () => {
      current = { ...current, ...buildWeedmasterEvidenceRestorePatch(current, history, 2) };
      // A subsequent regulator refresh uses the same production merge and preserves the old declaration.
      current.verification_sources = mergeRefreshEvidence(current, [{ kind: "manufacturer_label", name: "eLabel", reference: regulator }]);
      const before = structuredClone(current);
      calls.length = 0;
      const response = await request(previewBody);
      assertEquals(response.status, 200);
      const served = await response.json();
      assertEquals(served.match_source, "master");
      assertEquals(served.master.master_chemical_id, WEEDMASTER_ID);
      assertEquals(served.master.catalogue_status, "candidate");
      assertEquals([served.default_rate_options.per_hectare.length, served.default_rate_options.per_100_litres.length], [9, 8]);
      const phalaris = served.default_rate_options.per_100_litres.find((option: any) => option.rate_ids.includes("rate_v1_4efec198ead373a3286939ced245fadf"));
      assertEquals([phalaris.min_value, phalaris.max_value, phalaris.unit], [500, 1000, "mL"]);
      assertEquals(phalaris.conditions, ["Handgun"]);
      assert(phalaris.targets.includes("Phalaris"));
      assertEquals(served.label_evidence.reviewed_manufacturer_document, manufacturer);
      assertEquals(calls, ["/auth/v1/user", "/rest/v1/rpc/is_system_admin", "/rest/v1/master_chemicals"]);
      assertEquals(current, before);
    });
  } finally {
    Deno.serve = originalServe;
    Deno.env.get = originalGet;
    globalThis.fetch = originalFetch;
  }
});
