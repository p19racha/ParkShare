create table public.spaces (
 id uuid primary key default gen_random_uuid(),
 owner uuid not null references auth.users,
 title text not null check (length(title) between 1 and 100),
 area text not null,
 lat double precision not null check (lat between -90 and 90),
 lng double precision not null check (lng between -180 and 180),
 rate integer not null check (rate between 4 and 500),
 fit text not null,
 method text not null check (method in ('Open driveway','Gate code','Attended handoff')),
 zone text not null default 'America/Los_Angeles',
 hours jsonb not null default '{"1":[0,1440],"2":[0,1440],"3":[0,1440],"4":[0,1440],"5":[0,1440],"6":[0,1440],"7":[0,1440]}'::jsonb,
 published boolean not null default false,
 occupied boolean not null default false,
 demo boolean not null default false
);
create table public.space_access (
 space uuid primary key references public.spaces,
 instructions text not null
);
create table public.host_accounts (
 owner uuid primary key references auth.users,
 stripe_id text not null unique
);
create table public.bookings (
 id uuid primary key default gen_random_uuid(),
 space uuid not null references public.spaces,
 driver uuid not null references auth.users,
 owner uuid not null references auth.users,
 title text not null,
 rate integer not null,
 minutes integer not null,
 stage text not null default 'hold'
  check (stage in ('hold','reserved','active','overdue','completed','cancelled','expired')),
 payment text not null default 'awaiting_authorization'
  check (payment in ('awaiting_authorization','authorized','capture_pending','paid','capture_failed','release_pending','released')),
 expires timestamptz not null,
 started timestamptz,
 stopped timestamptz,
 amount integer,
 intent text unique,
 destination text not null,
 created timestamptz not null default now()
);
create unique index one_occupant on public.bookings(space)
 where stage in ('hold','reserved','active','overdue');
create index bookings_payment on public.bookings(payment, expires);

alter table public.spaces enable row level security;
alter table public.space_access enable row level security;
alter table public.host_accounts enable row level security;
alter table public.bookings enable row level security;

revoke all on public.spaces, public.space_access, public.host_accounts, public.bookings from anon, authenticated;
grant select on public.spaces, public.bookings to authenticated;
grant all on public.spaces, public.space_access, public.host_accounts, public.bookings to service_role;
create policy visible_spaces on public.spaces for select to authenticated using (published or owner = auth.uid());
create policy my_bookings on public.bookings for select to authenticated using (driver = auth.uid() or owner = auth.uid());

-- The public signal carries no listing details. A pause still reaches subscribers
-- after the listing becomes invisible under the spaces policy.
create table public.availability_updates (
 space uuid primary key references public.spaces on delete cascade,
 changed timestamptz not null
);
alter table public.availability_updates enable row level security;
revoke all on public.availability_updates from anon, authenticated;
grant select on public.availability_updates to authenticated;
create policy public_availability_changes on public.availability_updates for select
 to authenticated using (true);
alter publication supabase_realtime add table public.availability_updates, public.bookings;

create function public.notify_availability() returns trigger language plpgsql
security definer set search_path = '' as $$
begin
 if new.published or (tg_op='UPDATE' and old.published) then
  insert into public.availability_updates(space,changed) values(new.id,clock_timestamp())
  on conflict (space) do update set changed=excluded.changed;
 end if;
 return new;
end
$$;
revoke execute on function public.notify_availability() from public, anon, authenticated;
create trigger public_availability after insert or update on public.spaces
 for each row execute function public.notify_availability();

create function public.open_minutes(s public.spaces, at_time timestamptz)
returns integer language plpgsql stable set search_path = '' as $$
declare
  local_time timestamp := at_time at time zone s.zone;
  day_start timestamp := date_trunc('day',local_time);
  opening jsonb := s.hours -> extract(isodow from local_time)::int::text;
  next_opening jsonb;
  minute_of_day int := extract(hour from local_time)::int * 60 + extract(minute from local_time)::int;
  closes int;
  closing_time timestamptz;
