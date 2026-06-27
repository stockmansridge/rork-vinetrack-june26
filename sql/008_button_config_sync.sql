-- Phase 10F: Vineyard button configuration sync.
-- Stores per-vineyard repair/growth button configuration so all members of a
-- vineyard see the same button workflow. Configuration may only be edited by
-- owners and managers.

create table if not exists public.vineyard_button_configs (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  config_type text not null check (config_type in ('repair_buttons', 'growth_buttons', 'button_templates')),
  config_data jsonb not null default '[]'::jsonb,

  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1,

  unique (vineyard_id, config_type)
);

create index if not exists idx_vineyard_button_configs_vineyard_id
  on public.vineyard_button_configs (vineyard_id);
create index if not exists idx_vineyard_button_configs_config_type
  on public.vineyard_button_configs (config_type);
create index if not exists idx_vineyard_button_configs_updated_at
  on public.vineyard_button_configs (updated_at);

create or replace trigger vineyard_button_configs_set_updated_at
before update on public.vineyard_button_configs
for each row execute function public.set_updated_at();

alter table public.vineyard_button_configs enable row level security;

-- Any vineyard member may read configuration for their vineyard.
drop policy if exists "vineyard_button_configs_select_members"
  on public.vineyard_button_configs;
create policy "vineyard_button_configs_select_members"
on public.vineyard_button_configs for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

-- Only owners and managers may insert configuration rows.
drop policy if exists "vineyard_button_configs_insert_admins"
  on public.vineyard_button_configs;
create policy "vineyard_button_configs_insert_admins"
on public.vineyard_button_configs for insert
to authenticated
with check (
  public.has_vineyard_role(vineyard_id, array['owner', 'manager'])
);

-- Only owners and managers may update configuration rows.
drop policy if exists "vineyard_button_configs_update_admins"
  on public.vineyard_button_configs;
create policy "vineyard_button_configs_update_admins"
on public.vineyard_button_configs for update
to authenticated
using (
  public.has_vineyard_role(vineyard_id, array['owner', 'manager'])
)
with check (
  public.has_vineyard_role(vineyard_id, array['owner', 'manager'])
);

-- Hard delete is blocked from the client.
drop policy if exists "vineyard_button_configs_no_client_hard_delete"
  on public.vineyard_button_configs;
create policy "vineyard_button_configs_no_client_hard_delete"
on public.vineyard_button_configs for delete
to authenticated
using (false);
