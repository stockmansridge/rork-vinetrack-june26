// Herbicide classification v2 — current numeric groups + legacy equivalence.
//
// # What this pins
//
// Australia replaced the alphabetical herbicide mode-of-action codes with the
// globally aligned NUMERIC system. Labels began carrying numbers in 2022 and
// the transition completed in 2024, so the code a grower reads on a current
// Australian herbicide label is "Group 14", not "Group E" and not "Group G".
//
// The table held the OLD global HRAC letters, which produced a FALSE CONFLICT
// on every herbicide: the label and the lookup said the same thing in two
// different alphabets and the app reported them as sources that disagreed.
// A false alarm about a resistance group is the most expensive kind of wrong
// answer this app can give.
//
// The tests are written against the RULE, not against one product: any
// herbicide in the table must classify numerically, agree with both of its
// legacy alphabets, and still conflict with a genuinely different group.

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  ACTIVITY_GROUP_TABLE,
  ACTIVITY_GROUP_TABLE_VERSION,
  authoritativeGroup,
  groupsAreEquivalent,
  legacyGroupCodes,
  reconcileGroup,
} from "./activity_groups.ts";

Deno.test("v2: the reference table version is bumped so a re-verification can tell which revision judged a product", () => {
  assertEquals(ACTIVITY_GROUP_TABLE_VERSION, 2);
});

// ---------------------------------------------------------------------------
// The rule, applied to every herbicide in the table
// ---------------------------------------------------------------------------

Deno.test("v2: EVERY herbicide classifies to a CURRENT numeric group — no letters survive", () => {
  const herbicides = Object.entries(ACTIVITY_GROUP_TABLE)
    .filter(([, group]) => group.scheme === "hrac");

  assert(herbicides.length > 0, "the table must still classify herbicides");
  for (const [active, group] of herbicides) {
    assert(
      /^\d+$/.test(group.code),
      `${active} still carries a legacy alphabetical code "${group.code}" — ` +
        "current Australian labels print numbers",
    );
  }
});

Deno.test("v2: every herbicide agrees with each of its own legacy codes, and none is served as the answer", () => {
  for (const [active, group] of Object.entries(ACTIVITY_GROUP_TABLE)) {
    if (group.scheme !== "hrac") continue;
    const legacy = legacyGroupCodes(active);
    assert(legacy.length > 0, `${active} records no legacy code to reconcile against`);

    for (const code of legacy) {
      const outcome = reconcileGroup(active, { scheme: "hrac", code });
      assertEquals(
        outcome.conflict,
        null,
        `${active}: legacy code "${code}" must not read as a source disagreement`,
      );
      // The CURRENT group is what a grower sees — never the historical code.
      assertEquals(
        outcome.group?.code,
        group.code,
        `${active}: the current numeric group must be served, not the legacy code`,
      );
    }
  }
});

Deno.test("v2: the current value agrees with itself, however the source decorates it", () => {
  for (const [active, group] of Object.entries(ACTIVITY_GROUP_TABLE)) {
    if (group.scheme !== "hrac") continue;
    for (const written of [group.code, `Group ${group.code}`, `${group.code} (whatever)`]) {
      const outcome = reconcileGroup(active, { scheme: "hrac", code: written });
      assertEquals(
        outcome.conflict,
        null,
        `${active}: "${written}" is the current group written differently, not a conflict`,
      );
    }
  }
});

Deno.test("v2: a GENUINELY different group still conflicts — the check is not simply switched off", () => {
  for (const [active, group] of Object.entries(ACTIVITY_GROUP_TABLE)) {
    if (group.scheme !== "hrac") continue;
    // A group this active was never classified under, current or legacy.
    const wrong = group.code === "2" ? "9" : "2";
    if (legacyGroupCodes(active).includes(wrong)) continue;

    const outcome = reconcileGroup(active, { scheme: "hrac", code: wrong });
    assert(
      outcome.conflict !== null,
      `${active}: group ${wrong} is a real disagreement and must be reported`,
    );
    assertEquals(
      outcome.group?.code,
      group.code,
      "the authoritative group is served even while the conflict stands",
    );
  }
});

