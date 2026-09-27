-- Manufacturer-only V2 result cache. Unreviewed results never become approved Master entries.
create table if not exists public.chemical_web_v2_cache (
  key text primary key,
  payload jsonb not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  constraint chemical_web_v2_cache_key_length check (length(key) between 8 and 250)
);
create index if not exists chemical_web_v2_cache_expiry on public.chemical_web_v2_cache (expires_at);
alter table public.chemical_web_v2_cache enable row level security;
revoke all on public.chemical_web_v2_cache from anon, authenticated;
grant select, insert, update, delete on public.chemical_web_v2_cache to service_role;
