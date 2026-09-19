begin;

revoke insert, update, delete
on public.vineyard_insights_deletions
from authenticated;

revoke delete
on public.vintage_note_types
from authenticated;

commit;
