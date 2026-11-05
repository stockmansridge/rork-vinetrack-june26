-- Isolated test infrastructure only. Never run against a connected Supabase.
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE SCHEMA auth;
CREATE TABLE auth.users(id uuid PRIMARY KEY);
INSERT INTO auth.users VALUES
 ('30000000-0000-0000-0000-000000000001'),
 ('30000000-0000-0000-0000-000000000002'),
 ('30000000-0000-0000-0000-000000000003'),
 ('30000000-0000-0000-0000-000000000004'),
 ('30000000-0000-0000-0000-000000000005');
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS
 $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
GRANT USAGE ON SCHEMA auth TO authenticated;
GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated;
CREATE TABLE public.vineyards(id uuid PRIMARY KEY);
INSERT INTO public.vineyards VALUES('10000000-0000-0000-0000-000000000001'),('10000000-0000-0000-0000-000000000002');
CREATE TABLE public.paddocks(id uuid PRIMARY KEY,vineyard_id uuid REFERENCES public.vineyards(id),deleted_at timestamptz);
INSERT INTO public.paddocks VALUES('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',NULL);
GRANT SELECT ON public.paddocks TO authenticated;
CREATE TABLE public.fixture_memberships(user_id uuid,vineyard_id uuid,role text);
INSERT INTO public.fixture_memberships VALUES
 ('30000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','operator'),
 ('30000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','supervisor'),
 ('30000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000001','manager'),
 ('30000000-0000-0000-0000-000000000005','10000000-0000-0000-0000-000000000001','owner');
CREATE FUNCTION public.has_vineyard_role(v uuid,r text[]) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS
 $$ SELECT EXISTS(SELECT 1 FROM public.fixture_memberships WHERE user_id=auth.uid() AND vineyard_id=v AND role=ANY(r)) $$;
CREATE FUNCTION public.is_vineyard_member(v uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS
 $$ SELECT EXISTS(SELECT 1 FROM public.fixture_memberships WHERE user_id=auth.uid() AND vineyard_id=v) $$;
CREATE FUNCTION public.set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at=now(); RETURN NEW; END $$;
-- Projection dependency fixture: deletion must clear these columns atomically.
CREATE TABLE public.season_yield_estimates(
 id uuid DEFAULT gen_random_uuid() PRIMARY KEY,vineyard_id uuid,source_session_id uuid,
 estimate_source text,base_estimate_tonnes numeric,is_estimate_available boolean,
 setup_warnings jsonb,updated_at timestamptz,calculated_at timestamptz
);
CREATE SCHEMA vinetrack_internal;
