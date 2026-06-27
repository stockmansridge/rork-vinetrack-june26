import type { SupabaseClient } from "@supabase/supabase-js";
import type { SourceSnapshot } from "../types.js";
import { listAuthUsers, readTable } from "./v2.js";

export async function readV1Snapshot(client: SupabaseClient): Promise<SourceSnapshot> {
  const [
    users,
    profiles,
    vineyards,
    vineyardMembers,
    invitations,
    disclaimerAcceptances,
    vineyardData
  ] = await Promise.all([
    listAuthUsers(client),
    readTable(client, "profiles"),
    readTable(client, "vineyards"),
    readTable(client, "vineyard_members"),
    readTable(client, "invitations"),
    readTable(client, "disclaimer_acceptances"),
    readVineyardData(client)
  ]);

  return {
    users,
    profiles,
    vineyards,
    vineyardMembers,
    invitations,
    disclaimerAcceptances,
    vineyardData
  };
}

async function readVineyardData(client: SupabaseClient) {
  const primary = await readTable(client, "vineyard_data");
  if (primary.exists) return primary;
  const fallback = await readTable(client, "vineyardData");
  if (fallback.exists) return { ...fallback, table: "vineyardData" };
  return primary;
}
