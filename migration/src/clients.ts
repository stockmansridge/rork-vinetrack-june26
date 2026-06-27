import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import type { MigrationConfig } from "./config.js";

export type MigrationClients = {
  v1: SupabaseClient;
  v2: SupabaseClient;
};

export function createMigrationClients(config: MigrationConfig): MigrationClients {
  return {
    v1: createAdminClient(config.v1Url, config.v1ServiceRoleKey),
    v2: createAdminClient(config.v2Url, config.v2ServiceRoleKey)
  };
}

function createAdminClient(url: string, key: string): SupabaseClient {
  return createClient(url, key, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
      detectSessionInUrl: false
    }
  });
}
