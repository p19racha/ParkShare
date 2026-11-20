-- Keep historic USD quotes intact. Hosts set the hourly INR price explicitly.
alter table public.spaces add column hourly_paise integer check (hourly_paise between 100 and 1000000);
alter table public.space_access
 add column entrance_lat double precision check (entrance_lat between -90 and 90),
 add column entrance_lng double precision check (entrance_lng between -180 and 180);
alter table public.bookings add column hourly_paise integer check (hourly_paise between 100 and 1000000);
alter table public.bookings drop constraint bookings_payment_check;
alter table public.bookings add constraint bookings_payment_check check
 (payment in ('awaiting_authorization','authorized','capture_pending','paid','capture_failed',
 'release_pending','released','pay_at_spot'));
alter table public.bookings alter column destination drop not null;
create index inr_booking_expiry on public.bookings(expires)
 where hourly_paise is not null and stage in ('reserved','active');

create or replace function public.advance_booking(bid uuid, action text, actor uuid default null)
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
  update public.bookings set stage='cancelled', payment=case when hourly_paise is null then 'release_pending' else payment end where id=bid returning * into b;
 elsif action = 'tick' and b.stage in ('hold','reserved') and b.expires <= t then
  update public.bookings set stage='expired', payment=case when hourly_paise is null then 'release_pending' else payment end where id=bid returning * into b;
 elsif (action = 'tick' and b.stage='active' and b.expires <= t)
    or (action = 'end' and (b.driver = actor or b.owner = actor) and b.stage in ('active','overdue')) then
  if b.stage='overdue' then
   update public.bookings set stage='completed' where id=bid returning * into b;
  else
   update public.bookings set
    stage=case when action='tick' then 'overdue' else 'completed' end,
    stopped=least(t,b.expires),
    amount=case when b.hourly_paise is null then
      greatest(50,least(b.minutes,ceil(extract(epoch from least(t,b.expires)-b.started)/60)::int)*b.rate)
      else ceil(b.hourly_paise * least(b.minutes,ceil(extract(epoch from least(t,b.expires)-b.started)/60)) / 60)::int end,
    payment=case when b.hourly_paise is null then 'capture_pending' else payment end
    where id=bid returning * into b;
  end if;
 elsif action <> 'tick' then
  raise exception 'This booking action is unavailable';
 end if;
 return b;
end
$$;

create or replace function public.save_space(uid uuid, sid uuid, data jsonb, private_instructions text)
returns uuid language plpgsql set search_path = '' as $$
declare saved uuid;
begin
 if not exists(select 1 from pg_catalog.pg_timezone_names where name=data->>'zone') then
  raise exception 'Enter a valid IANA time zone.';
 end if;
 if sid is not null and not exists(select 1 from public.spaces where id=sid and owner=uid) then
  raise exception 'Listing is occupied or belongs to another account';
 end if;
 insert into public.spaces(id,owner,title,area,lat,lng,rate,fit,method,zone,hours,published,hourly_paise)
 values(coalesce(sid,gen_random_uuid()),uid,data->>'title',data->>'area',
  round((data->>'lat')::numeric,3),round((data->>'lng')::numeric,3),
  (data->>'rate')::int,data->>'fit',data->>'method',data->>'zone',
  data->'hours',(data->>'published')::boolean,(data->>'hourly_paise')::int)
 on conflict (id) do update set title=excluded.title,area=excluded.area,lat=excluded.lat,
  lng=excluded.lng,rate=excluded.rate,fit=excluded.fit,method=excluded.method,
  zone=excluded.zone,hours=excluded.hours,published=excluded.published,hourly_paise=coalesce(excluded.hourly_paise,spaces.hourly_paise)
 where spaces.owner=uid and (not spaces.occupied or not excluded.published
   and (spaces.title,spaces.area,spaces.lat,spaces.lng,spaces.rate,spaces.fit,spaces.method,spaces.zone,spaces.hours,spaces.hourly_paise)
   is not distinct from (excluded.title,excluded.area,excluded.lat,excluded.lng,excluded.rate,
    excluded.fit,excluded.method,excluded.zone,excluded.hours,coalesce(excluded.hourly_paise,spaces.hourly_paise)))
 returning id into saved;
 if saved is null then raise exception 'Listing is occupied or belongs to another account'; end if;
 insert into public.space_access(space,instructions,entrance_lat,entrance_lng)
 values(saved,private_instructions,(data->>'lat')::double precision,(data->>'lng')::double precision)
 on conflict(space) do update set instructions=excluded.instructions,
 entrance_lat=excluded.entrance_lat,entrance_lng=excluded.entrance_lng
 where not (select occupied from public.spaces where id=saved);
 return saved;
end
$$;
create or replace function public.reserve_space(sid uuid, uid uuid, duration integer, quoted_rate integer)
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
  or s.demo or s.hourly_paise is not null or s.occupied or s.owner=uid
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

create function public.reserve_inr_space(sid uuid, uid uuid, duration integer, quoted_paise integer)
returns public.bookings language plpgsql set search_path = '' as $$
declare
 s public.spaces;
 b public.bookings;
begin
 -- Booking locks precede listing locks, matching advance_booking.
 for b in select * from public.bookings where space=sid and stage in ('hold','reserved')
  and expires<=clock_timestamp() loop
   perform public.advance_booking(b.id,'tick');
 end loop;
 select * into strict s from public.spaces where id=sid for update;
 if s.hourly_paise is null or quoted_paise is distinct from s.hourly_paise then
  raise exception 'The price changed. Refresh the listing and review the current rate';
 end if;
 select * into b from public.bookings where space=sid and driver=uid and stage='reserved'
  and hourly_paise=quoted_paise and minutes=duration and expires>clock_timestamp();
 if found then return b; end if;
 if duration is null or duration not between 15 and 240 or not s.published or s.demo
  or s.occupied or s.owner=uid or public.open_minutes(s,clock_timestamp()) < duration+15 then
   raise exception 'This space is unavailable for the selected stay';
 end if;
 insert into public.bookings(space,driver,owner,title,rate,hourly_paise,minutes,expires,stage,payment)
 values(s.id,uid,s.owner,s.title,s.rate,s.hourly_paise,duration,
   clock_timestamp()+interval '15 minutes','reserved','pay_at_spot')
 returning * into b;
 return b;
end
$$;

create function public.expire_inr_bookings()
returns void language plpgsql set search_path = '' as $$
declare bid uuid;
begin
 for bid in select id from public.bookings where hourly_paise is not null
  and stage in ('reserved','active') and expires<=clock_timestamp()
  order by expires limit 100 for update skip locked loop
   perform public.advance_booking(bid,'tick');
 end loop;
end
$$;

create function public.booking_entrance(bid uuid, uid uuid)
returns jsonb language sql stable set search_path = '' as $$
 select jsonb_build_object('instructions',a.instructions,'lat',a.entrance_lat,'lng',a.entrance_lng)
 from public.bookings b join public.space_access a on a.space=b.space
 where b.id=bid and (b.owner=uid or (b.driver=uid and
  ((b.stage='reserved' and b.expires>now()) or b.stage in ('active','overdue'))))
$$;

revoke execute on function public.reserve_inr_space(uuid,uuid,integer,integer),
 public.expire_inr_bookings(),public.booking_entrance(uuid,uuid) from public,anon,authenticated;
grant execute on function public.reserve_inr_space(uuid,uuid,integer,integer),
 public.expire_inr_bookings(),public.booking_entrance(uuid,uuid) to service_role;
