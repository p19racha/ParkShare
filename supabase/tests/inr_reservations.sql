begin;
insert into auth.users(id) values
 ('c0000000-0000-4000-8000-000000000001'),
 ('c0000000-0000-4000-8000-000000000002'),
 ('c0000000-0000-4000-8000-000000000003');

do $$
declare
 host constant uuid := 'c0000000-0000-4000-8000-000000000001';
 driver constant uuid := 'c0000000-0000-4000-8000-000000000002';
 other constant uuid := 'c0000000-0000-4000-8000-000000000003';
 spot uuid;
 b public.bookings;
begin
 spot := public.save_space(host,null,'{
  "title":"Pilot entrance","area":"Central","fit":"Car","method":"Gate code",
  "lat":22.61234,"lng":79.43456,"rate":12,"hourly_paise":7500,"zone":"Asia/Kolkata",
  "hours":{"1":[0,1440],"2":[0,1440],"3":[0,1440],"4":[0,1440],"5":[0,1440],"6":[0,1440],"7":[0,1440]},
  "published":true
 }','Ring the gate bell');
 assert (select lat from public.spaces where id=spot)=22.612;
 assert not has_table_privilege('authenticated','public.space_access','SELECT');
 assert not has_function_privilege('authenticated','public.booking_entrance(uuid,uuid)','EXECUTE');
 b := public.reserve_inr_space(spot,driver,30,7500);
 assert b.stage='reserved' and b.hourly_paise=7500 and b.payment='pay_at_spot' and b.intent is null;
 assert public.booking_entrance(b.id,other) is null;
 assert (public.booking_entrance(b.id,driver)->>'lat')::double precision=22.61234;
 assert (public.reserve_inr_space(spot,driver,30,7500)).id=b.id;
 assert not exists(select 1 from public.discover_spaces(22,79,23,80) x where x.id=spot);
 b := public.advance_booking(b.id,'start',driver);
 update public.bookings set started=clock_timestamp()-interval '4 minutes 1 second' where id=b.id;
 b := public.advance_booking(b.id,'end',driver);
 assert b.stage='completed' and b.amount=625 and b.payment='pay_at_spot';
 assert public.booking_entrance(b.id,driver) is null;
 b := public.reserve_inr_space(spot,driver,15,7500);
 update public.bookings set expires=clock_timestamp()-interval '1 second' where id=b.id;
 perform public.expire_inr_bookings();
 assert (select stage='expired' from public.bookings where id=b.id);
 assert not (select occupied from public.spaces where id=spot);
end
$$;
rollback;
