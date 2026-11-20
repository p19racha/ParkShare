import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'discover.dart';
import 'main.dart';
import 'market.dart';
import 'trips.dart';

class Host extends StatefulWidget {
  const Host({
    super.key,
    this.market,
    required this.updates,
    required this.visible,
  });
  final Market? market;
  final Listenable updates;
  final bool visible;
  @override
  State<Host> createState() => _HostState();
}

class _HostState extends State<Host> {
  List<RowData>? listings;
  List<RowData> bookings = [];
  RowData? payout;
  bool working = false;
  String? error;
  int request = 0;

  @override
  void initState() {
    super.initState();
    widget.updates.addListener(load);
  }

  @override
  void didUpdateWidget(Host oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible && !oldWidget.visible) {
      load();
      if (checkoutEnabled) loadPayout();
    }
  }

  @override
  void dispose() {
    widget.updates.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    final market = widget.market;
    if (market == null || !widget.visible) return;
    final id = ++request;
    try {
      final results = await Future.wait([
        market.listings(),
        market.call('host_bookings'),
      ]);
      if (mounted && id == request) {
        setState(() {
          listings = results[0] as List<RowData>;
          bookings = List<RowData>.from(
            (results[1] as RowData)['bookings'] as List,
          );
          error = null;
        });
      }
    } catch (_) {
      if (mounted && id == request) {
        setState(() => error = 'Could not refresh your host dashboard.');
      }
    }
  }

  Future<void> loadPayout() async {
    if (widget.market == null) return;
    try {
      final status = await widget.market!.call('payouts');
      if (mounted) setState(() => payout = status);
    } catch (error) {
      if (mounted) feedback(context, error);
    }
  }

  Future<void> perform(Future<void> Function() task) async {
    setState(() => working = true);
    try {
      await task();
    } catch (error) {
      if (mounted) feedback(context, error);
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> editor([RowData? listing]) => perform(() async {
    final access = listing == null
        ? null
        : await widget.market!.call('owner_access', {'space': listing['id']});
    if (!mounted) return;
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ListingEditor(
          market: widget.market!,
          listing: listing,
          instructions: access?['instructions'] as String? ?? '',
          entrance:
              access?['entrance_lat'] is num && access?['entrance_lng'] is num
              ? LatLng(
                  (access!['entrance_lat'] as num).toDouble(),
                  (access['entrance_lng'] as num).toDouble(),
                )
              : null,
        ),
      ),
    );
    if (saved == true) await load();
  });

  @override
  Widget build(BuildContext context) {
    if (widget.market == null) {
      return const EmptyState(
        icon: Icons.garage_outlined,
        title: 'Host a parking space',
        detail: 'Connect the sandbox to publish a space, manage reservations and track payouts.',
      );
    }
    final records = listings ?? [];
    return RefreshIndicator(
      onRefresh: () async {
        await Future.wait([load(), if (checkoutEnabled) loadPayout()]);
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Host dashboard',
            style: Theme.of(context).textTheme.headlineMedium
                ?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: working ? null : () => editor(),
            icon: const Icon(Icons.add),
            label: const Text('Add a space'),
          ),
          if (error != null)
            TextButton(onPressed: load, child: Text('$error Tap to retry.')),
          if (listings == null && error == null)
            const Center(child: CircularProgressIndicator()),
          for (final space in records)
            Card(
              color: Colors.white,
              child: ListTile(
                title: Text(space['title'] as String),
                subtitle: Text(
                  '${space['published'] == true ? 'Published' : 'Draft or paused'} · ${space['occupied'] == true ? 'Occupied' : 'Clear'} · ${space['hourly_paise'] is int ? hourlyRate(space['hourly_paise'] as int) : 'Set an INR rate'}',
                ),
                trailing: const Icon(Icons.edit_outlined),
                onTap: working ? null : () => editor(space),
              ),
            ),
          if (checkoutEnabled) ...[
            const SizedBox(height: 18),
            Text(
              'Sandbox payouts',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            Text(payout?['status'] as String? ?? 'Checking payout status…'),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: working
                      ? null
                      : () => perform(() async {
                          final result = await widget.market!.call('onboard');
                          if (!await launchUrl(
                            Uri.parse(result['url'] as String),
                            mode: LaunchMode.externalApplication,
                          )) {
                            throw Exception(
                              'Could not open Stripe onboarding.',
                            );
                          }
                        }),
                  child: const Text('Stripe onboarding'),
                ),
                TextButton(
                  onPressed: working ? null : loadPayout,
                  child: const Text('Refresh payout status'),
                ),
              ],
            ),
            for (final item in (payout?['payouts'] as List? ?? []))
              ListTile(
                title: Text(dollars(item['amount'] as int)),
                trailing: Text(item['status'] as String),
              ),
          ],
          const SizedBox(height: 14),
          Text(
            'Recent bookings',
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          if (bookings.isEmpty)
            const Text(
              'Bookings will appear here when drivers reserve your spaces.',
            ),
          for (final b in bookings)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(b['title'] as String),
              subtitle: Text(
                '${bookingStatus(b['stage'] as String)} · ${(b['payment'] as String).replaceAll('_', ' ')}'
                '${b['payment'] == 'paid' ? ' · ${dollars(b['amount'] as int)} earned' : ''}',
              ),
              trailing: ['active', 'overdue'].contains(b['stage'])
                  ? TextButton(
                      onPressed: working
                          ? null
                          : () => perform(() async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text(
                                    'Confirm the space is clear',
                                  ),
                                  content: const Text(
                                    'End this booking and make the space available again?',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: const Text('Back'),
                                    ),
                                    FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: const Text('Confirm'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed == true) {
                                await widget.market!.call('end', {
                                  'id': b['id'],
                                });
                                await load();
                              }
                            }),
                      child: const Text('Mark clear'),
                    )
                  : null,
            ),
        ],
      ),
    );
  }
}

