// Jonathan only, separate from Master apply. Usage:
// deno run --allow-env --allow-net --allow-read --allow-run=magick scripts/stage-weedmaster-media.ts MANIFEST PDF COVER_PNG
// Requires V2_SUPABASE_URL, EXPO_PUBLIC_SUPABASE_ANON_KEY, VINETRACK_ADMIN_ACCESS_TOKEN.
import { inspectStoredReview, type ReviewApi, type StoredReviewManifest, type StoredReviewPreview } from "./master-stored-review.ts";
import type { MasterRow } from "../supabase/functions/chemical-info-lookup/ingestion/contract.ts";

const digest = async (data: Uint8Array): Promise<string> => Array.from(
  new Uint8Array(await crypto.subtle.digest("SHA-256", data.buffer as ArrayBuffer)),
  (byte) => byte.toString(16).padStart(2, "0")).join("");

export function reviewedCover(patch: Record<string, unknown>, hash: string): Record<string, unknown> | null {
  const sources = patch.verification_sources;
  if (!Array.isArray(sources)) return null;
  const matches = sources.map((s) => s?.reviewed_visual_declaration)
    .filter((d) => d?.document_sha256 === hash);
  return matches.length === 1 ? matches[0] as Record<string, unknown> : null;
}

/** Versioned paths are independent of vineyard and never contain a local path or signed URL. */
export function mediaVersionPaths(id: string, hash: string, page: number): [string, string, string] {
  if (!/^[a-f0-9-]{36}$/.test(id) || !/^[a-f0-9]{64}$/.test(hash) || !Number.isSafeInteger(page) || page < 1)
    throw new Error("Invalid Master/document/page identity");
  const base = `${id}/${hash}/`;
  return [`${base}label.pdf`, `${base}front-p${page}.png`, `${base}thumb-p${page}.webp`];
}