begin
  if opening is null or minute_of_day < (opening->>0)::int or minute_of_day >= (opening->>1)::int then
    return 0;
  end if;
  closes := (opening->>1)::int;
  if closes=1440 then
    next_opening := s.hours -> extract(isodow from day_start+interval '1 day')::int::text;
    if (next_opening->>0)::int=0 then closes := closes+(next_opening->>1)::int; end if;
  end if;
  closing_time := (day_start+make_interval(mins=>closes)) at time zone s.zone;
  return greatest(0,floor(extract(epoch from closing_time-at_time)/60)::int);
end
$$;

create function public.advance_booking(bid uuid, action text, actor uuid default null)
returns public.bookings language plpgsql set search_path = '' as $$
declare
 b public.bookings;
 t timestamptz;
begin
 select * into strict b from public.bookings where id=bid for update;
 t := clock_timestamp();
 if action = 'authorize' then
  if b.stage = 'hold' and b.expires > t then
   update public.bookings set stage='reserved', payment='authorized', expires=t+interval '10 minutes'
    where id=bid returning * into b;
  end if;
 elsif action = 'start' then
  if b.driver <> actor or actor is null or b.stage <> 'reserved' or b.expires <= t then
   raise exception 'This reservation cannot be started';
  end if;
  if (select public.open_minutes(s,t) from public.spaces s where s.id=b.space) < b.minutes then
   raise exception 'The selected duration no longer fits opening hours';
  end if;
  update public.bookings set stage='active', started=t, expires=t+make_interval(mins=>b.minutes)
   where id=bid returning * into b;
 elsif action = 'cancel' and b.driver = actor and b.stage in ('hold','reserved') then
  update public.bookings set stage='cancelled', payment='release_pending' where id=bid returning * into b;
 elsif action = 'tick' and b.stage in ('hold','reserved') and b.expires <= t then
  update public.bookings set stage='expired', payment='release_pending' where id=bid returning * into b;
 elsif (action = 'tick' and b.stage='active' and b.expires <= t)
    or (action = 'end' and (b.driver = actor or b.owner = actor) and b.stage in ('active','overdue')) then
  if b.stage='overdue' then
   update public.bookings set stage='completed' where id=bid returning * into b;
  else
   update public.bookings set
    stage=case when action='tick' then 'overdue' else 'completed' end,
    stopped=least(t,b.expires),
    amount=greatest(50,least(b.minutes,ceil(extract(epoch from least(t,b.expires)-b.started)/60)::int)*b.rate),
    payment='capture_pending'
    where id=bid returning * into b;
  end if;
 elsif action <> 'tick' then
  raise exception 'This booking action is unavailable';
 end if;
 return b;
end
$$;

create function public.sync_occupancy() returns trigger language plpgsql
security definer set search_path = '' as $$
begin
 if tg_op='INSERT' or new.stage is distinct from old.stage then
  update public.spaces set occupied=new.stage in ('hold','reserved','active','overdue')
   where id=new.space;
 end if;
 return new;
end
$$;
create trigger booking_availability after insert or update on public.bookings
 for each row execute function public.sync_occupancy();

create function public.reserve_space(sid uuid, uid uuid, duration integer, quoted_rate integer)
returns public.bookings language plpgsql set search_path = '' as $$
declare
 s public.spaces;
 b public.bookings;
 account text;
begin
 -- Resolve expired holds in booking-lock order before locking the listing.
 for b in select * from public.bookings where space=sid and stage in ('hold','reserved')
  and expires <= clock_timestamp() loop
   perform public.advance_booking(b.id,'tick');
 end loop;
 select * into strict s from public.spaces where id=sid for update;
 if quoted_rate is distinct from s.rate then
  raise exception 'The price changed. Refresh the listing and review the current rate';
 end if;
 if duration is null or duration not between 15 and 240 or not s.published
  or s.demo or s.occupied or s.owner=uid
  or public.open_minutes(s,clock_timestamp()) < duration+15 then
   raise exception 'This space is unavailable for the selected stay';
 end if;
 select stripe_id into strict account from public.host_accounts where owner=s.owner;
 insert into public.bookings(space,driver,owner,title,rate,minutes,expires,destination)
 values(s.id,uid,s.owner,s.title,s.rate,duration,clock_timestamp()+interval '5 minutes',account)
 returning * into b;
 return b;
