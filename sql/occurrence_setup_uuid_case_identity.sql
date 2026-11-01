-- Preserve the deployed function (including newer actor/auth checks and ACLs).
-- Change only selected-block membership from JSON text equality to UUID identity.
-- No data changes, old request rewriting, permission widening or receipt replacement.
do $migration$
declare
  definition text;
  needle constant text := $old$not provided_blocks ? (i->>'blockId')$old$;
  replacement constant text := $new$not exists(select 1 from jsonb_array_elements_text(provided_blocks) selected(id) where selected.id::uuid = (i->>'blockId')::uuid)$new$;
begin
  definition := pg_get_functiondef('public.create_trip_with_occurrences_v1(uuid,jsonb,jsonb)'::regprocedure);
  if strpos(definition, replacement) > 0 and strpos(definition, needle) = 0 then return; end if;
  if (length(definition) - length(replace(definition, needle, ''))) / length(needle) <> 1 then
    raise exception 'Occurrence setup comparison changed; review the live function before applying this repair.';
  end if;
  execute replace(definition, needle, replacement);
end;
$migration$;
