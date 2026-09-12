import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

interface Job {
  pin_id: string;
  evidence_revision: number;
  resolver_version: string;
  lease_token: string;
}

Deno.serve(async (request: Request): Promise<Response> => {
  const secret = Deno.env.get("PIN_ENRICHMENT_WORKER_SECRET");
  const supplied = request.headers.get("x-pin-enrichment-secret");
  if (!secret || supplied !== secret) return new Response("Unauthorized", { status: 401 });

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return new Response("Missing server configuration", { status: 500 });
  const client = createClient(url, serviceKey, { auth: { persistSession: false } });
  const { data, error } = await client.rpc("claim_pin_location_enrichment", {
    p_limit: 20,
    p_lease_seconds: 90,
  });
  if (error) return Response.json({ error: "claim_failed" }, { status: 500 });

  const outcomes: Array<{ pinId: string; outcome: string }> = [];
  for (const job of (data ?? []) as Job[]) {
    const result = await client.rpc("commit_pin_location_enrichment", {
      p_pin_id: job.pin_id,
      p_evidence_revision: job.evidence_revision,
      p_resolver_version: job.resolver_version,
      p_lease_token: job.lease_token,
    });
    if (result.error) {
      const failed = await client.rpc("fail_pin_location_enrichment", {
        p_pin_id: job.pin_id,
        p_evidence_revision: job.evidence_revision,
        p_resolver_version: job.resolver_version,
        p_lease_token: job.lease_token,
        p_error: result.error.message || "commit_failed",
      });
      outcomes.push({ pinId: job.pin_id, outcome: String(failed.data ?? "retry_not_recorded") });
    } else {
      outcomes.push({ pinId: job.pin_id, outcome: String(result.data ?? "unknown") });
    }
  }
  return Response.json({ claimed: outcomes.length, outcomes });
});
