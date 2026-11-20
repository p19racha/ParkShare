-- Run as the database administrator after applying migrations. All fixtures roll back.
begin;

insert into auth.users(id) values
 ('a0000000-0000-4000-8000-000000000001'),
 ('a0000000-0000-4000-8000-000000000002'),
 ('a0000000-0000-4000-8000-000000000003');
insert into public.host_accounts values ('a0000000-0000-4000-8000-000000000001','acct_test');
insert into public.spaces(id,owner,title,area,lat,lng,rate,fit,method,published)
 values('a1000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000001',
 'Test spot','Test area',37.79,-122.412,12,'Standard car','Gate code',true);
insert into public.space_access values ('a1000000-0000-4000-8000-000000000001','Test instructions');

do $$
declare
 host constant uuid := 'a0000000-0000-4000-8000-000000000001';
 driver constant uuid := 'a0000000-0000-4000-8000-000000000002';
 other constant uuid := 'a0000000-0000-4000-8000-000000000003';
 spot constant uuid := 'a1000000-0000-4000-8000-000000000001';
 b public.bookings;
 checked public.bookings;
 saved uuid;
 s public.spaces;
begin
 assert not has_table_privilege('authenticated', 'public.space_access', 'SELECT');
 assert not has_function_privilege('authenticated', 'public.booking_access(uuid,uuid)', 'EXECUTE');
 assert not has_function_privilege('authenticated', 'public.advance_booking(uuid,text,uuid)', 'EXECUTE');
 select * into strict s from public.spaces where id=spot;
 assert public.open_minutes(s,'2026-11-21 07:56:00+00') > 240, '24-hour opening must span midnight';
 s.hours := '{"5":[600,660]}';
 assert public.open_minutes(s,'2026-11-20 18:30:00+00') = 30, 'Local weekly opening time';

 begin
   perform public.reserve_space(spot, driver, 15, 11);
   raise exception 'A stale quote was accepted';
 exception when raise_exception then
   if sqlerrm <> 'The price changed. Refresh the listing and review the current rate' then raise; end if;
 end;
 b := public.reserve_space(spot, driver, 15, 12);
 assert b.stage='hold';
 assert not exists(select 1 from public.discover_spaces(37,-123,38,-122) x where x.id=spot);
 assert public.booking_access(b.id, driver) is null;
 assert public.booking_access(b.id, host)='Test instructions';
 begin
   perform public.reserve_space(spot, other, 15, 12);
   raise exception 'A second driver received the same spot';
 exception when raise_exception then
   if sqlerrm <> 'This space is unavailable for the selected stay' then raise; end if;
 end;
 b := public.advance_booking(b.id,'authorize');
 checked := public.advance_booking(b.id,'authorize');
 assert b.stage='reserved' and b.expires=checked.expires, 'Duplicate callbacks must preserve expiry';
 assert public.booking_access(b.id, driver)='Test instructions';
 assert public.booking_access(b.id, other) is null;
 begin
   perform public.advance_booking(b.id,'start',other);
   raise exception 'An unrelated user started the booking';
 exception when raise_exception then
   if sqlerrm <> 'This reservation cannot be started' then raise; end if;
 end;
 b := public.advance_booking(b.id,'start',driver);
 assert b.stage='active' and b.started is not null;
 update public.bookings set started=clock_timestamp()-interval '4 minutes 1 second' where id=b.id;
 b := public.advance_booking(b.id,'end', driver);
 assert b.stage='completed' and b.amount=60 and b.payment='capture_pending';
 assert public.booking_access(b.id, driver) is null;
 assert not (select occupied from public.spaces where id=spot);
 assert exists(select 1 from public.discover_spaces(37,-123,38,-122) x where x.id=spot);

 b := public.reserve_space(spot,driver,15,12);
 update public.bookings set expires=clock_timestamp()-interval '1 second' where id=b.id;
 checked := public.reserve_space(spot,other,15,12);
 b := public.advance_booking(b.id,'authorize');
 assert b.stage='expired' and b.payment='release_pending', 'Late authorizations must be reversed';
 checked := public.advance_booking(checked.id,'authorize');
 update public.bookings set expires=clock_timestamp()-interval '1 second' where id=checked.id;
 checked := public.advance_booking(checked.id,'tick');
 assert checked.stage='expired' and public.booking_access(checked.id,other) is null;

 b := public.reserve_space(spot,driver,15,12);
 b := public.advance_booking(b.id,'cancel',driver);
 assert b.stage='cancelled' and b.payment='release_pending';
 b := public.reserve_space(spot,driver,15,12);
 b := public.advance_booking(b.id,'authorize');
 b := public.advance_booking(b.id,'start',driver);
 update public.bookings set started=clock_timestamp()-interval '16 minutes',
 expires=clock_timestamp()-interval '1 minute' where id=b.id;
 b := public.advance_booking(b.id,'tick');
 assert b.stage='overdue' and b.amount=180;
 assert (select occupied from public.spaces where id=spot);
 checked := public.advance_booking(b.id,'end',host);
 assert checked.stage='completed' and checked.amount=b.amount and checked.stopped=b.stopped;
 assert not (select occupied from public.spaces where id=spot);

 select * into strict s from public.spaces where id=spot;
 saved := public.save_space(host, null, to_jsonb(s) || '{"lat":37.79177}', 'Another address');
 assert (select lat from public.spaces where id=saved)=37.792;
 perform public.save_space(host,saved,to_jsonb(s),'Updated address');
 assert (select instructions from public.space_access where space=saved)='Updated address';
 assert not exists(select 1 from public.host_accounts where owner=other);
 saved := public.save_space(other, null, to_jsonb(s) || '{"title":"Pilot listing"}', 'Private pilot instructions');
 assert exists(select 1 from public.discover_spaces(37,-123,38,-122) x
  where x.id=saved and x.title='Pilot listing' and not to_jsonb(x) ? 'instructions');
 begin
   perform public.save_space(driver,saved,to_jsonb(s),'Unauthorized edit');
   raise exception 'An unrelated user edited the space';
 exception when raise_exception then
   if sqlerrm <> 'Listing is occupied or belongs to another account' then raise; end if;
 end;
 perform public.save_space(other,saved,to_jsonb(s) || '{"title":"Updated pilot listing"}','Private pilot instructions');
 assert exists(select 1 from public.discover_spaces(37,-123,38,-122) x where x.id=saved and x.title='Updated pilot listing');
 perform public.save_space(other,saved,to_jsonb(s) || '{"published":false}','Private pilot instructions');
 assert not exists(select 1 from public.discover_spaces(37,-123,38,-122) x where x.id=saved);
 assert exists(select 1 from public.availability_updates where space=saved);
 assert not has_function_privilege('anon','public.save_space(uuid,uuid,jsonb,text)','EXECUTE');
 assert not has_table_privilege('anon','public.spaces','INSERT');
end
$$;

set local role service_role;
select public.discover_spaces(37,-123,38,-122);
select public.reserve_space('a1000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000002',15,12);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-000000000002',true);
do $$
begin
 assert exists(select 1 from public.bookings);
 assert not exists(select 1 from public.bookings where driver='a0000000-0000-4000-8000-000000000003');
end
$$;
reset role;

rollback;