class ListingEditor extends StatefulWidget {
  const ListingEditor({
    super.key,
    required this.market,
    this.listing,
    required this.instructions,
    this.entrance,
  });
  final Market market;
  final RowData? listing;
  final String instructions;
  final LatLng? entrance;

  @override
  State<ListingEditor> createState() => _ListingEditorState();
}

class _ListingEditorState extends State<ListingEditor> {
  final form = GlobalKey<FormState>();
  final map = MapController();
  late final TextEditingController title;
  late final TextEditingController area;
  late final TextEditingController fit;
  late final TextEditingController rate;
  late final TextEditingController zone;
  late final TextEditingController instructions;
  late final Map<String, List<int>> hours;
  late LatLng pin;
  late String method;
  bool busy = false;
  bool occupied = false;

  @override
  void initState() {
    super.initState();
    final space = widget.listing;
    title = TextEditingController(text: space?['title'] as String?);
    area = TextEditingController(text: space?['area'] as String?);
    fit = TextEditingController(
      text: space?['fit'] as String? ?? 'Standard car',
    );
    final hourly = space?['hourly_paise'] as int?;
    rate = TextEditingController(
      text: hourly == null
          ? (space == null ? '40' : '')
          : (hourly / 100).toStringAsFixed(hourly % 100 == 0 ? 0 : 2),
    );
    zone = TextEditingController(
      text: space?['zone'] as String? ?? 'Asia/Kolkata',
    );
    instructions = TextEditingController(text: widget.instructions);
    method = space?['method'] as String? ?? 'Open driveway';
    pin = widget.entrance ?? (space == null ? india : pointOf(space));
    occupied = space?['occupied'] == true;
    final windows = (space?['hours'] as Map?) ?? allDayHours;
    hours = {
      for (final entry in windows.entries)
        entry.key as String: List<int>.from(entry.value as List),
    };
  }

