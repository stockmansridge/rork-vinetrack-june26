-- Run against an isolated database after sql/250, or in a rolled-back transaction.
-- Clone the *actual* production check onto an isolated probe so no vineyard data is touched.
do $$
declare
  definition text;
  source text;
begin
  select pg_get_constraintdef(oid) into definition
  from pg_constraint
  where conrelid = 'public.saved_chemicals'::regclass
    and conname = 'saved_chemicals_entry_source_check'
    and contype = 'c';
  if definition is null then raise exception 'T250.1: missing Saved Chemical source check'; end if;
  create temporary table saved_chemical_source_probe (entry_source text) on commit drop;
  execute format('alter table saved_chemical_source_probe add constraint source_check %s', definition);
  foreach source in array array['customer_entered', 'register_lookup', 'master_catalogue', 'label_lookup'] loop
    insert into saved_chemical_source_probe values (source);
  end loop;
  insert into saved_chemical_source_probe values (null);
  if (select count(*) from saved_chemical_source_probe) <> 5 then
    raise exception 'T250.2: canonical or legacy source refused';
  end if;
  foreach source in array array['manual_v2', 'master_catalogue_v2', 'label_lookup_v2'] loop
    begin
      insert into saved_chemical_source_probe values (source);
      raise exception 'T250.3: obsolete source accepted: %', source;
    exception when check_violation then
      if exists (select 1 from saved_chemical_source_probe where entry_source = source) then
        raise exception 'T250.3: obsolete source inserted: %', source;
      end if;
    end;
  end loop;
end $$;
