-- Read-only catalog inventory, including native-auth and managed dependencies.
-- No business rows, role password hashes, vault data or auth user data are selected.
with namespaces as (
 select oid,nspname from pg_namespace where nspname not like 'pg_%' and nspname <> 'information_schema'
), relations as (
 select n.nspname,c.relname,c.relkind,c.relrowsecurity,c.relforcerowsecurity,
        pg_get_userbyid(c.relowner) owner,c.relacl::text privileges
 from pg_class c join namespaces n on n.oid=c.relnamespace
 where c.relkind in ('r','p','v','m','S','f')
), functions as (
 select n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) arguments,
        pg_get_userbyid(p.proowner) owner,p.prosecdef,p.proconfig,p.proacl::text privileges,
        md5(pg_get_functiondef(p.oid)) definition_hash
 from pg_proc p join namespaces n on n.oid=p.pronamespace where p.prokind in ('f','p')
), columns as (
 select n.nspname,c.relname,a.attname,a.attnum,format_type(a.atttypid,a.atttypmod) type,
        a.attnotnull,a.attidentity,a.attgenerated,a.attacl::text privileges,
        pg_get_expr(d.adbin,d.adrelid) default_expression
 from pg_attribute a join pg_class c on c.oid=a.attrelid join namespaces n on n.oid=c.relnamespace
 left join pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum
 where a.attnum>0 and not a.attisdropped and c.relkind in ('r','p','v','m','f')
), triggers as (
 select n.nspname,c.relname,t.tgname,t.tgenabled,pg_get_triggerdef(t.oid) definition
 from pg_trigger t join pg_class c on c.oid=t.tgrelid join namespaces n on n.oid=c.relnamespace where not t.tgisinternal
), views as (
 select n.nspname,c.relname,md5(pg_get_viewdef(c.oid,true)) definition_hash
 from pg_class c join namespaces n on n.oid=c.relnamespace where c.relkind in ('v','m')
), indexes as (
 select n.nspname,c.relname table_name,i.relname index_name,k.indisvalid,k.indisready,
        pg_get_indexdef(k.indexrelid) definition
 from pg_index k join pg_class c on c.oid=k.indrelid join pg_class i on i.oid=k.indexrelid
 join namespaces n on n.oid=c.relnamespace
), constraints as (
 select n.nspname,c.relname,k.conname,k.contype,k.convalidated,pg_get_constraintdef(k.oid) definition
 from pg_constraint k join namespaces n on n.oid=k.connamespace left join pg_class c on c.oid=k.conrelid
)
select jsonb_build_object(
 'server_version',current_setting('server_version'),
 'native_auth_users_present',to_regclass('auth.users') is not null,
 'extensions',(select jsonb_agg(jsonb_build_object('name',e.extname,'version',e.extversion,'schema',n.nspname) order by e.extname) from pg_extension e join pg_namespace n on n.oid=e.extnamespace),
 'schemas',(select jsonb_agg(jsonb_build_object('name',n.nspname,'owner',pg_get_userbyid(n.nspowner),'privileges',n.nspacl::text) order by n.nspname) from pg_namespace n where n.oid in (select oid from namespaces)),
 'roles',(select jsonb_agg(jsonb_build_object('name',rolname,'superuser',rolsuper,'inherit',rolinherit,'create_role',rolcreaterole,'create_db',rolcreatedb,'login',rolcanlogin,'replication',rolreplication,'bypass_rls',rolbypassrls,'config',rolconfig) order by rolname) from pg_roles where rolname not like 'pg_%' and rolname <> 'cli_login_postgres'),
 'memberships',(select jsonb_agg(jsonb_build_object('role',pg_get_userbyid(roleid),'member',pg_get_userbyid(member),'grantor',pg_get_userbyid(grantor),'admin',admin_option,'inherit',inherit_option,'set',set_option) order by roleid,member) from pg_auth_members where pg_get_userbyid(member) <> 'cli_login_postgres'),
 'relations',(select jsonb_agg(to_jsonb(r) order by nspname,relname) from relations r),
 'columns',(select jsonb_agg(to_jsonb(c) order by nspname,relname,attnum) from columns c),
 'functions',(select jsonb_agg(to_jsonb(f) order by nspname,proname,arguments) from functions f),
 'triggers',(select jsonb_agg(to_jsonb(t) order by nspname,relname,tgname) from triggers t),
 'constraints',(select jsonb_agg(to_jsonb(c) order by nspname,relname,conname) from constraints c),
 'views',(select jsonb_agg(to_jsonb(v) order by nspname,relname) from views v),
 'indexes',(select jsonb_agg(to_jsonb(i) order by nspname,table_name,index_name) from indexes i),
 'policies',(select jsonb_agg(to_jsonb(p) order by schemaname,tablename,policyname) from pg_policies p where schemaname in (select nspname from namespaces)),
 'default_privileges',(select jsonb_agg(jsonb_build_object('role',pg_get_userbyid(d.defaclrole),'schema',n.nspname,'type',d.defaclobjtype,'acl',d.defaclacl::text) order by d.defaclrole,d.defaclnamespace,d.defaclobjtype) from pg_default_acl d left join pg_namespace n on n.oid=d.defaclnamespace)
);
