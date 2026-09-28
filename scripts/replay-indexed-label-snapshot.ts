// Offline only: run with --allow-read=PATH, never --allow-net. No approval or write path.
import { replayIndexedLabelSnapshot } from "../supabase/functions/chemical-info-lookup/ingestion/manufacturer_label_snapshot_replay.ts";
import type { IndexedLabelSnapshot } from "../supabase/functions/chemical-info-lookup/ingestion/manufacturer_label_snapshot.ts";

export async function replayFile(file: string): Promise<{ original: unknown; replayed: unknown; comparison: unknown; vineyard_rates: unknown }> {
  if ((await Deno.stat(file)).size > 150_000) throw new Error("Snapshot exceeds diagnostic size limit");
  const snapshot = JSON.parse(await Deno.readTextFile(file)) as IndexedLabelSnapshot;
  if (snapshot.version !== 2 || snapshot.validator_version !== 1 || !snapshot.validation || !snapshot.master)
    throw new Error("Unsupported or missing snapshot/validator version");
  const replayed = await replayIndexedLabelSnapshot(snapshot);
  const observed = { status: replayed.status, reason: replayed.status === "ready" ? null : replayed.reason };
  if (JSON.stringify(observed) !== JSON.stringify(snapshot.validation))
    throw new Error(`Validator replay diverged: stored=${JSON.stringify(snapshot.validation)} replayed=${JSON.stringify(observed)}`);
  return { original: snapshot.validation, replayed: observed,
    comparison: { locked: snapshot.locked, extracted: snapshot.extracted?.product,
      printed_registration: snapshot.extracted?.registration, actives: snapshot.extracted?.actives,
      tool_evidence: snapshot.tool, normalized: snapshot.comparison },
    vineyard_rates: snapshot.extracted?.uses.filter((use) => /grape|vineyard/i.test(use.crop ?? "")) ?? [] };
}

if (import.meta.main) {
  if (Deno.args.length !== 1) throw new Error("Usage: deno run --allow-read=SNAPSHOT scripts/replay-indexed-label-snapshot.ts SNAPSHOT");
  console.log(JSON.stringify(await replayFile(Deno.args[0]), null, 2));
}