async function main(): Promise<void> {
  if (Deno.args.length !== 3 || !Deno.stdin.isTerminal()) throw new Error("Interactive admin required: MANIFEST PDF COVER_PNG");
  const [manifestFile, pdfFile, coverFile] = Deno.args;
  const manifest = JSON.parse(await Deno.readTextFile(manifestFile)) as StoredReviewManifest;
  const url = (Deno.env.get("V2_SUPABASE_URL") ?? "").replace(/\/$/, "");
  const anon = Deno.env.get("EXPO_PUBLIC_SUPABASE_ANON_KEY") ?? "";
  const token = Deno.env.get("VINETRACK_ADMIN_ACCESS_TOKEN") ?? "";
  if (!url || !anon || !token) throw new Error("Admin credentials required");
  const headers = { apikey: anon, Authorization: `Bearer ${token}` };
  async function json(path: string, body?: object): Promise<any> {
    const r = await fetch(`${url}${path}`, { method: body ? "POST" : "GET", headers: {
      ...headers, "Content-Type": "application/json" }, ...(body ? { body: JSON.stringify(body) } : {}) });
    if (!r.ok) throw new Error(`HTTP ${r.status}: ${path.split("?")[0]}`);
    return await r.json();
  }
  if (await json("/rest/v1/rpc/is_system_admin", {}) !== true) throw new Error("System Admin required");
  const api: ReviewApi = {
    currentUser: async () => (await json("/auth/v1/user")).id ?? "",
    master: async (id) => {
      const rows = await json(`/rest/v1/master_chemicals?select=*&id=eq.${id}&limit=1`) as MasterRow[];
      if (rows.length !== 1) throw new Error("Master identity missing");
      return rows[0];
    },
    stored: async (id) => {
      const rows = await json(`/rest/v1/master_review_previews?select=*&id=eq.${id}&limit=1`) as StoredReviewPreview[];
      if (rows.length !== 1) throw new Error("Stored preview missing");
      return rows[0];
    },
    prepare: async () => { throw new Error("Preparation forbidden in media staging"); },
    apply: async () => { throw new Error("Master apply forbidden in media staging"); },
  };
  const inspected = await inspectStoredReview(api, manifest);
  if (!inspected.pending || manifest.registration_identity_key !== "AU:apvma:53576")
    throw new Error("Pending Weedmaster preview or exact registration identity required");
  const pdf = await Deno.readFile(pdfFile);
  const cover = await Deno.readFile(coverFile);
  const hash = await digest(pdf);
  const declaration = reviewedCover(inspected.patch, hash);
  if (!declaration) throw new Error("Exact PDF hash has no unique reviewed cover in stored preview");
  const admin = await api.currentUser();
  if (hash !== declaration.document_sha256 || declaration.reviewed_by !== admin ||
    !Number.isInteger(declaration.physical_page) || Number(declaration.physical_page) < 1 ||
    typeof declaration.source_url !== "string" || !declaration.source_url.startsWith("https://") ||
    cover.length < 100 || ![137, 80, 78, 71, 13, 10, 26, 10].every((b, i) => cover[i] === b))
    throw new Error("Cover, PDF hash, page or authenticated preview reviewer mismatch");
  const page = Number(declaration.physical_page);
  console.log(JSON.stringify({ master_chemical_id: manifest.master_chemical_id,
    registration_identity_key: manifest.registration_identity_key, document_sha256: hash,
    source_url: declaration.source_url, document_version: declaration.document_version,
    physical_page: page, full_image: coverFile, pdf: pdfFile, preview_id: manifest.preview_id }, null, 2));
  if (prompt(`Open ${coverFile} and PDF physical page ${page}. Type RETAIN FRONT ${hash} only if the PNG is the actual confirmed front page:`) !== `RETAIN FRONT ${hash}`)
    throw new Error("Front image not confirmed; no upload");
  const command = new Deno.Command("magick", { args: ["png:-", "-auto-orient", "-thumbnail", "256x256>", "-strip", "webp:-"],
    stdin: "piped", stdout: "piped", stderr: "piped" }).spawn();
  const writer = command.stdin.getWriter();
  await writer.write(cover); await writer.close();
  const output = await command.output();
  if (!output.success || !output.stdout.length) throw new Error("Thumbnail generation failed; nothing uploaded");
  const [pdfPath, fullPath, thumbPath] = mediaVersionPaths(manifest.master_chemical_id, hash, page);
  for (const [path, bytes, type] of [
    [pdfPath, pdf, "application/pdf"],
    [fullPath, cover, "image/png"],
    [thumbPath, output.stdout, "image/webp"],
  ] as const) {
    const object = `${url}/storage/v1/object/master-chemical-media/${path}`;
    const existing = await fetch(object, { headers });
    if (existing.ok) {
      if (await digest(new Uint8Array(await existing.arrayBuffer())) !== await digest(bytes))
        throw new Error(`Existing immutable object differs: ${path}`);
      continue;
    }
    if (existing.status !== 404) throw new Error(`Object verification failed: HTTP ${existing.status}`);
    const uploaded = await fetch(object, { method: "POST", headers: { ...headers, "Content-Type": type, "x-upsert": "false" }, body: bytes });
    if (!uploaded.ok) throw new Error(`Object upload failed: HTTP ${uploaded.status}; inspect immutable objects before retry`);
  }
  const id = await json("/rest/v1/rpc/stage_master_chemical_media", {
    p_master_id: manifest.master_chemical_id, p_preview_id: manifest.preview_id,
    p_patch_sha256: manifest.proposed_patch_sha256, p_document_sha256: hash,
    p_source_url: declaration.source_url, p_document_version: declaration.document_version ?? null,
    p_physical_page: page,
  });
  console.log(`Pending media ${id}; Master unchanged. Media approval is separate and was NOT performed.`);
}

if (import.meta.main) main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : "Media staging failed");
  Deno.exitCode = 1;
});
