-- 203: Master Catalogue Review — Stage 2 R2-A (SQL layer only).
--
-- Implements the AMENDED Stage 2 review contract (trust-boundary revision):
-- the review-apply path is server-bound. The client NEVER submits or echoes an
-- authoritative patch. `master_review_preview` (edge, R2-B) stores the exact
-- resolver-built patch server-side in `master_review_previews`; apply loads it
-- by opaque id. A caller holding an admin JWT can therefore never write
-- source_kind, verification_* fields, registered_uses, or any resolver
-- provenance with values of their own choosing — there is no RPC that accepts
-- those values as input.
--
-- WHAT THIS CREATES
--   * public.master_review_previews         — short-lived, single-use, server-
--     stored resolver patches. Written ONLY by the service-role edge action
--     (the one service-role write in the review flow); consumed ONLY inside
--     master_review_apply. No client role can insert/update/delete.
--   * public.master_chemical_review_actions — append-only review decision
--     audit (who/when/why/what was reviewed and what it produced). No write
--     policies, no write grants: rows are inserted exclusively inside the
--     SECURITY DEFINER RPCs below. UPDATE/DELETE are impossible for every
--     client role — append-only by construction.
--   * Four SECURITY DEFINER RPCs, each first-line gated on
--     public.is_system_admin() and executed under the ADMIN'S OWN JWT so the
--     sql/199 version trigger records real reviewer attribution
--     (changed_by = auth.uid()) and a mandatory change reason (GUC
--     vinetrack.master_change_reason):
--       master_review_apply(p_preview_id, p_master_id, p_reason)
--       master_review_adjudicate(p_master_id, p_expected_revision, p_field,
--                                p_conflict, p_selected, p_reason)
--       master_review_correct(p_master_id, p_expected_revision, p_patch, p_reason)
--       master_review_rekey(p_master_id, p_expected_revision, p_new_country,
--                           p_new_scheme, p_new_number, p_reason)
--
-- TRUST BOUNDARY (amended contract §B/§C)
--   * Resolver patch contract — the ONLY fields a stored preview patch may
--     write: registered_product_name, registrant, product_category, form_type,
--     label_version, label_reference, registered_uses, label_rate_bases,
--     verification_status, verification_sources, verification_conflicts,
--     verification_unresolved_fields, retrieved_at, source_kind,
--     source_reference. Enforced here at apply time (defense in depth; the
--     edge validates again at store time in R2-B). Identity fields and
--     review_status are structurally impossible through every path.
--   * master_review_correct whitelist (never carries authority): common_names,
--     product_category, form_type, label_reference, label_version,
--     review_notes, registrant, registered_product_name. Canonical-content
--     corrections append a `manual_entry` source entry; alias/notes-only
--     corrections do not (so they keep not bumping catalogue_version — no
--     false drift signals, exactly as the sql/199 trigger intends).
--   * master_review_adjudicate mutates NO field values. `stored` and
--     `superseded_by_refresh` remove the chosen conflict entry, append a
--     `manual_entry` source, and recompute status capped at
--     partially_verified (adjudication can never mint `verified`).
--     `authoritative` is gated on a typed-handler registry that ships EMPTY:
--     every authoritative selection fails closed with typed_handler_missing,
--     because WireConflict.authoritative_value is display text, never a
--     writable value. Registration identity conflicts are excluded entirely
--     (identity_not_adjudicable).
--   * master_review_rekey is the ONLY identity path: candidate + zero linked
--     saved_chemicals + duplicate-identity check. Approved/linked rows use
--     retire + create (identity immutable).
--
-- SAFETY CONTRACT
--   * Purely additive. sql/199 tables, triggers, CHECKs (including THE
--     approval gate master_chemicals_approved_provenance_check) and RLS are
--     untouched. saved_chemicals is READ ONLY here (rekey linkage check).
--     spray_records / spray snapshots are never read or written.
--   * Atomic by construction: each RPC is one transaction — patch apply,
--     preview consumption and the review-action insert commit or fail
--     together. Partial states cannot exist.
--   * Idempotent migration; single transaction.
--
-- ERROR TOKENS (message text is the contract; errcode aids edge mapping)
--   not_authorised(42501) reason_required(22023) preview_not_found(P0002)
--   preview_not_yours(42501) preview_mismatch(22023) preview_expired(55000)
--   master_not_found(P0002) revision_mismatch(55000)
--   patch_contract_violation(22023) invalid_selection(22023)
--   field_required(22023) conflict_invalid(22023)
--   conflict_field_mismatch(22023) identity_not_adjudicable(22023)
--   typed_handler_missing(0A000) conflict_not_found(P0002)
--   invalid_identity(22023) rekey_not_candidate(55000) rekey_linked(55000)
--   identity_exists(23505)
--   Idempotent replay of a consumed preview is NOT an error: apply returns
--   {"status":"already_applied", ...}.

