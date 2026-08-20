// Stage 5G tests — 10-product pilot batch for Stage 5F-approved AWRI matches.
//
// G01–G12 prove the pilot's safety properties STRUCTURALLY, against the real
// reviewed audit artifact: only the operator-approved allowlist can build,
// rejected aliases and non-audited names refuse, tampered artifacts refuse,
// the wire format is locked to the deployed seed_apply action, state is
// cohort-separated from the Stage 5B/5D batch, and reruns are idempotent.

import {
  assert,
  assertEquals,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  type AuditArtifact,
  buildPilotBatch,
  initialPilotState,
  parsePilotState,
  type PilotItem,
  type PilotPair,
  pilotRequestBody,
  type PilotState,
  STAGE5G_COHORT_ID,
  STAGE5G_PILOT_ALLOWLIST,
  STAGE5G_SEED_SOURCE_ID,
} from "./seed_awri_pilot.ts";
import {
  type ApplyState,
  initialApplyState,
  planPending,
  recordOutcome,
  summariseApply,
} from "./seed_awri_apply.ts";
import { SEED_SOURCES } from "./seed_apply.ts";
import { nameCorresponds } from "./apvma.ts";

const artifactUrl = new URL("./seeds/awri_dogbook_2026_27.audit.json", import.meta.url);
const REAL_ARTIFACT = JSON.parse(await Deno.readTextFile(artifactUrl)) as AuditArtifact;

const clone = (): AuditArtifact => structuredClone(REAL_ARTIFACT);

const EXPECTED_IDENTITIES = [
  "AU:apvma:53987",
  "AU:apvma:54522",
  "AU:apvma:58831",
  "AU:apvma:60560",
  "AU:apvma:63228",
  "AU:apvma:67494",
  "AU:apvma:68458",
  "AU:apvma:81077",
  "AU:apvma:83459",
  "AU:apvma:92506",
] as const;

Deno.test("G01: the pilot batch is exactly the 10 approved pairs — sorted, canonical, registered names carried from the audit", () => {
  const items = buildPilotBatch(clone());
  assertEquals(items.length, 10);
  assertEquals(items.map((i) => i.registration_identity_key), [...EXPECTED_IDENTITIES]);
  const allowNames = new Set(STAGE5G_PILOT_ALLOWLIST.map((p) => p.awri_product_name));
  for (const item of items) {
    assert(allowNames.has(item.awri_product_name), `unexpected AWRI name ${item.awri_product_name}`);
    assertEquals(item.registration_identity_key, `AU:apvma:${item.registration_number}`);
    assertEquals(item.pre_verified_review_status, null);
    assert(item.send_product_name.trim().length > 0);
    assertEquals(item.send_product_name, item.registered_product_name);
  }
  const conan = items.find((i) => i.registration_number === "68458");
  assertEquals(conan?.awri_product_name, "Conan Sticks 720SC");
  assertEquals(conan?.send_product_name, "CONAN STICKS 720 SC FUNGICIDE");
});

Deno.test("G02: structural exclusion — 179 approved in the audit, but ONLY the allowlisted 10 enter; rejected/duplicate identities never appear", () => {
  const approved = REAL_ARTIFACT.items.filter((i) => i.decision === "approve_for_seed");
  assertEquals(approved.length, 179);
  const items = buildPilotBatch(clone());
  assertEquals(items.length, 10);
  const allowNumbers = new Set(STAGE5G_PILOT_ALLOWLIST.map((p) => p.registration_number));
  for (const item of items) {
    assert(allowNumbers.has(item.registration_number));
  }
  // The duplicate-alias identities (kept under their stronger names in the
  // audit) are approved but NOT allowlisted — they must not leak in.
  for (const identity of ["AU:apvma:87040", "AU:apvma:63727"]) {
    assert(!items.some((i) => i.registration_identity_key === identity));
  }
});

Deno.test("G03: a rejected duplicate alias in the allowlist refuses to build — both Stage 5F rejections stay out", () => {
  for (const pair of [
    { awri_product_name: "Dry GLY 680", registration_number: "87040" },
    { awri_product_name: "Top Wettable Sulphur", registration_number: "63727" },
  ]) {
    assertThrows(
      () => buildPilotBatch(clone(), [pair]),
      Error,
      "NOT approved",
    );
  }
});

