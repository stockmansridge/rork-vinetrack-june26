import { assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { mediaVersionPaths, reviewedCover } from "./stage-weedmaster-media.ts";

const id = "a0000000-0000-4000-8000-000000000001";
const anotherId = "b0000000-0000-4000-8000-000000000002";
const hash = "a".repeat(64);
const newerHash = "b".repeat(64);

Deno.test("the same Master and document reuse the exact three versioned paths across vineyards", () => {
  const first = mediaVersionPaths(id, hash, 1);
  assertEquals(first, mediaVersionPaths(id, hash, 1));
  assertEquals(first, [`${id}/${hash}/label.pdf`, `${id}/${hash}/front-p1.png`, `${id}/${hash}/thumb-p1.webp`]);
  assertEquals(first.some((path) => path.includes("vineyard")), false);
});

Deno.test("different chemical, hash or reviewed page never reuses a front label path", () => {
  const original = mediaVersionPaths(id, hash, 1);
  for (const other of [mediaVersionPaths(anotherId, hash, 1), mediaVersionPaths(id, newerHash, 1), mediaVersionPaths(id, hash, 2)]) {
    assertEquals(other[2] === original[2], false);
  }
  assertThrows(() => mediaVersionPaths(id, hash, 0));
  assertThrows(() => mediaVersionPaths(id, "wrong", 1));
});

Deno.test("only a unique hash-matched stored declaration can select the cover", () => {
  const declaration = { document_sha256: hash, physical_page: 2 };
  const patch = { verification_sources: [{ reviewed_visual_declaration: declaration }] };
  assertEquals(reviewedCover(patch, hash), declaration);
  assertEquals(reviewedCover(patch, newerHash), null);
  assertEquals(reviewedCover({ verification_sources: [...patch.verification_sources, ...patch.verification_sources] }, hash), null);
  assertEquals(reviewedCover({ verification_sources: [] }, hash), null);
});