begin;

-- ---------------------------------------------------------------------------
-- 0. Preconditions
-- ---------------------------------------------------------------------------

do $$
begin
  if to_regprocedure('public.is_system_admin()') is null then
    raise exception 'sql/203 precondition failed: public.is_system_admin() missing (apply sql/062 first)';
  end if;
  if to_regclass('public.master_chemicals') is null
     or to_regclass('public.master_chemical_versions') is null then
    raise exception 'sql/203 precondition failed: master catalogue missing (apply sql/199 first)';
  end if;
  if to_regprocedure('public.master_chemicals_before_write()') is null
     or to_regprocedure('public.master_chemicals_record_version()') is null then
    raise exception 'sql/203 precondition failed: sql/199 revision/history triggers missing';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'saved_chemicals'
                    and column_name = 'master_chemical_id') then
    raise exception 'sql/203 precondition failed: saved_chemicals.master_chemical_id missing (apply sql/199 first)';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- 1. master_review_previews — server-stored resolver patches (short-lived)
-- ---------------------------------------------------------------------------

create table if not exists public.master_review_previews (
  id uuid primary key default gen_random_uuid(),
  master_chemical_id uuid not null references public.master_chemicals(id) on delete cascade,
  -- catalogue_version at preview time — the CAS token apply verifies. The
  -- client never echoes it; it lives here, server-side.
  base_revision integer not null,
  -- Resolver refresh outcome at preview time (vocabulary owned by the edge;
  -- non-empty is the only structural requirement so R2-B outcome growth
  -- never needs a schema change).
  outcome text not null,
  -- The EXACT whitelisted patch the resolver built. What apply writes is this
  -- and only this — the display copy returned to the portal is informational.
  proposed_patch jsonb not null,
  -- Diff snapshot ({field, current, authoritative} entries) for portal/audit.
  changes jsonb,
  -- The admin the preview is bound to; apply refuses every other caller.
  requested_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '30 minutes'),
  consumed_at timestamptz,
  -- The review action that consumed this preview. Plain uuid, no FK: the
  -- durable copy of the patch lives in the action row; previews are
  -- ephemeral and purged opportunistically.
  consumed_action_id uuid,
  constraint master_review_previews_base_revision_check
    check (base_revision >= 1),
  constraint master_review_previews_outcome_check
    check (btrim(outcome) <> ''),
  constraint master_review_previews_patch_object_check
    check (jsonb_typeof(proposed_patch) = 'object')
);

comment on table public.master_review_previews is
  'Server-stored resolver refresh patches awaiting admin apply (sql/203, Stage 2 R2-A). '
  'Written ONLY by the service-role master_review_preview edge action; consumed ONLY inside '
  'the master_review_apply RPC. Single-use, expiring, bound to the requesting admin. This '
  'table IS the trust boundary: because no client role can write here, no client can ever '
  'submit an authoritative patch of its own.';
comment on column public.master_review_previews.proposed_patch is
  'Exact resolver-built patch, resolver-patch-contract keys only. Apply writes exactly this. '
  'Never client-supplied, never client-echoed.';
comment on column public.master_review_previews.base_revision is
  'master_chemicals.catalogue_version the admin reviewed. Apply CAS-checks against it.';

create index if not exists idx_master_review_previews_master
  on public.master_review_previews (master_chemical_id, created_at desc);

-- ---------------------------------------------------------------------------
-- 2. master_chemical_review_actions — append-only review decision audit
-- ---------------------------------------------------------------------------
-- FK deliberately has NO cascade: a master row with recorded review decisions
-- cannot be hard-deleted (retire it instead) — same doctrine as the
-- saved_chemicals link.

create table if not exists public.master_chemical_review_actions (
  id uuid primary key default gen_random_uuid(),
  master_chemical_id uuid not null references public.master_chemicals(id),
  action text not null,
  -- Which stored preview a refresh_apply consumed (no FK; previews are
  -- ephemeral — the patch itself is duplicated into `patch` for permanence).
  preview_id uuid,
  -- catalogue_version the admin reviewed / the version after the write.
  -- result_revision = base_revision when the write changed no canonical
  -- content (still a decision, still audited).
  base_revision integer not null,
  result_revision integer,
  -- adjudicate only:
  field text,
  conflict jsonb,
  selected text,
  -- refresh_apply / correct / rekey payload (verbatim, durable).
  patch jsonb,
  reason text not null,
  performed_by uuid not null references auth.users(id),
  performed_at timestamptz not null default now(),
  constraint master_review_actions_action_check
    check (action in ('refresh_apply','adjudicate','correct','rekey')),
  -- 'authoritative' is reserved for R2-D typed handlers; in Stage 2 it is
  -- unreachable (the RPC fails closed before any write).
  constraint master_review_actions_selected_check
    check (selected is null or selected in ('stored','superseded_by_refresh','authoritative')),
  constraint master_review_actions_reason_check
    check (btrim(reason) <> '')
);