  @override
  void dispose() {
    map.dispose();
    for (final field in [title, area, fit, rate, zone, instructions]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> placeAtCurrentLocation() async {
    try {
      final point = await parkingLocation();
      if (mounted && !busy && !occupied) {
        setState(() => pin = point);
        map.move(point, 16);
      }
    } catch (error) {
      if (mounted) feedback(context, error);
    }
  }

  Future<void> editHours(int day) async {
    final key = '$day';
    final current = hours[key] ?? [0, 1440];
    final result = await showDialog<List<int>>(
      context: context,
      builder: (_) => DayEditor(day: day, current: current),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (result.isEmpty) {
        hours.remove(key);
      } else {
        hours[key] = result;
      }
    });
  }

  Future<void> save(bool published) async {
    if (!form.currentState!.validate()) return;
    setState(() => busy = true);
    try {
      await widget.market.call('save', {
        'id': widget.listing?['id'],
        'instructions': instructions.text.trim(),
        'space': {
          'title': title.text.trim(),
          'area': area.text.trim(),
          'fit': fit.text.trim(),
          'rate': widget.listing?['rate'] ?? 12,
          'hourly_paise': parseHourlyPaise(rate.text),
          'zone': zone.text.trim(),
          'lat': pin.latitude,
          'lng': pin.longitude,
          'method': method,
          'published': published,
          'hours': hours,
        },
      });
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) feedback(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget field(
    TextEditingController controller,
    String label, {
    int lines = 1,
    bool numeric = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      enabled: !busy && !occupied,
      controller: controller,
      maxLines: lines,
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      decoration: InputDecoration(labelText: label),
      validator: (value) {
        final contents = value?.trim() ?? '';
        if (numeric) {
          if (parseHourlyPaise(contents) == null) {
            return 'Enter an hourly rate from ₹1 to ₹10,000.';
          }
        }
        if (contents.isEmpty) return 'Required';
        return null;
      },
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.listing == null ? 'Add a space' : 'Edit space'),
    ),
    body: Form(
      key: form,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (occupied)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'This space has a booking. You can pause it while the booking is open.',
              ),
            ),
          field(title, 'Listing title'),
          field(area, 'Neighborhood'),
          field(fit, 'Vehicle fit'),
          field(rate, 'Rate per hour (₹)', numeric: true),
          DropdownButtonFormField<String>(
            initialValue: method,
            decoration: const InputDecoration(labelText: 'Parking access'),
            items: [
              for (final label in [
                'Open driveway',
                'Gate code',
                'Attended handoff',
              ])
                DropdownMenuItem(value: label, child: Text(label)),
            ],
            onChanged: busy || occupied
                ? null
                : (value) => setState(() => method = value!),
          ),
          const SizedBox(height: 12),
          field(
            instructions,
            'Private address and arrival instructions',
            lines: 4,
          ),
          const Text(
            'Tap the map to set the parking entrance. Drivers see the exact pin after booking.',
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 220,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                children: [
                  FlutterMap(
                    mapController: map,
                    options: MapOptions(
                      initialCenter: pin,
                      initialZoom: 14,
                      onTap: busy || occupied
                          ? null
                          : (_, point) => setState(() => pin = point),
                    ),
                    children: [
                      parkingTiles(),
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: pin,
                            child: const Icon(
                              Icons.location_pin,
                              color: pine,
                              size: 35,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: IconButton.filledTonal(
                      tooltip: 'Place pin at my location',
                      onPressed: busy || occupied
                          ? null
                          : placeAtCurrentLocation,
                      icon: const Icon(Icons.my_location),
                    ),
                  ),
                  mapAttribution,
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          field(zone, 'IANA time zone'),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Weekly opening hours'),
            children: [
              for (var day = 1; day <= 7; day++)
                ListTile(
                  title: Text(days[day - 1]),
                  trailing: Text(hoursLabel(hours['$day'])),
                  onTap: busy || occupied ? null : () => editHours(day),
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (!occupied)
            FilledButton(
              onPressed: busy ? null : () => save(true),
              child: const Text('Publish space'),
            ),
          OutlinedButton(
            onPressed: busy ? null : () => save(false),
            child: Text(
              widget.listing?['published'] == true
                  ? 'Pause listing'
                  : 'Save draft',
            ),
          ),
        ],
      ),
    ),
  );
}

class DayEditor extends StatefulWidget {
  const DayEditor({super.key, required this.day, required this.current});
  final int day;
  final List<int> current;
  @override
  State<DayEditor> createState() => _DayEditorState();
}

class _DayEditorState extends State<DayEditor> {
  late int start = widget.current[0];
  late int end = widget.current[1];
  Future<void> pick(bool opening) async {
    final value = opening
        ? start
        : end == 1440
        ? 1439
        : end;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: value ~/ 60, minute: value % 60),
    );
    if (time == null || !mounted) return;
    setState(() {
      if (opening) {
        start = time.hour * 60 + time.minute;
      } else {
        end = time.hour * 60 + time.minute;
      }
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(days[widget.day - 1]),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          title: const Text('Opens'),
          trailing: Text(clockLabel(start)),
          onTap: () => pick(true),
        ),
        ListTile(
          title: const Text('Closes'),
          trailing: Text(clockLabel(end)),
          onTap: () => pick(false),
        ),
        TextButton(
          onPressed: () => setState(() {
            start = 0;
            end = 1440;
          }),
          child: const Text('Open 24 hours'),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, <int>[]),
        child: const Text('Closed all day'),
      ),
      FilledButton(
        onPressed: end <= start
            ? null
            : () => Navigator.pop(context, [start, end]),
        child: const Text('Save'),
      ),
    ],
  );
}
