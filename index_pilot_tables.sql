\set ON_ERROR_STOP

do $$
begin
  if (select setting from pg_settings where name='server_version_num')<'13'
  then
    raise 'This library works only for PostgreSQL 13 or higher!';
  end if;
end; $$;



create schema if not exists index_pilot;

--history of performed reindex action
create table index_pilot.reindex_history
(
  id bigserial primary key,
  entry_timestamp timestamptz not null default now(),
  indexrelid oid,
  datid oid,
  datname name not null,
  schemaname name not null,
  relname name not null,
  indexrelname name not null,
  server_version_num integer not null default current_setting('server_version_num')::integer,
  indexsize_before bigint not null,
  indexsize_after bigint not null,
  estimated_tuples bigint not null,
  reindex_duration interval not null,
  analyze_duration interval not null
);
create index reindex_history_oid_index on index_pilot.reindex_history(datid, indexrelid);
create index reindex_history_index on index_pilot.reindex_history(datname, schemaname, relname, indexrelname);

--history of index sizes (not really neccessary to keep all this data but very useful for future analyzis of bloat trends
create table index_pilot.index_current_state
(
  id bigserial primary key,
  mtime timestamptz not null default now(),
  indexrelid oid not null,
  datid oid not null,
  datname name not null,
  schemaname name not null,
  relname name not null,
  indexrelname name not null,
  indexsize bigint not null,
  indisvalid boolean not null default true,
  estimated_tuples bigint not null,
  best_ratio real
);
create unique index index_current_state_oid_index on index_pilot.index_current_state(datid, indexrelid);
create index index_current_state_index on index_pilot.index_current_state(datname, schemaname, relname, indexrelname);

--settings table
create table index_pilot.config
(
  id bigserial primary key,
  datname name,
  schemaname name,
  relname name,
  indexrelname name,
  key text not null,
  value text,
  comment text
);
create unique index config_u1 on index_pilot.config(key) where datname is null;
create unique index config_u2 on index_pilot.config(key, datname) where schemaname is null;
create unique index config_u3 on index_pilot.config(key, datname, schemaname) where relname is null;
create unique index config_u4 on index_pilot.config(key, datname, schemaname, relname) where indexrelname is null;
create unique index config_u5 on index_pilot.config(key, datname, schemaname, relname, indexrelname);
alter table index_pilot.config add constraint inherit_check1 check (indexrelname is null or indexrelname is not null and relname    is not null);
alter table index_pilot.config add constraint inherit_check2 check (relname      is null or relname      is not null and schemaname is not null);
alter table index_pilot.config add constraint inherit_check3 check (schemaname   is null or schemaname   is not null and datname    is not null);


create view index_pilot.history as
  select date_trunc('second', entry_timestamp)::timestamp as ts,
       datname as db, schemaname as schema, relname as table,
       indexrelname as index, pg_size_pretty(indexsize_before) as size_before,
       pg_size_pretty(indexsize_after) as size_after,
       case when indexsize_after is not null and indexsize_after > 0 
            then (indexsize_before::float/indexsize_after)::numeric(12,2) 
            else null end as ratio,
       pg_size_pretty(estimated_tuples) as tuples, date_trunc('seconds', reindex_duration) as duration
  from index_pilot.reindex_history order by id DESC;


--default GLOBAL settings
insert into index_pilot.config (key, value, comment) values
('index_size_threshold', '10MB', 'ignore indexes under 10MB size unless forced entries found in history'),
('index_rebuild_scale_factor', '2', 'rebuild indexes by default estimated bloat over 2x'),
('minimum_reliable_index_size', '128kB', 'small indexes not reliable to use as gauge'),
('reindex_history_retention_period','10 years', 'reindex history default retention pcommenteriod')
;

--default per any DB setting
insert into index_pilot.config (datname, schemaname, relname, indexrelname, key, value, comment) values
('*', 'repack', null,      null, 'skip', 'true', 'skip repack internal schema'),
('*', 'pgq',    'event_*', null, 'skip', 'true', 'skip pgq transient tables')
;


--current version of table structure
create table index_pilot.tables_version
(
	version smallint not null
);
create unique index tables_version_single_row on  index_pilot.tables_version((version is not null));
insert into index_pilot.tables_version values(8);


-- current proccessed index can be invalid
create table index_pilot.current_processed_index
(
  id bigserial primary key,
  mtime timestamptz not null default now(),
  datname name not null,
  schemaname name not null,
  relname name not null,
  indexrelname name not null
);