comment on table public.master_chemical_review_actions is
  'Append-only Master Catalogue review decision audit (sql/203, Stage 2 R2-A). One row per '
  'admin decision: refresh apply, conflict adjudication, correction, rekey. Written '
  'exclusively inside the SECURITY DEFINER review RPCs; no role holds INSERT/UPDATE/DELETE. '
  'A conflict leaves the live row only by acquiring a decision record here — evidence is '
  'never deleted (pre-change row images live in master_chemical_versions).';
comment on column public.master_chemical_review_actions.conflict is
  'For adjudications: the disputed conflict entry VERBATIM, kept forever.';

create index if not exists idx_master_review_actions_master
  on public.master_chemical_review_actions (master_chemical_id, performed_at desc);

-- ---------------------------------------------------------------------------
-- 3. RLS + privileges — the structural write lockout
-- ---------------------------------------------------------------------------
-- Both tables: system-admin SELECT only; ZERO write policies. Grants are
-- revoked down to the minimum (Supabase default privileges would otherwise
-- hand ALL to anon/authenticated/service_role):
--   previews: authenticated SELECT (RLS-gated); service_role SELECT/INSERT/
--             DELETE (edge stores + purges stale rows) — NO UPDATE anywhere:
--             consumption happens only inside master_review_apply (owner).
--   actions:  authenticated SELECT (RLS-gated); service_role SELECT.
--             No INSERT/UPDATE/DELETE for any role — append-only.

alter table public.master_review_previews         enable row level security;
alter table public.master_chemical_review_actions enable row level security;

drop policy if exists master_review_previews_admin_read on public.master_review_previews;
create policy master_review_previews_admin_read
  on public.master_review_previews for select to authenticated
  using (public.is_system_admin());

drop policy if exists master_review_actions_admin_read on public.master_chemical_review_actions;
create policy master_review_actions_admin_read
  on public.master_chemical_review_actions for select to authenticated
  using (public.is_system_admin());

revoke all on table public.master_review_previews
  from public, anon, authenticated, service_role;
grant select on public.master_review_previews to authenticated;
grant select, insert, delete on public.master_review_previews to service_role;

revoke all on table public.master_chemical_review_actions
  from public, anon, authenticated, service_role;
grant select on public.master_chemical_review_actions to authenticated;
grant select on public.master_chemical_review_actions to service_role;

-- ---------------------------------------------------------------------------
-- 4. master_review_apply — apply a server-stored resolver patch
-- ---------------------------------------------------------------------------
-- The client sends an opaque preview id + reason. The patch, the CAS token
-- and the ownership binding are all read server-side. Validation order is the
-- amended contract's: admin -> reason -> preview exists -> ownership ->
-- master match -> consumed (idempotent) -> expiry -> CAS -> patch contract.

