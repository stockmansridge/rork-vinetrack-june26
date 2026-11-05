// Issue #53: permanent fixture hard delete orchestrator.
// A user's JWT authorizes the SQL RPC. The service key stays server-side and
// ONLY cleans the deleted item's private photo folder after the RPC receipt.
// Retries of the same operation ID are safe and finish incomplete cleanup.

type DeleteRequest = {
  p_operation_id: string;
  p_item_id: string;
  p_vineyard_id: string;
  p_expected_revision: number;
};

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const respond = (body: object, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: CORS });

async function readJson(response: Response): Promise<any> {
  const body = await response.text();
  try { return body ? JSON.parse(body) : null; }
  catch { return { message: "Unexpected server response" }; }
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response(null, { headers: CORS, status: 204 });
  if (request.method !== "POST") return respond({ error: "method_not_allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL")?.replace(/\/+$/, "");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceKey) {
    return respond({ error: "service_not_configured" }, 503);
  }

  const authorization = request.headers.get("Authorization") ?? "";
  if (!/^Bearer \S+$/i.test(authorization)) {
    return respond({ error: "sign_in_required" }, 401);
  }
  const jwt = authorization.replace(/^Bearer /i, "");
  let input: DeleteRequest;
  try {
    if (Number(request.headers.get("Content-Length") ?? 0) > 4096) throw Error("oversized");
    input = await request.json();
    if (!input || !UUID.test(input.p_operation_id) || !UUID.test(input.p_item_id) ||
        !UUID.test(input.p_vineyard_id) ||
        !Number.isSafeInteger(input.p_expected_revision) ||
        input.p_expected_revision < 1) throw Error("invalid");
  } catch {
    return respond({ error: "invalid_delete_request" }, 400);
  }

  // JWT validity, not a client-supplied actor ID, determines identity.
  const userResponse = await fetch(supabaseUrl + "/auth/v1/user", {
    headers: { apikey: anonKey, Authorization: authorization },
  }).catch(() => null);
  if (!userResponse?.ok) return respond({ error: "invalid_session" }, 401);

  // The SECURITY DEFINER RPC independently enforces selected vineyard
  // membership + current owner/manager role + pilot flag + revision CAS.
  const rpcResponse = await fetch(supabaseUrl + "/rest/v1/rpc/hard_delete_permanent_item_v1", {
    method: "POST",
    headers: {
      apikey: anonKey,
      Authorization: authorization,
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify(input),
  }).catch(() => null);
  if (!rpcResponse) return respond({ error: "delete_retry_required" }, 503);
  const receiptData = await readJson(rpcResponse);
  if (!rpcResponse.ok) {
    const code = receiptData?.code ?? "";
    const status = code === "42501" ? 403 : code === "40001" || code === "23505" ? 409 :
                   code === "P0002" ? 404 : rpcResponse.status >= 500 ? 503 : 400;
    return respond({ error: "delete_rejected", code, message: String(receiptData?.message ?? "Delete rejected") }, status);
  }
  const receipt = Array.isArray(receiptData) && receiptData.length === 1 ? receiptData[0] : null;
  if (!receipt ||
      receipt.item_id !== input.p_item_id.toLowerCase() ||
      receipt.operation_id !== input.p_operation_id.toLowerCase() ||
      receipt.vineyard_id !== input.p_vineyard_id.toLowerCase()) {
    return respond({ error: "delete_receipt_unverified", photo_cleanup_pending: true }, 503);
  }

  const adminHeaders = { apikey: serviceKey, Authorization: "Bearer " + serviceKey,
                         "Content-Type": "application/json" };
  // Confirm the row is actually absent before deleting storage objects.
  const checkUrl = new URL(supabaseUrl + "/rest/v1/permanent_items");
  checkUrl.searchParams.set("select", "id");
  checkUrl.searchParams.set("id", "eq." + input.p_item_id.toLowerCase());
  checkUrl.searchParams.set("vineyard_id", "eq." + input.p_vineyard_id.toLowerCase());
  const check = await fetch(checkUrl.toString(), { headers: adminHeaders }).catch(() => null);
  if (!check?.ok) return respond({ error: "delete_verification_unavailable", photo_cleanup_pending: true }, 503);
  const found = await readJson(check);
  if (!Array.isArray(found) || found.length !== 0) {
    return respond({ error: "delete_not_confirmed", photo_cleanup_pending: true }, 503);
  }

  const folder = input.p_vineyard_id.toLowerCase() + "/" + input.p_item_id.toLowerCase();
  let photoObjectsRemoved = 0;
  // Old photo revisions can leave additional files in the same exact item folder.
  // Never trust a client-provided photo path or allow a directory above item_id.
  try {
    let clean = false;
    for (let attempt = 0; attempt < 20; attempt++) {
      const list = await fetch(supabaseUrl + "/storage/v1/object/list/permanent-item-photos", {
        method: "POST",
        headers: adminHeaders,
        body: JSON.stringify({ prefix: folder + "/", limit: 100, offset: 0, sortBy: { column: "name", order: "asc" } }),
      });
      const objects = await readJson(list);
      if (!list.ok || !Array.isArray(objects)) throw Error("photo_list_failed");
      const entries = objects.filter((entry: any) => typeof entry?.name === "string" &&
        /^[A-Za-z0-9_-]{1,100}\.(jpg|jpeg|png|webp)$/i.test(entry.name));
      if (objects.length === 0) { clean = true; break; }
      if (entries.length !== objects.length) throw Error("unexpected_photo_folder_content");
      const paths = entries.map((entry: any) => folder + "/" + entry.name);
      const removed = await fetch(supabaseUrl + "/storage/v1/object/permanent-item-photos", {
        method: "DELETE",
        headers: adminHeaders,
        body: JSON.stringify({ prefixes: paths }),
      });
      if (!removed.ok) throw Error("photo_remove_failed");
      photoObjectsRemoved += paths.length;
    }
    if (!clean) throw Error("photo_cleanup_incomplete");
  } catch {
    // The database row HAS been physically deleted. Retain exactly this operation
    // ID and retry to clean any objects; never generate another delete.
    return respond({
      deleted: true, photo_cleanup_pending: true,
      item_id: receipt.item_id, operation_id: receipt.operation_id,
      message: "Permanent Item deleted; retry the same operation to finish private photo cleanup.",
    }, 503);
  }

  return respond({
    deleted: true, photo_cleanup_pending: false,
    item_id: receipt.item_id, operation_id: receipt.operation_id,
    deleted_at: receipt.deleted_at,
    photo_objects_removed: photoObjectsRemoved,
  });
});