Deno.test("G04: names outside the deterministic audit refuse — probable, no-match and invented names are structurally absent", () => {
  for (const name of ["BioPest", "Amitrole 47T", "Nofactor 500"]) {
    assertThrows(
      () => buildPilotBatch(clone(), [{ awri_product_name: name, registration_number: "12345" }]),
      Error,
      "not in the Stage 5F audit",
    );
  }
});

Deno.test("G05: an allowlist number that disagrees with the audited registration refuses", () => {
  assertThrows(
    () =>
      buildPilotBatch(clone(), [
        { awri_product_name: "Conan Sticks 720SC", registration_number: "99999" },
      ]),
    Error,
    "audited as APVMA 68458",
  );
});

Deno.test("G06: tampered audit items refuse — decision, currency, checks and tier are all re-demanded", () => {
  const flip = (mutate: (item: AuditArtifact["items"][number]) => void, message: string) => {
    const tampered = clone();
    const item = tampered.items.find((i) => i.awri_product_name === "Conan Sticks 720SC");
    assert(item);
    mutate(item);
    assertThrows(() => buildPilotBatch(tampered), Error, message);
  };
  flip((i) => {
    i.decision = "reject";
  }, "NOT approved");
  flip((i) => {
    i.registration_status.classification = "lapsed_before_extract";
  }, "not current_in_extract");
  flip((i) => {
    i.checks[Object.keys(i.checks)[0]] = false;
  }, "failed audit check");
  flip((i) => {
    i.matching_tier = "probable_manual_review";
  }, "non-deterministic tier");
  flip((i) => {
    i.registration_identity_key = "AU:apvma:00001";
  }, "not canonical");
});

Deno.test("G07: the artifact must be THE approved Stage 5F audit — wrong stage, drifted counts or truncated items refuse", () => {
  const wrongStage = clone();
  wrongStage.stage = "5E — match classification";
  assertThrows(() => buildPilotBatch(wrongStage), Error, "not a Stage 5F audit");

  const wrongCount = clone();
  wrongCount.counts.total_audited = 180;
  assertThrows(() => buildPilotBatch(wrongCount), Error, "counts.total_audited");

  const collision = clone();
  collision.counts.master_collisions = 1;
  assertThrows(() => buildPilotBatch(collision), Error, "counts.master_collisions");

  const truncated = clone();
  truncated.items = truncated.items.slice(0, 180);
  assertThrows(() => buildPilotBatch(truncated), Error, "180 items");
});

Deno.test("G08: allowlist hygiene — duplicates, empties and malformed numbers refuse", () => {
  const conan: PilotPair = { awri_product_name: "Conan Sticks 720SC", registration_number: "68458" };
  assertThrows(() => buildPilotBatch(clone(), []), Error, "empty allowlist");
  assertThrows(() => buildPilotBatch(clone(), [conan, { ...conan }]), Error, "duplicate AWRI name");
  assertThrows(
    () =>
      buildPilotBatch(clone(), [
        conan,
        { awri_product_name: "Hammer 400 EC", registration_number: "68458" },
      ]),
    Error,
    "duplicate registration number",
  );
  assertThrows(
    () => buildPilotBatch(clone(), [{ awri_product_name: "Conan Sticks 720SC", registration_number: "12" }]),
    Error,
    "not 3-8 digits",
  );
  assertThrows(
    () => buildPilotBatch(clone(), [{ awri_product_name: "  ", registration_number: "68458" }]),
    Error,
    "empty AWRI product name",
  );
});

Deno.test("G09: wire format is locked to the deployed seed_apply action — registered name out, whitelisted seed source, nothing else", () => {
  assert(SEED_SOURCES[STAGE5G_SEED_SOURCE_ID], "seed source must be on the server whitelist");
  const items = buildPilotBatch(clone());
  for (const item of items) {
    const body = pilotRequestBody(item);
    assertEquals(body, {
      action: "seed_apply",
      registrationNumber: item.registration_number,
      productName: item.send_product_name,
      seedSource: "awri_dogbook_2026_27",
    });
    assertEquals(Object.keys(body).length, 4);
  }
  const broken: PilotItem = { ...items[0], send_product_name: "  " };
  assertThrows(() => pilotRequestBody(broken), Error, "no send_product_name");
});