create or replace function public.master_review_apply(
  p_preview_id uuid,
  p_master_id uuid,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_preview public.master_review_previews%rowtype;
  v_master public.master_chemicals%rowtype;
  v_patch jsonb;
  v_key text;
  v_type text;
  v_action_id uuid := gen_random_uuid();
  v_result_revision integer;
begin
  if not public.is_system_admin() then
    raise exception 'not_authorised' using errcode = '42501';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'reason_required' using errcode = '22023';
  end if;

  select * into v_preview
    from public.master_review_previews
   where id = p_preview_id
   for update;
  if not found then
    raise exception 'preview_not_found' using errcode = 'P0002';
  end if;

  -- Apply is bound to the admin who previewed — reviewer attribution stays
  -- honest and a stolen preview id is useless to anyone else.
  if v_preview.requested_by is distinct from auth.uid() then
    raise exception 'preview_not_yours' using errcode = '42501';
  end if;
  if v_preview.master_chemical_id is distinct from p_master_id then
    raise exception 'preview_mismatch' using errcode = '22023';
  end if;

  -- Idempotent double-tap: a consumed preview replays its outcome, writes
  -- nothing, and reports the revision the original apply produced.
  if v_preview.consumed_at is not null then
    select a.result_revision into v_result_revision
      from public.master_chemical_review_actions a
     where a.id = v_preview.consumed_action_id;
    return jsonb_build_object(
      'status', 'already_applied',
      'master_chemical_id', p_master_id,
      'base_revision', v_preview.base_revision,
      'result_revision', v_result_revision,
      'action_id', v_preview.consumed_action_id);
  end if;

  if v_preview.expires_at <= now() then
    raise exception 'preview_expired' using errcode = '55000',
      hint = 'Re-run master_review_preview; the register may have drifted.';
  end if;

  select * into v_master
    from public.master_chemicals
   where id = p_master_id
   for update;
  if not found then
    raise exception 'master_not_found' using errcode = 'P0002';
  end if;
  if v_master.catalogue_version <> v_preview.base_revision then
    raise exception 'revision_mismatch' using errcode = '55000',
      detail = format('current_revision=%s base_revision=%s',
                      v_master.catalogue_version, v_preview.base_revision);
  end if;

  -- Defense in depth: re-validate the stored patch against the resolver
  -- patch contract. The edge enforces this at store time (R2-B); a violation
  -- here means the store path is compromised — fail closed, write nothing.
  v_patch := v_preview.proposed_patch;
  if v_patch is null or jsonb_typeof(v_patch) <> 'object' or v_patch = '{}'::jsonb then
    raise exception 'patch_contract_violation' using errcode = '22023',
      detail = 'proposed_patch must be a non-empty object';
  end if;
  for v_key, v_type in
    select e.key, jsonb_typeof(e.value) from jsonb_each(v_patch) e
  loop
    if v_key in ('registered_product_name','verification_status','source_kind') then
      if v_type <> 'string' then
        raise exception 'patch_contract_violation' using errcode = '22023',
          detail = format('key %s must be a string', v_key);
      end if;
    elsif v_key in ('registrant','product_category','form_type','label_version',
                    'label_reference','source_reference','retrieved_at') then
      if v_type not in ('string','null') then
        raise exception 'patch_contract_violation' using errcode = '22023',
          detail = format('key %s must be a string or null', v_key);
      end if;
    elsif v_key in ('registered_uses','label_rate_bases') then
      if v_type <> 'array' then
        raise exception 'patch_contract_violation' using errcode = '22023',
          detail = format('key %s must be an array', v_key);
      end if;
    elsif v_key in ('verification_sources','verification_conflicts',
                    'verification_unresolved_fields') then
      if v_type not in ('array','null') then
        raise exception 'patch_contract_violation' using errcode = '22023',
          detail = format('key %s must be an array or null', v_key);
      end if;
    else
      -- Identity fields, review_status, catalogue_version, anything else:
      -- not in the resolver patch contract. Nothing is written.
      raise exception 'patch_contract_violation' using errcode = '22023',
        detail = format('forbidden_key=%s', v_key);
    end if;
  end loop;

  -- Reviewer attribution + mandatory reason for the sql/199 version trigger.
  perform set_config('vinetrack.master_change_reason', p_reason, true);

  update public.master_chemicals m set
    registered_product_name = case when v_patch ? 'registered_product_name'
        then v_patch->>'registered_product_name' else m.registered_product_name end,
    registrant = case when v_patch ? 'registrant'
        then v_patch->>'registrant' else m.registrant end,
    product_category = case when v_patch ? 'product_category'
        then v_patch->>'product_category' else m.product_category end,
    form_type = case when v_patch ? 'form_type'
        then v_patch->>'form_type' else m.form_type end,
    label_version = case when v_patch ? 'label_version'
        then v_patch->>'label_version' else m.label_version end,
    label_reference = case when v_patch ? 'label_reference'
        then v_patch->>'label_reference' else m.label_reference end,
    registered_uses = case when v_patch ? 'registered_uses'
        then v_patch->'registered_uses' else m.registered_uses end,
    label_rate_bases = case when v_patch ? 'label_rate_bases'
        then (select coalesce(array_agg(t.v), '{}'::text[])
                from jsonb_array_elements_text(v_patch->'label_rate_bases') t(v))
        else m.label_rate_bases end,
    verification_status = case when v_patch ? 'verification_status'
        then v_patch->>'verification_status' else m.verification_status end,
    verification_sources = case when v_patch ? 'verification_sources'
        then nullif(v_patch->'verification_sources', 'null'::jsonb)
        else m.verification_sources end,
    verification_conflicts = case when v_patch ? 'verification_conflicts'
        then nullif(v_patch->'verification_conflicts', 'null'::jsonb)
        else m.verification_conflicts end,
    verification_unresolved_fields = case when v_patch ? 'verification_unresolved_fields'
        then case when jsonb_typeof(v_patch->'verification_unresolved_fields') = 'null' then null
             else (select coalesce(array_agg(t.v), '{}'::text[])
                     from jsonb_array_elements_text(v_patch->'verification_unresolved_fields') t(v))
             end
        else m.verification_unresolved_fields end,
    retrieved_at = case when v_patch ? 'retrieved_at'
        then nullif(v_patch->>'retrieved_at', '')::timestamptz else m.retrieved_at end,
    source_kind = case when v_patch ? 'source_kind'
        then v_patch->>'source_kind' else m.source_kind end,
    source_reference = case when v_patch ? 'source_reference'
        then v_patch->>'source_reference' else m.source_reference end
  where m.id = p_master_id;

  select catalogue_version into v_result_revision
    from public.master_chemicals where id = p_master_id;

  -- Atomic with the update above: same transaction, all or nothing.
  insert into public.master_chemical_review_actions
    (id, master_chemical_id, action, preview_id, base_revision, result_revision,
     patch, reason, performed_by)
  values
    (v_action_id, p_master_id, 'refresh_apply', p_preview_id,
     v_preview.base_revision, v_result_revision, v_patch, p_reason, auth.uid());

  update public.master_review_previews
     set consumed_at = now(), consumed_action_id = v_action_id
   where id = p_preview_id;

  return jsonb_build_object(
    'status', 'applied',
    'master_chemical_id', p_master_id,
    'base_revision', v_preview.base_revision,
    'result_revision', v_result_revision,
    'action_id', v_action_id);
end$$;

comment on function public.master_review_apply(uuid, uuid, text) is
  'Applies a server-stored resolver refresh patch (sql/203). System admin only, under the '
  'admin''s own JWT. The client sends only an opaque preview id + reason — the patch, CAS '
  'token and ownership binding are read server-side. Single-use; consumed previews replay '
  'as already_applied. Never touches review_status, identity, saved_chemicals or sprays.';

revoke all on function public.master_review_apply(uuid, uuid, text) from public;
grant execute on function public.master_review_apply(uuid, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. master_review_adjudicate — resolve one evidenced conflict, values untouched
-- ---------------------------------------------------------------------------
-- The admin points at a server-stored conflict (jsonb equality) and chooses:
--   stored                — keep the stored value; conflict entry retired.
--   superseded_by_refresh — an applied refresh made the entry moot; retired.
--   authoritative         — adopt the register value: REQUIRES a typed
--                           handler. The registry ships EMPTY in Stage 2, so
--                           this ALWAYS fails closed (typed_handler_missing).
--                           authoritative_value is display text — it is never
--                           parsed and never written.
-- No selection ever changes a chemistry value in Stage 2. Status recompute is
-- capped at partially_verified; the retired entry is kept verbatim in the
-- audit row and in pre-change version snapshots.

create or replace function public.master_review_adjudicate(
  p_master_id uuid,
  p_expected_revision integer,
  p_field text,
  p_conflict jsonb,
  p_selected text,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_master public.master_chemicals%rowtype;
  v_conflicts jsonb;
  v_remaining jsonb;
  v_new_status text;
  v_source_entry jsonb;
  v_action_id uuid := gen_random_uuid();
  v_result_revision integer;
begin
  if not public.is_system_admin() then
    raise exception 'not_authorised' using errcode = '42501';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'reason_required' using errcode = '22023';
  end if;
  if p_selected is null
     or p_selected not in ('stored','superseded_by_refresh','authoritative') then
    raise exception 'invalid_selection' using errcode = '22023',
      detail = 'p_selected must be stored | superseded_by_refresh | authoritative';
  end if;
  if p_field is null or btrim(p_field) = '' then
    raise exception 'field_required' using errcode = '22023';
  end if;
  if p_conflict is null or jsonb_typeof(p_conflict) <> 'object' then
    raise exception 'conflict_invalid' using errcode = '22023';
  end if;
  if (p_conflict->>'field') is distinct from p_field then
    raise exception 'conflict_field_mismatch' using errcode = '22023';
  end if;

  -- Registration identity is never adjudicable — rekey (candidate + unlinked)
  -- or retire+create are the only identity paths. Checked before the typed-
  -- handler gate: the stronger rule wins.
  if p_field in ('registration_country','registration_scheme',
                 'registration_number','registration_identity_key') then
    raise exception 'identity_not_adjudicable' using errcode = '22023',
      hint = 'Identity changes only via master_review_rekey or retire+create.';
  end if;

  -- Typed handler registry: EMPTY in Stage 2 (R2-D adds the first handlers
  -- alongside resolver-captured typed payloads). Fail closed, write nothing.
  if p_selected = 'authoritative' then
    raise exception 'typed_handler_missing' using errcode = '0A000',
      detail = format('no typed adjudication handler registered for field %s', p_field),
      hint = 'authoritative_value is display text. Use refresh preview/apply for '
             'register-representable fields, or select stored with a reason.';
  end if;

  select * into v_master
    from public.master_chemicals
   where id = p_master_id
   for update;
  if not found then
    raise exception 'master_not_found' using errcode = 'P0002';
  end if;
  if v_master.catalogue_version <> p_expected_revision then
    raise exception 'revision_mismatch' using errcode = '55000',
      detail = format('current_revision=%s expected_revision=%s',
                      v_master.catalogue_version, p_expected_revision);
  end if;

  v_conflicts := coalesce(v_master.verification_conflicts, '[]'::jsonb);
  if jsonb_typeof(v_conflicts) <> 'array'
     or not exists (select 1 from jsonb_array_elements(v_conflicts) e
                     where e.value = p_conflict) then
    raise exception 'conflict_not_found' using errcode = 'P0002',
      hint = 'The row''s conflicts changed since review — re-load and re-decide.';
  end if;

  select coalesce(jsonb_agg(e.value), '[]'::jsonb) into v_remaining
    from jsonb_array_elements(v_conflicts) e
   where e.value <> p_conflict;

  -- Adjudication can never mint `verified`.
  v_new_status := case when jsonb_array_length(v_remaining) = 0
                       then 'partially_verified'
                       else 'conflict' end;

  -- Human review is marked with the existing non-authoritative source kind —
  -- every client already renders manual_entry as self-reported.
  v_source_entry := jsonb_build_object(
    'kind', 'manual_entry',
    'name', format('System admin adjudication — %s (%s)', p_field, p_selected),
    'reference', null,
    'retrieved_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));

  perform set_config('vinetrack.master_change_reason', p_reason, true);

  update public.master_chemicals set
    verification_conflicts = v_remaining,
    verification_status    = v_new_status,
    verification_sources   = coalesce(verification_sources, '[]'::jsonb)
                               || jsonb_build_array(v_source_entry)
  where id = p_master_id;

  select catalogue_version into v_result_revision
    from public.master_chemicals where id = p_master_id;

  insert into public.master_chemical_review_actions
    (id, master_chemical_id, action, base_revision, result_revision,
     field, conflict, selected, reason, performed_by)
  values
    (v_action_id, p_master_id, 'adjudicate', p_expected_revision, v_result_revision,
     p_field, p_conflict, p_selected, p_reason, auth.uid());

  return jsonb_build_object(
    'status', 'adjudicated',
    'master_chemical_id', p_master_id,
    'field', p_field,
    'selected', p_selected,
    'verification_status', v_new_status,
    'remaining_conflicts', jsonb_array_length(v_remaining),
    'base_revision', p_expected_revision,
    'result_revision', v_result_revision,
    'action_id', v_action_id);
end$$;

comment on function public.master_review_adjudicate(uuid, integer, text, jsonb, text, text) is
  'Adjudicates one evidenced verification conflict (sql/203). stored / superseded_by_refresh '
  'retire the entry without touching any value; authoritative fails closed '
  '(typed_handler_missing) until R2-D typed handlers exist. Registration identity conflicts '
  'are never adjudicable. Status recompute is capped at partially_verified.';

revoke all on function public.master_review_adjudicate(uuid, integer, text, jsonb, text, text) from public;
grant execute on function public.master_review_adjudicate(uuid, integer, text, jsonb, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. master_review_correct — non-authoritative metadata corrections
-- ---------------------------------------------------------------------------

create or replace function public.master_review_correct(
  p_master_id uuid,
  p_expected_revision integer,
  p_patch jsonb,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_master public.master_chemicals%rowtype;
  v_key text;
  v_type text;
  v_common text[];
  v_canonical_keys text[];
  v_source_entry jsonb;
  v_action_id uuid := gen_random_uuid();
  v_result_revision integer;
begin
  if not public.is_system_admin() then
    raise exception 'not_authorised' using errcode = '42501';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'reason_required' using errcode = '22023';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'patch_contract_violation' using errcode = '22023',
      detail = 'p_patch must be a non-empty object';
  end if;

  -- Correction whitelist. source_kind, verification_*, chemistry, identity
  -- and review_status are structurally unreachable — a correction can never
  -- launder authority or satisfy the approval gate.
  for v_key, v_type in
    select e.key, jsonb_typeof(e.value) from jsonb_each(p_patch) e
  loop
    if v_key = 'registered_product_name' then
      if v_type <> 'string' or btrim(p_patch->>'registered_product_name') = '' then
        raise exception 'patch_contract_violation' using errcode = '22023',
          detail = 'registered_product_name must be a non-empty string';
      end if;
    elsif v_key in ('registrant','product_category','form_type',
                    'label_reference','label_version','review_notes') then
      if v_type not in ('string','null') then
        raise exception 'patch_contract_violation' using errcode = '22023',
          detail = format('key %s must be a string or null', v_key);
      end if;
    elsif v_key = 'common_names' then
      if v_type <> 'array' then
        raise exception 'patch_contract_violation' using errcode = '22023',
          detail = 'common_names must be an array of strings';
      end if;
    else
      raise exception 'patch_contract_violation' using errcode = '22023',
        detail = format('forbidden_key=%s', v_key);
    end if;
  end loop;

  if p_patch ? 'common_names' then
    -- sql/199 alias contract: lower-cased exact-match aliases only.
    select coalesce(array_agg(distinct lower(btrim(t.v))), '{}'::text[])
      into v_common
      from jsonb_array_elements_text(p_patch->'common_names') t(v)
     where btrim(t.v) <> '';
  end if;

  select * into v_master
    from public.master_chemicals
   where id = p_master_id
   for update;
  if not found then
    raise exception 'master_not_found' using errcode = 'P0002';
  end if;
  if v_master.catalogue_version <> p_expected_revision then
    raise exception 'revision_mismatch' using errcode = '55000',
      detail = format('current_revision=%s expected_revision=%s',
                      v_master.catalogue_version, p_expected_revision);
  end if;

  -- Canonical-content corrections are trust-marked with a manual_entry source
  -- (which also bumps the revision, surfacing drift to linked vineyards).
  -- Alias/notes-only corrections stay revision-silent by sql/199 design —
  -- no source entry, no false drift signal. The audit row records both kinds.
  select array_agg(t.k order by t.k) into v_canonical_keys
    from jsonb_object_keys(p_patch) t(k)
   where t.k in ('registered_product_name','registrant','product_category',
                 'form_type','label_reference','label_version');

  perform set_config('vinetrack.master_change_reason', p_reason, true);

  if v_canonical_keys is not null then
    v_source_entry := jsonb_build_object(
      'kind', 'manual_entry',
      'name', format('System admin correction — %s', array_to_string(v_canonical_keys, ', ')),
      'reference', null,
      'retrieved_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  end if;

  update public.master_chemicals m set
    registered_product_name = case when p_patch ? 'registered_product_name'
        then p_patch->>'registered_product_name' else m.registered_product_name end,
    registrant = case when p_patch ? 'registrant'
        then p_patch->>'registrant' else m.registrant end,
    product_category = case when p_patch ? 'product_category'
        then p_patch->>'product_category' else m.product_category end,
    form_type = case when p_patch ? 'form_type'
        then p_patch->>'form_type' else m.form_type end,
    label_reference = case when p_patch ? 'label_reference'
        then p_patch->>'label_reference' else m.label_reference end,
    label_version = case when p_patch ? 'label_version'
        then p_patch->>'label_version' else m.label_version end,
    review_notes = case when p_patch ? 'review_notes'
        then p_patch->>'review_notes' else m.review_notes end,
    common_names = case when p_patch ? 'common_names'
        then v_common else m.common_names end,
    verification_sources = case when v_source_entry is not null
        then coalesce(m.verification_sources, '[]'::jsonb)
               || jsonb_build_array(v_source_entry)
        else m.verification_sources end
  where m.id = p_master_id;

  select catalogue_version into v_result_revision
    from public.master_chemicals where id = p_master_id;

  insert into public.master_chemical_review_actions
    (id, master_chemical_id, action, base_revision, result_revision,
     patch, reason, performed_by)
  values
    (v_action_id, p_master_id, 'correct', p_expected_revision, v_result_revision,
     p_patch, p_reason, auth.uid());

  return jsonb_build_object(
    'status', 'corrected',
    'master_chemical_id', p_master_id,
    'base_revision', p_expected_revision,
    'result_revision', v_result_revision,
    'action_id', v_action_id);
end$$;

comment on function public.master_review_correct(uuid, integer, jsonb, text) is
  'Non-authoritative admin corrections (sql/203): common_names, product_category, form_type, '
  'label_reference, label_version, review_notes, registrant, registered_product_name. '
  'Canonical corrections append a manual_entry source (and bump the revision); alias/notes-'
  'only corrections stay revision-silent. Never touches source_kind, verification fields, '
  'chemistry, identity or review_status.';

revoke all on function public.master_review_correct(uuid, integer, jsonb, text) from public;
grant execute on function public.master_review_correct(uuid, integer, jsonb, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. master_review_rekey — the ONLY identity path
-- ---------------------------------------------------------------------------

create or replace function public.master_review_rekey(
  p_master_id uuid,
  p_expected_revision integer,
  p_new_country text,
  p_new_scheme text,
  p_new_number text,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_master public.master_chemicals%rowtype;
  v_new_key text;
  v_existing uuid;
  v_action_id uuid := gen_random_uuid();
  v_result_revision integer;
  v_patch jsonb;
begin
  if not public.is_system_admin() then
    raise exception 'not_authorised' using errcode = '42501';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'reason_required' using errcode = '22023';
  end if;
  if p_new_country is null or p_new_country !~ '^[A-Z]{2}$' then
    raise exception 'invalid_identity' using errcode = '22023',
      detail = 'registration_country must be ISO-2 uppercase';
  end if;
  if p_new_scheme is null or p_new_scheme not in ('apvma','acvm','nz_epa','other') then
    raise exception 'invalid_identity' using errcode = '22023',
      detail = 'registration_scheme must be apvma | acvm | nz_epa | other';
  end if;
  if p_new_number is null or btrim(p_new_number) = '' then
    raise exception 'invalid_identity' using errcode = '22023',
      detail = 'registration_number must be non-empty';
  end if;

  select * into v_master
    from public.master_chemicals
   where id = p_master_id
   for update;
  if not found then
    raise exception 'master_not_found' using errcode = 'P0002';
  end if;
  if v_master.catalogue_version <> p_expected_revision then
    raise exception 'revision_mismatch' using errcode = '55000',
      detail = format('current_revision=%s expected_revision=%s',
                      v_master.catalogue_version, p_expected_revision);
  end if;

  -- Approved (and retired) rows have immutable identity: retire + create.
  if v_master.review_status <> 'candidate' then
    raise exception 'rekey_not_candidate' using errcode = '55000',
      hint = 'Approved/retired identities are immutable — retire this row and create a '
             'new candidate with the correct registration.';
  end if;

  -- A row any vineyard record points at is never silently re-pointed.
  if exists (select 1 from public.saved_chemicals sc
              where sc.master_chemical_id = p_master_id) then
    raise exception 'rekey_linked' using errcode = '55000',
      hint = 'Linked rows keep their identity — retire + create instead.';
  end if;

  v_new_key := p_new_country || ':' || p_new_scheme || ':' || upper(btrim(p_new_number));
  select id into v_existing
    from public.master_chemicals
   where registration_identity_key = v_new_key
     and id <> p_master_id;
  if v_existing is not null then
    raise exception 'identity_exists' using errcode = '23505',
      detail = format('existing_master_chemical_id=%s', v_existing);
  end if;

  v_patch := jsonb_build_object(
    'old', jsonb_build_object(
      'registration_country', v_master.registration_country,
      'registration_scheme',  v_master.registration_scheme,
      'registration_number',  v_master.registration_number,
      'registration_identity_key', v_master.registration_identity_key),
    'new', jsonb_build_object(
      'registration_country', p_new_country,
      'registration_scheme',  p_new_scheme,
      'registration_number',  p_new_number,
      'registration_identity_key', v_new_key));

  perform set_config('vinetrack.master_change_reason', p_reason, true);

  -- The unique identity constraint backstops any concurrent insert race.
  update public.master_chemicals set
    registration_country = p_new_country,
    registration_scheme  = p_new_scheme,
    registration_number  = p_new_number
  where id = p_master_id;

  select catalogue_version into v_result_revision
    from public.master_chemicals where id = p_master_id;

  insert into public.master_chemical_review_actions
    (id, master_chemical_id, action, base_revision, result_revision,
     patch, reason, performed_by)
  values
    (v_action_id, p_master_id, 'rekey', p_expected_revision, v_result_revision,
     v_patch, p_reason, auth.uid());

  return jsonb_build_object(
    'status', 'rekeyed',
    'master_chemical_id', p_master_id,
    'old_identity_key', v_master.registration_identity_key,
    'new_identity_key', v_new_key,
    'base_revision', p_expected_revision,
    'result_revision', v_result_revision,
    'action_id', v_action_id);
end$$;

comment on function public.master_review_rekey(uuid, integer, text, text, text, text) is
  'The ONLY registration-identity path (sql/203): candidate rows with zero saved_chemicals '
  'links, duplicate-identity checked. Approved/linked rows are immutable — retire + create. '
  'Registration identity is excluded from adjudication entirely.';

revoke all on function public.master_review_rekey(uuid, integer, text, text, text, text) from public;
grant execute on function public.master_review_rekey(uuid, integer, text, text, text, text) to authenticated;

commit;
