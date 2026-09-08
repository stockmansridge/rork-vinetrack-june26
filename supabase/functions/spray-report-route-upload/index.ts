import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const BUCKET = "trip-report-assets";
const STYLE = "spray-route-red-green-v1";
const MAX_BYTES = 10 * 1024 * 1024;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}
function hex(bytes: Uint8Array): string {
  return Array.from(bytes).map((value) => value.toString(16).padStart(2, "0")).join("");
}
function decodeBase64(value: string): Uint8Array {
  const binary = atob(value);
  const result = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) result[index] = binary.charCodeAt(index);
  return result;
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !anonKey || !serviceKey) return json({ error: "Server misconfigured" }, 500);
  const authorization = request.headers.get("Authorization") ?? "";
  if (!authorization.toLowerCase().startsWith("bearer ")) return json({ error: "Authentication required" }, 401);
  const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false } });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) return json({ error: "Authentication required" }, 401);

  let body: Record<string, unknown>;
  try { body = await request.json(); } catch { return json({ error: "Invalid JSON" }, 400); }
  const tripId = typeof body.tripId === "string" ? body.tripId : "";
  const routeHash = typeof body.routeHash === "string" ? body.routeHash : "";
  const pngBase64 = typeof body.pngBase64 === "string" ? body.pngBase64 : "";
  const coordinates = Array.isArray(body.coordinates) ? body.coordinates.filter((point): point is { latitude: number; longitude: number } => typeof point === "object" && point !== null && Number.isFinite((point as { latitude?: number }).latitude) && Number.isFinite((point as { longitude?: number }).longitude)) : [];
  const width = Number(body.width);
  const height = Number(body.height);
  if (!/^[0-9a-f-]{36}$/i.test(tripId) || !/^[a-f0-9]{64}$/.test(routeHash) || width !== 1030 || height !== 700) {
    return json({ error: "Invalid canonical route metadata" }, 400);
  }
  if (coordinates.length >= 2) {
    const routeInput = [STYLE, "1030x700", ...coordinates.map((point) => `${point.latitude.toFixed(6)},${point.longitude.toFixed(6)}`)].join("|");
    const routeInputBytes: ArrayBuffer = Uint8Array.from(new TextEncoder().encode(routeInput)).buffer;
    const verifiedRouteHash = hex(new Uint8Array(await crypto.subtle.digest("SHA-256", routeInputBytes)));
    if (verifiedRouteHash !== routeHash) return json({ error: "Route hash does not match the complete coordinate sequence" }, 400);
  }
  const { data: trip, error: tripError } = await userClient.from("trips").select("id,vineyard_id").eq("id", tripId).is("deleted_at", null).maybeSingle();
  if (tripError || !trip) return json({ error: "Trip not found or access denied" }, 404);

  let bytes: Uint8Array;
  if (pngBase64) {
    try { bytes = decodeBase64(pngBase64); } catch { return json({ error: "Invalid PNG encoding" }, 400); }
  } else {
    const mapsKey = Deno.env.get("GOOGLE_MAPS_API_KEY") ?? "";
    if (!mapsKey || coordinates.length < 2) return json({ error: "PNG bytes or at least two route coordinates are required" }, 400);
    const sampled = coordinates.length <= 100 ? coordinates : Array.from({ length: 100 }, (_, index) => coordinates[Math.round(index * (coordinates.length - 1) / 99)]);
    const staticUrl = new URL("https://maps.googleapis.com/maps/api/staticmap");
    staticUrl.searchParams.set("size", "515x350"); staticUrl.searchParams.set("scale", "2"); staticUrl.searchParams.set("format", "png"); staticUrl.searchParams.set("maptype", "hybrid");
    const colors = ["0xdb1a1aff", "0xf5520fff", "0xfaad0dff", "0xa6c214ff", "0x1a9e38ff"];
    colors.forEach((color, colorIndex) => {
      const start = Math.floor(colorIndex * (sampled.length - 1) / colors.length);
      const end = Math.ceil((colorIndex + 1) * (sampled.length - 1) / colors.length);
      const segment = sampled.slice(start, end + 1).map((point) => `${point.latitude.toFixed(6)},${point.longitude.toFixed(6)}`).join("|");
      staticUrl.searchParams.append("path", `color:${color}|weight:4|${segment}`);
    });
    const first = sampled[0]; const last = sampled[sampled.length - 1];
    staticUrl.searchParams.append("markers", `color:red|label:S|${first.latitude.toFixed(6)},${first.longitude.toFixed(6)}`);
    staticUrl.searchParams.append("markers", `color:green|label:F|${last.latitude.toFixed(6)},${last.longitude.toFixed(6)}`);
    staticUrl.searchParams.set("key", mapsKey);
    const mapResponse = await fetch(staticUrl);
    if (!mapResponse.ok) return json({ error: `Canonical map generation failed (${mapResponse.status})` }, 502);
    bytes = new Uint8Array(await mapResponse.arrayBuffer());
  }
  if (bytes.length < 8 || bytes.length > MAX_BYTES || bytes[0] !== 0x89 || bytes[1] !== 0x50 || bytes[2] !== 0x4e || bytes[3] !== 0x47) {
    return json({ error: "A valid PNG within the size limit is required" }, 400);
  }
  const digestInput: ArrayBuffer = Uint8Array.from(bytes).buffer;
  const sha256 = hex(new Uint8Array(await crypto.subtle.digest("SHA-256", digestInput)));
  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });
  const objectPath = `${tripId}/${STYLE}-${routeHash.slice(0, 16)}-${sha256.slice(0, 16)}.png`;
  const { error: uploadError } = await admin.storage.from(BUCKET).upload(objectPath, bytes, { contentType: "image/png", upsert: false });
  if (uploadError && !uploadError.message.toLowerCase().includes("already exists")) return json({ error: "Route upload failed" }, 502);

  const { data: registered, error: registerError } = await userClient.rpc("register_spray_report_route_asset_v1", {
    p_trip_id: tripId, p_bucket: BUCKET, p_object_path: objectPath, p_sha256: sha256, p_route_hash: routeHash, p_style_version: STYLE,
  });
  if (registerError || !registered) return json({ error: "Route registration failed" }, 502);
  const winner = registered as { objectPath?: string; sha256?: string };
  if (winner.objectPath !== objectPath) await admin.storage.from(BUCKET).remove([objectPath]);
  return json({ route: registered, uploadedSha256: sha256, reusedExisting: winner.objectPath !== objectPath });
});
