// Stage 5H tests — the remaining 169 Stage 5F-approved AWRI matches
// (179 approved − the 10 completed and production-verified in Stage 5G).
//
// H01–H08 prove the batch's safety properties STRUCTURALLY, against the real
// reviewed audit artifact: the batch is derived (never hand-listed), exactly
// disjoint from the Stage 5G pilot, rejected aliases and non-deterministic
// names stay out, tampered artifacts refuse, the wire format is locked to the
// deployed seed_apply action, state is cohort-separated from BOTH earlier
// state files, and reruns are idempotent.

import {
  assert,
  assertEquals,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  type AuditArtifact,
  buildStage5hBatch,
  initialStage5hState,
  parseStage5hState,
  STAGE5H_BATCH_SIZE,
  STAGE5H_COHORT_ID,
  STAGE5H_SEED_SOURCE_ID,
  type Stage5hItem,
  stage5hRequestBody,
  type Stage5hState,
} from "./seed_awri_stage5h.ts";
import {
  initialPilotState,
  STAGE5G_PILOT_ALLOWLIST,
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

const PILOT_NAMES = new Set(STAGE5G_PILOT_ALLOWLIST.map((p) => p.awri_product_name));
const PILOT_IDENTITIES = new Set(
  STAGE5G_PILOT_ALLOWLIST.map((p) => `AU:apvma:${p.registration_number}`),
);

Deno.test("H01: the batch is DERIVED — exactly 169, sorted, disjoint from the pilot, and pilot ∪ batch = all 179 approved identities", () => {
  const items = buildStage5hBatch(clone());
  assertEquals(items.length, STAGE5H_BATCH_SIZE);
  assertEquals(items.length, 169);

  const nums = items.map((i) => Number.parseInt(i.registration_number, 10));
  for (let i = 1; i < nums.length; i++) {
    assert(nums[i - 1] < nums[i], "batch must be sorted strictly ascending by registration number");
  }

  const approvedIds = new Set(
    REAL_ARTIFACT.items
      .filter((i) => i.decision === "approve_for_seed")
      .map((i) => i.registration_identity_key),
  );
  assertEquals(approvedIds.size, 179);

  const batchIds = new Set(items.map((i) => i.registration_identity_key));
  assertEquals(batchIds.size, 169);
  for (const id of batchIds) {
    assert(!PILOT_IDENTITIES.has(id), `pilot identity ${id} leaked into Stage 5H`);
    assert(approvedIds.has(id), `${id} is not an approved audit identity`);
  }
  const union = new Set([...PILOT_IDENTITIES, ...batchIds]);
  assertEquals(union.size, 179, "pilot + batch must cover every approved identity exactly");

  for (const item of items) {
    assertEquals(item.registration_identity_key, `AU:apvma:${item.registration_number}`);
    assertEquals(item.pre_verified_review_status, null);
    assertEquals(item.send_product_name, item.registered_product_name);
    assert(item.send_product_name.trim().length > 0);
    assert(!PILOT_NAMES.has(item.awri_product_name), `pilot name ${item.awri_product_name} leaked in`);
  }
});

Deno.test("H02: the 2 rejected duplicate aliases never enter; their identities appear exactly once, under the stronger audited names", () => {
  const items = buildStage5hBatch(clone());
  const names = new Set(items.map((i) => i.awri_product_name));
  assert(!names.has("Dry GLY 680"), "rejected alias Dry GLY 680 must not enter");
  assert(!names.has("Top Wettable Sulphur"), "rejected alias Top Wettable Sulphur must not enter");
  for (const identity of ["AU:apvma:87040", "AU:apvma:63727"]) {
    const hits = items.filter((i) => i.registration_identity_key === identity);
    assertEquals(hits.length, 1, `${identity} must appear exactly once (stronger-name item)`);
    assert(
      hits[0].awri_product_name !== "Dry GLY 680" && hits[0].awri_product_name !== "Top Wettable Sulphur",
      "identity must be carried by the approved stronger name",
    );
  }
  // Probable/ambiguous/no-match names are structurally absent: the artifact
  // holds only the 181 deterministic matches.
  assertEquals(REAL_ARTIFACT.items.length, 181);
});

Deno.test("H03: tampered audit items refuse — decision, currency, checks, tier and identity are all re-demanded", () => {
  const pickTarget = (artifact: AuditArtifact) => {
    const target = artifact.items.find(
      (i) => i.decision === "approve_for_seed" && !PILOT_NAMES.has(i.awri_product_name),
    );
    assert(target, "artifact must contain a non-pilot approved item");
    return target;
  };
  const flip = (mutate: (item: AuditArtifact["items"][number]) => void, message: string) => {
    const tampered = clone();
    mutate(pickTarget(tampered));
    assertThrows(() => buildStage5hBatch(tampered), Error, message);
  };
  flip((i) => {
    i.decision = "reject";
  }, "rejected items");
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

Deno.test("H04: the artifact must be THE approved Stage 5F audit — wrong stage, drifted counts or truncated items refuse", () => {
  const wrongStage = clone();
  wrongStage.stage = "5E — match classification";
  assertThrows(() => buildStage5hBatch(wrongStage), Error, "not a Stage 5F audit");

  const wrongCount = clone();
  wrongCount.counts.total_audited = 180;
  assertThrows(() => buildStage5hBatch(wrongCount), Error, "counts.total_audited");

  const collision = clone();
  collision.counts.master_collisions = 1;
  assertThrows(() => buildStage5hBatch(collision), Error, "counts.master_collisions");

  const truncated = clone();
  truncated.items = truncated.items.slice(0, 180);
  assertThrows(() => buildStage5hBatch(truncated), Error, "180 items");
});

Deno.test("H05: exclusion integrity — the completed Stage 5G cohort must reconcile name-and-number against the audit, all 10 of it", () => {
  assertEquals(STAGE5G_PILOT_ALLOWLIST.length, 10, "the completed pilot cohort is exactly 10 pairs");

  // A pilot-named item whose audited number disagrees with what Stage 5G applied.
  const renumbered = clone();
  const conan = renumbered.items.find((i) => i.awri_product_name === "Conan Sticks 720SC");
  assert(conan);
  conan.apvma_registration_number = "99999";
  assertThrows(() => buildStage5hBatch(renumbered), Error, "Stage 5G completed it as");

  // A renamed pilot item still carrying the pilot identity must not re-enter.
  const renamed = clone();
  const conan2 = renamed.items.find((i) => i.awri_product_name === "Conan Sticks 720SC");
  assert(conan2);
  conan2.awri_product_name = "Conan Sticks 720SC RENAMED";
  assertThrows(() => buildStage5hBatch(renamed), Error, "belongs to the completed Stage 5G pilot");

  // A pilot item renamed AND renumbered leaves an exclusion unmatched — refuse.
  const vanished = clone();
  const conan3 = vanished.items.find((i) => i.awri_product_name === "Conan Sticks 720SC");
  assert(conan3);
  conan3.awri_product_name = "Conan Sticks 720SC RENAMED";
  conan3.apvma_registration_number = "12345";
  conan3.registration_identity_key = "AU:apvma:12345";
  assertThrows(() => buildStage5hBatch(vanished), Error, "matched 9 of 10");

  // The exclusion list itself is pinned to 10 entries.
  assertThrows(() => buildStage5hBatch(clone(), []), Error, "exactly 10 Stage 5G exclusions");
});

Deno.test("H06: wire format is locked to the deployed seed_apply action — audited registered name out, whitelisted seed source, nothing else", () => {
  assert(SEED_SOURCES[STAGE5H_SEED_SOURCE_ID], "seed source must be on the server whitelist");
  const items = buildStage5hBatch(clone());
  for (const item of items) {
    const body = stage5hRequestBody(item);
    assertEquals(body, {
      action: "seed_apply",
      registrationNumber: item.registration_number,
      productName: item.send_product_name,
      seedSource: "awri_dogbook_2026_27",
    });
    assertEquals(Object.keys(body).length, 4);
    assertEquals(
      nameCorresponds(item.send_product_name, item.send_product_name),
      true,
      `${item.send_product_name} must exact-match itself under deployed live re-verification`,
    );
  }
  const broken: Stage5hItem = { ...items[0], send_product_name: "  " };
  assertThrows(() => stage5hRequestBody(broken), Error, "no send_product_name");
});

Deno.test("H07: cohort-separated state — the Stage 5B/5D batch state, the Stage 5G pilot state, other cohorts and malformed files all refuse", () => {
  const fresh = initialStage5hState("2026-08-20T00:00:00.000Z");
  assertEquals(fresh.cohort, STAGE5H_COHORT_ID);
  assertEquals(fresh.seed_source_id, STAGE5H_SEED_SOURCE_ID);
  assertEquals(fresh.records, {});
  assertEquals(parseStage5hState(JSON.stringify(fresh)), fresh);

  // Stage 5B/5D state shape: no cohort tag.
  const stage5b = initialApplyState("awri_dogbook_2026_27", "2026-08-20T00:00:00.000Z");
  assertThrows(() => parseStage5hState(JSON.stringify(stage5b)), Error, "cohort");

  // The completed Stage 5G pilot's state: different cohort tag.
  const pilotState = initialPilotState("2026-08-20T00:00:00.000Z");
  assertThrows(() => parseStage5hState(JSON.stringify(pilotState)), Error, "another cohort");

  assertThrows(
    () => parseStage5hState(JSON.stringify({ ...fresh, cohort: "stage5i_future" })),
    Error,
    "another cohort",
  );
  assertThrows(
    () => parseStage5hState(JSON.stringify({ ...fresh, seed_source_id: "other_source" })),
    Error,
    "seed source",
  );
  assertThrows(() => parseStage5hState(JSON.stringify({ ...fresh, records: [] })), Error, "records");
  assertThrows(() => parseStage5hState("not json"), Error, "not valid JSON");
});

Deno.test("H08: resumable + idempotent + pure — terminal outcomes never re-send, failures retry, cohort survives state updates, artifact never mutated", () => {
  const before = JSON.stringify(REAL_ARTIFACT);
  const a = buildStage5hBatch(clone());
  const b = buildStage5hBatch(clone());
  assertEquals(JSON.stringify(a), JSON.stringify(b), "batch build must be deterministic");
  assertEquals(JSON.stringify(REAL_ARTIFACT), before, "artifact must not be mutated");

  let state: ApplyState = initialStage5hState("2026-08-20T00:00:00.000Z");
  assertEquals(planPending(a, state).length, 169);

  for (const item of a) {
    state = recordOutcome(state, item.registration_identity_key, "created", "candidate created", "2026-08-20T00:01:00.000Z");
  }
  assertEquals(planPending(a, state).length, 0, "terminal outcomes are never re-sent");
  assertEquals((state as Stage5hState).cohort, STAGE5H_COHORT_ID, "cohort tag survives every state update");
  const done = summariseApply(a, state);
  assertEquals(done.created, 169);
  assertEquals(done.pending, 0);

  state = recordOutcome(state, a[0].registration_identity_key, "failed", "transport error", "2026-08-20T00:02:00.000Z");
  const retry = planPending(a, state);
  assertEquals(retry.length, 1, "only failed items retry");
  assertEquals(retry[0].registration_identity_key, a[0].registration_identity_key);

  state = recordOutcome(state, a[0].registration_identity_key, "already_exists", "skipped unchanged", "2026-08-20T00:03:00.000Z");
  assertEquals(planPending(a, state).length, 0, "already_exists is terminal — the rerun check converges to zero sends");
});