end
$$;

revoke execute on function public.reserve_space(uuid,uuid,integer,integer),
 public.advance_booking(uuid,text,uuid), public.sync_occupancy(),
 public.open_minutes(public.spaces,timestamptz) from public, anon, authenticated;
grant execute on function public.reserve_space(uuid,uuid,integer,integer),
 public.advance_booking(uuid,text,uuid), public.open_minutes(public.spaces,timestamptz) to service_role;

create function public.save_space(uid uuid, sid uuid, data jsonb, private_instructions text)
returns uuid language plpgsql set search_path = '' as $$
declare saved uuid;
begin
 if not exists(select 1 from pg_catalog.pg_timezone_names where name=data->>'zone') then
  raise exception 'Enter a valid IANA time zone.';
 end if;
 if sid is not null and not exists(select 1 from public.spaces where id=sid and owner=uid) then
  raise exception 'Listing is occupied or belongs to another account';
 end if;
 insert into public.spaces(id,owner,title,area,lat,lng,rate,fit,method,zone,hours,published)
 values(coalesce(sid,gen_random_uuid()),uid,data->>'title',data->>'area',
  round((data->>'lat')::numeric,3),round((data->>'lng')::numeric,3),
  (data->>'rate')::int,data->>'fit',data->>'method',data->>'zone',
  data->'hours',(data->>'published')::boolean)
 on conflict (id) do update set title=excluded.title,area=excluded.area,lat=excluded.lat,
  lng=excluded.lng,rate=excluded.rate,fit=excluded.fit,method=excluded.method,
  zone=excluded.zone,hours=excluded.hours,published=excluded.published
 where spaces.owner=uid and (not spaces.occupied or not excluded.published
   and (spaces.title,spaces.area,spaces.lat,spaces.lng,spaces.rate,spaces.fit,spaces.method,spaces.zone,spaces.hours)
   is not distinct from (excluded.title,excluded.area,excluded.lat,excluded.lng,excluded.rate,
    excluded.fit,excluded.method,excluded.zone,excluded.hours))
 returning id into saved;
 if saved is null then raise exception 'Listing is occupied or belongs to another account'; end if;
 insert into public.space_access(space,instructions) values(saved,private_instructions)
 on conflict(space) do update set instructions=excluded.instructions
 where not (select occupied from public.spaces where id=saved);
 return saved;
end
$$;
revoke execute on function public.save_space(uuid,uuid,jsonb,text) from public, anon, authenticated;
grant execute on function public.save_space(uuid,uuid,jsonb,text) to service_role;

create function public.discover_spaces(south double precision, west double precision,
 north double precision, east double precision)
returns setof public.spaces language sql stable set search_path = '' as $$
 select s.* from public.spaces s
 where published and not occupied and public.open_minutes(s,now()) >= 30
 and lat between south and north
 and (case when west <= east then lng between west and east else lng >= west or lng <= east end)
 order by demo, title limit 150
$$;

create function public.booking_access(bid uuid, uid uuid)
returns text language sql stable set search_path = '' as $$
 select a.instructions
 from public.bookings b join public.space_access a on a.space=b.space
 where b.id=bid and (b.owner=uid or (b.driver=uid and
  ((b.stage='reserved' and b.expires>now()) or b.stage in ('active','overdue'))))
$$;
revoke execute on function public.discover_spaces(double precision,double precision,double precision,double precision),
 public.booking_access(uuid,uuid) from public, anon, authenticated;
grant execute on function public.discover_spaces(double precision,double precision,double precision,double precision),
 public.booking_access(uuid,uuid) to service_role;