// ---------------------------------------------------------------------------
// The specific shape of the reported regression (as a RULE, not a product)
// ---------------------------------------------------------------------------

Deno.test("v2: a PPO inhibitor is Group 14, and its legacy 'E' and 'G' codes raise no conflict", () => {
  // The two legacy alphabets disagree with each other about the letter: "E"
  // was PPO globally, "G" was PPO in Australia. Both mean Group 14, and this
  // is exactly why equivalence is decided per ACTIVE rather than per letter.
  const ppoActives = Object.entries(ACTIVITY_GROUP_TABLE)
    .filter(([, g]) => g.scheme === "hrac" && g.code === "14")
    .map(([name]) => name);

  assert(ppoActives.length > 0, "the table must classify PPO inhibitors");
  for (const active of ppoActives) {
    assertEquals(authoritativeGroup(active)?.code, "14");
    for (const legacy of ["E", "G", "Group E", "HRAC E"]) {
      assertEquals(
        reconcileGroup(active, { scheme: "hrac", code: legacy }).conflict,
        null,
        `${active}: legacy "${legacy}" must not create a Group 14-versus-letter conflict`,
      );
    }
  }
});

Deno.test("v2: legacy letters are NOT decodable across actives — equivalence never leaks between chemistries", () => {
  // "E" is a legacy code for flumioxazin (PPO / 14). It is NOT a legacy code
  // for an ALS inhibitor, so offering it there is still a real disagreement.
  // A per-LETTER mapping would silently accept it; a per-ACTIVE one cannot.
  const als = Object.entries(ACTIVITY_GROUP_TABLE)
    .find(([, g]) => g.scheme === "hrac" && g.code === "2")?.[0];
  assert(als, "the table must classify an ALS inhibitor");

  assert(
    !legacyGroupCodes(als).includes("E"),
    "an ALS inhibitor must not inherit a PPO inhibitor's legacy letter",
  );
  assert(
    reconcileGroup(als, { scheme: "hrac", code: "E" }).conflict !== null,
    "a legacy letter belonging to another chemistry is a genuine conflict",
  );
});

// ---------------------------------------------------------------------------
// Schemes that were never realigned must be untouched
// ---------------------------------------------------------------------------

Deno.test("v2: FRAC and IRAC classifications are unchanged and carry no invented legacy mapping", () => {
  for (const [active, group] of Object.entries(ACTIVITY_GROUP_TABLE)) {
    if (group.scheme === "hrac") continue;
    assertEquals(
      legacyGroupCodes(active),
      [],
      `${active}: only herbicides were realigned — no legacy codes may be invented`,
    );
    assertEquals(
      reconcileGroup(active, { scheme: group.scheme, code: group.code }).conflict,
      null,
    );
  }
});

Deno.test("v2: equivalence requires the SAME scheme — FRAC 3 is not HRAC 3", () => {
  assert(
    !groupsAreEquivalent(
      "flumioxazin",
      { scheme: "hrac", code: "14" },
      { scheme: "frac", code: "14" },
    ),
    "a bare number is meaningless without its scheme",
  );
});

// ---------------------------------------------------------------------------
// Salt / ester forms
// ---------------------------------------------------------------------------

Deno.test("v2: a formulation suffix inherits both the current group and its legacy codes", () => {
  assertEquals(authoritativeGroup("Glyphosate isopropylamine salt")?.code, "9");
  assert(
    legacyGroupCodes("Glyphosate isopropylamine salt").includes("G"),
    "a salt form must reconcile against its parent's legacy codes too",
  );
  assertEquals(
    reconcileGroup("Glyphosate isopropylamine salt", { scheme: "hrac", code: "M" }).conflict,
    null,
    "the old Australian letter for glyphosate is not a disagreement",
  );
});
