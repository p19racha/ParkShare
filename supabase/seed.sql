-- Fictional listings for discovery. The placeholder owner cannot sign in.
insert into auth.users (id) values ('d0000000-0000-4000-8000-000000000001')
on conflict (id) do nothing;

insert into public.spaces (id, owner, title, area, lat, lng, rate, fit, method, published, demo)
select s.id::uuid, 'd0000000-0000-4000-8000-000000000001'::uuid,
 s.title, s.area, s.lat, s.lng, s.rate, 'Standard car', s.method, true, true
from (values
 ('d1000000-0000-4000-8000-000000000001','Mason Street Driveway','Nob Hill',37.792,-122.411,12,'Open driveway'),
 ('d1000000-0000-4000-8000-000000000002','SoMa Courtyard','South of Market',37.782,-122.405,10,'Gate code'),
 ('d1000000-0000-4000-8000-000000000003','Hayes Valley Garage','Hayes Valley',37.777,-122.424,16,'Attended handoff'),
 ('d1000000-0000-4000-8000-000000000004','North Beach Parking Pad','North Beach',37.801,-122.410,14,'Open driveway'),
 ('d1000000-0000-4000-8000-000000000005','Franklin Street Spot','Pacific Heights',37.791,-122.427,11,'Open driveway')
) s(id,title,area,lat,lng,rate,method)
on conflict (id) do nothing;