Deno.test("G10: WHY the registered name is sent — the audited registered name is GUARANTEED to verify (exact self-match); booklet names are not, even under the upgraded typography matcher", () => {
  const items = buildPilotBatch(clone());
  let bookletCorresponds = 0;
  for (const item of items) {
    assertEquals(
      nameCorresponds(item.send_product_name, item.send_product_name),
      true,
      `${item.send_product_name} must exact-match itself`,
    );
    if (nameCorresponds(item.awri_product_name, item.send_product_name)) {
      bookletCorresponds += 1;
    }
  }
  // The general resolver upgrade (matching.ts) added pure-typography tiers,
  // so booklet names like "Penncozeb 750DF" now correspond to their
  // registered names ("… 750 DF …") — but registrant-prefix booklet names
  // still cannot. The registered name remains the only wire choice that
  // verifies for EVERY item, which is why Stage 5G/5H send it.
  assert(
    bookletCorresponds < items.length,
    "at least one booklet name still requires the registered name on the wire",
  );
});

Deno.test("G11: cohort-separated state — the Stage 5B/5D batch state, other cohorts and malformed files all refuse", () => {
  const fresh = initialPilotState("2026-08-20T00:00:00.000Z");
  assertEquals(fresh.cohort, STAGE5G_COHORT_ID);
  assertEquals(fresh.seed_source_id, STAGE5G_SEED_SOURCE_ID);
  assertEquals(fresh.records, {});
  assertEquals(parsePilotState(JSON.stringify(fresh)), fresh);

  // Stage 5B/5D state shape: no cohort tag.
  const stage5b = initialApplyState("awri_dogbook_2026_27", "2026-08-20T00:00:00.000Z");
  assertThrows(() => parsePilotState(JSON.stringify(stage5b)), Error, "cohort");

  assertThrows(
    () => parsePilotState(JSON.stringify({ ...fresh, cohort: "stage5h_full_batch" })),
    Error,
    "another cohort",
  );
  assertThrows(
    () => parsePilotState(JSON.stringify({ ...fresh, seed_source_id: "other_source" })),
    Error,
    "seed source",
  );
  assertThrows(() => parsePilotState(JSON.stringify({ ...fresh, records: [] })), Error, "records");
  assertThrows(() => parsePilotState("not json"), Error, "not valid JSON");
});

Deno.test("G12: resumable + idempotent + pure — terminal outcomes never re-send, failures retry, cohort survives state updates, artifact never mutated", () => {
  const before = JSON.stringify(REAL_ARTIFACT);
  const a = buildPilotBatch(clone());
  const b = buildPilotBatch(clone());
  assertEquals(JSON.stringify(a), JSON.stringify(b));
  assertEquals(JSON.stringify(REAL_ARTIFACT), before, "artifact must not be mutated");

  let state: ApplyState = initialPilotState("2026-08-20T00:00:00.000Z");
  assertEquals(planPending(a, state).length, 10);

  for (const item of a) {
    state = recordOutcome(state, item.registration_identity_key, "created", "candidate created", "2026-08-20T00:01:00.000Z");
  }
  assertEquals(planPending(a, state).length, 0, "terminal outcomes are never re-sent");
  assertEquals((state as PilotState).cohort, STAGE5G_COHORT_ID, "cohort tag survives every state update");
  const done = summariseApply(a, state);
  assertEquals(done.created, 10);
  assertEquals(done.pending, 0);

  state = recordOutcome(state, a[0].registration_identity_key, "failed", "transport error", "2026-08-20T00:02:00.000Z");
  const retry = planPending(a, state);
  assertEquals(retry.length, 1, "only failed items retry");
  assertEquals(retry[0].registration_identity_key, a[0].registration_identity_key);
});
