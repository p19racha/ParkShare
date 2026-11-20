import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_stripe/flutter_stripe.dart' hide Card;
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'main.dart';
import 'market.dart';
import 'navigation.dart';

const india = LatLng(22.6, 79.4);

TileLayer parkingTiles() => TileLayer(
  urlTemplate: tileUrl,
  userAgentPackageName: 'com.parkshare.parkshare',
  maxNativeZoom: 19,
);

const MapAttribution mapAttribution = MapAttribution();

class MapAttribution extends StatelessWidget {
  const MapAttribution({super.key, this.bottom = 0});
  final double bottom;
  @override
  Widget build(BuildContext context) => Positioned(
    bottom: bottom,
    right: 0,
    child: Material(
      color: const Color(0xf2ffffff),
      child: InkWell(
        onTap: () =>
            launchUrl(Uri.parse('https://www.openstreetmap.org/copyright')),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 7, vertical: 5),
          child: Text(
            '© OpenStreetMap contributors',
            style: TextStyle(fontSize: 10),
          ),
        ),
      ),
    ),
  );
}

LatLng pointOf(RowData row) =>
    LatLng((row['lat'] as num).toDouble(), (row['lng'] as num).toDouble());

Future<LatLng> parkingLocation() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw Exception('Turn on location services to center the map.');
  }
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    throw Exception(
      'Enable location access in Android settings or browse the map manually.',
    );
  }
  final position = await Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(timeLimit: Duration(seconds: 10)),
  );
  return LatLng(position.latitude, position.longitude);
}

class Discover extends StatefulWidget {
  const Discover({
    super.key,
    required this.market,
    required this.openProfile,
    required this.updates,
    required this.onBooking,
  });
  final Market market;
  final VoidCallback openProfile;
  final Listenable updates;
  final VoidCallback onBooking;
  @override
  State<Discover> createState() => _DiscoverState();
}

class _DiscoverState extends State<Discover> {
  final controller = MapController();
  final sheet = DraggableScrollableController();
  static const collapsed = .15;
  static const preview = .36;
  static const expanded = .78;
  final extent = ValueNotifier<double>(preview);
  String? selected;
  ScrollController? sheetScroll;
  List<RowData> spaces = [];
  Timer? debounce;
  StreamSubscription<Position>? locationUpdates;
  LatLng? current;
  bool locating = false;
  bool following = true;
  bool ready = false;
  bool loading = true;
  String? error;
  int request = 0;

  @override
  void initState() {
    super.initState();
    widget.updates.addListener(load);
  }

  @override
  void dispose() {
    widget.updates.removeListener(load);
    debounce?.cancel();
    locationUpdates?.cancel();
    controller.dispose();
    sheet.dispose();
    extent.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (!ready || !mounted) return;
    final camera = controller.camera;
    if (camera.nonRotatedSize.isEmpty) return;
    final bounds = camera.visibleBounds;
    final requestId = ++request;
    try {
      final response = await widget.market.call('discover', {
        'south': bounds.south,
        'north': bounds.north,
        'west': bounds.west,
        'east': bounds.east,
      });
      final results = List<RowData>.from(response['spaces'] as List)
          .where((space) => space['hourly_paise'] is int)
          .toList();
      final location = current;
      if (location != null) {
        results.sort(
          (a, b) => metresBetween(
            location,
            pointOf(a),
          ).compareTo(metresBetween(location, pointOf(b))),
        );
      }
      if (!mounted || requestId != request) return;
      setState(() {
        spaces = results;
        if (!results.any((space) => space['id'] == selected)) selected = null;
        error = null;
        loading = false;
      });
    } catch (failure) {
      if (!mounted || requestId != request) return;
      setState(() {
        loading = false;
        error = 'Could not refresh parking.';
      });
    }
  }

  void scheduleLoad() {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 350), load);
  }

  Future<void> locate({bool showError = true}) async {
    if (locating) return;
    locating = true;
    following = true;
    try {
      final point = await parkingLocation();
      if (!mounted || !ready) return;
      updateLocation(point, zoom: 14.5);
      locationUpdates ??=
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 15,
            ),
          ).listen(
            (position) =>
                updateLocation(LatLng(position.latitude, position.longitude)),
            onError: (Object _) {},
          );
    } catch (failure) {
      if (showError && mounted) feedback(context, failure);
    } finally {
      locating = false;
    }
  }

  void updateLocation(LatLng point, {double? zoom}) {
    if (!mounted) return;
    setState(() => current = point);
    if (following && ready) {
      controller.move(point, zoom ?? controller.camera.zoom);
    }
  }

  Future<void> showSpot(RowData space) async {
    final booking = await showModalBottomSheet<RowData>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => SpotDetails(space: space, market: widget.market),
    );
    if (booking == null || !mounted) return;
    widget.onBooking();
    try {
      await openParkingNavigation(context, widget.market, booking);
    } catch (error) {
      if (mounted) feedback(context, error);
    }
  }

  void selectPin(RowData space) {
    setState(() => selected = space['id'] as String);
    final scroll = sheetScroll;
    if (scroll != null && scroll.hasClients) scroll.jumpTo(0);
    if (sheet.isAttached && sheet.size < preview) {
      unawaited(
        sheet.animateTo(
          preview,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ordered = [
      ...spaces.where((space) => space['id'] == selected),
      ...spaces.where((space) => space['id'] != selected),
    ];
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        fit: StackFit.expand,
        children: [
          FlutterMap(
            mapController: controller,
            options: MapOptions(
              initialCenter: india,
              initialZoom: 5,
              minZoom: 3,
              backgroundColor: const Color(0xffe6ead9),
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onMapReady: () {
                ready = true;
                scheduleLoad();
                unawaited(locate(showError: false));
              },
              onMapEvent: (event) {
                if (event is MapEventNonRotatedSizeChange) scheduleLoad();
              },
              onPositionChanged: (_, gesture) {
                if (gesture) following = false;
                scheduleLoad();
              },
            ),
            children: [
              parkingTiles(),
              MarkerLayer(
                markers: [
                  for (final space in spaces)
                    Marker(
                      point: pointOf(space),
                      width: 76,
                      height: 36,
                      child: Semantics(
                        selected: selected == space['id'],
                        button: true,
                        label: space['title'] as String,
                        child: Material(
                          color: selected == space['id'] ? lime : pine,
                          elevation: 3,
                          borderRadius: BorderRadius.circular(20),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(20),
                            onTap: () => selectPin(space),
                            child: Center(
                              child: Text(
                                hourlyRate(space['hourly_paise'] as int),
                                style: TextStyle(
                                  color: selected == space['id']
                                      ? pine
                                      : Colors.white,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (current case final point?) currentLocationMarker(point),
                ],
              ),
            ],
          ),
          NotificationListener<DraggableScrollableNotification>(
            onNotification: (notification) {
              extent.value = notification.extent;
              return false;
            },
            child: DraggableScrollableSheet(
              controller: sheet,
              minChildSize: collapsed,
              initialChildSize: preview,
              maxChildSize: expanded,
              snap: true,
              snapSizes: const [preview],
              builder: (context, scroll) {
                sheetScroll = scroll;
                return Material(
                  color: paper,
                  elevation: 12,
                  clipBehavior: Clip.antiAlias,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(24),
                  ),
                  child: CustomScrollView(
                    controller: scroll,
                    slivers: [
                      SliverToBoxAdapter(
                        child: Column(
                          children: [
                            const SizedBox(height: 9),
                            Semantics(
                              label: 'Parking sheet handle',
                              button: true,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => sheet.animateTo(
                                  sheet.size < preview
                                      ? preview
                                      : sheet.size < expanded
                                      ? expanded
                                      : collapsed,
                                  duration: const Duration(milliseconds: 240),
                                  curve: Curves.easeOut,
                                ),
                                child: SizedBox(
                                  width: 72,
                                  height: 16,
                                  child: Center(
                                    child: Container(
                                      width: 34,
                                      height: 4,
                                      decoration: BoxDecoration(
                                        color: pine.withValues(alpha: .3),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 10, 0),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      'Nearby parking',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge
                                          ?.copyWith(
                                            fontWeight: FontWeight.w800,
                                          ),
                                    ),
                                  ),
                                  if (!loading && error == null)
                                    Text('${spaces.length} spots'),
                                  IconButton(
                                    onPressed: load,
                                    tooltip: 'Refresh parking',
                                    icon: const Icon(Icons.refresh),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (loading || error != null || ordered.isEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                            child: loading
                                ? const Center(
                                    child: CircularProgressIndicator(),
                                  )
                                : error != null
                                ? TextButton(
                                    onPressed: load,
                                    child: Text('$error Tap to retry.'),
                                  )
                                : const Text(
                                    'No open spaces here. Move the map or use your location.',
                                  ),
                          ),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          sliver: SliverList.builder(
                            itemCount: ordered.length,
                            itemBuilder: (context, index) {
                              final space = ordered[index];
                              return Card(
                                color: selected == space['id']
                                    ? lime
                                    : Colors.white,
                                child: ListTile(
                                  selected: selected == space['id'],
                                  onTap: () {
                                    setState(
                                      () => selected = space['id'] as String,
                                    );
                                    showSpot(space);
                                  },
                                  leading: Icon(
                                    space['method'] == 'Gate code'
                                        ? Icons.lock_outline
                                        : Icons.local_parking,
                                    color: pine,
                                  ),
                                  title: Text(
                                    space['title'] as String,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  subtitle: Text(
                                    '${space['area']} · ${space['method']}',
                                  ),
                                  trailing: Text(
                                    hourlyRate(space['hourly_paise'] as int),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          Positioned(
            left: 14,
            right: 14,
            top: 10,
            child: SafeArea(
              bottom: false,
              child: Row(
                children: [
                  const Material(
                    color: paper,
                    elevation: 2,
                    borderRadius: BorderRadius.all(Radius.circular(16)),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(6, 5, 12, 5),
                      child: Brand(),
                    ),
                  ),
                  const Spacer(),
                  IconButton.filledTonal(
                    tooltip: 'Use my location',
                    onPressed: locate,
                    icon: const Icon(Icons.my_location),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filledTonal(
                    tooltip: 'Open profile',
                    onPressed: widget.openProfile,
                    icon: const Icon(Icons.person_outline),
                  ),
                ],
              ),
            ),
          ),
          ValueListenableBuilder<double>(
            valueListenable: extent,
            builder: (_, value, _) =>
                MapAttribution(bottom: constraints.maxHeight * value + 4),
          ),
        ],
      ),
    );
  }
}

Future<void> presentCheckout(String secret) async {
  await Stripe.instance.initPaymentSheet(
    paymentSheetParameters: SetupPaymentSheetParameters(
      paymentIntentClientSecret: secret,
      merchantDisplayName: 'ParkShare',
    ),
  );
  await Stripe.instance.presentPaymentSheet();
}

class SpotDetails extends StatefulWidget {
  const SpotDetails({super.key, required this.space, this.market});
  final RowData space;
  final Market? market;
  @override
  State<SpotDetails> createState() => _SpotDetailsState();
}

class _SpotDetailsState extends State<SpotDetails> {
  int minutes = 60;
  bool busy = false;

  double slide = 0;

  Future<void> reserve() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final result = await widget.market!.call('reserve_inr', {
        'space': widget.space['id'],
        'minutes': minutes,
        'hourly_paise': widget.space['hourly_paise'],
      });
      if (mounted) {
        Navigator.pop(
          context,
          Map<String, dynamic>.from(result['booking'] as Map),
        );
      }
    } catch (error) {
      if (mounted) feedback(context, error);
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          slide = 0;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final space = widget.space;
    final paise = space['hourly_paise'] as int;
    final quote = rupees(parkingCharge(paise, minutes));
    final isDemo = space['demo'] == true;
    final canReserve =
        widget.market != null &&
        !isDemo &&
        space['owner'] != widget.market!.uid;
    return PopScope(
      canPop: !busy,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              space['title'] as String,
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w900),
            ),
            Text(space['area'] as String),
            const SizedBox(height: 12),
            Text('${hourlyRate(paise)} · ${space['fit']} · ${space['method']}'),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Weekly hours'),
              subtitle: Text(space['zone'] as String),
              children: [
                for (var i = 0; i < 7; i++)
                  ListTile(
                    dense: true,
                    title: Text(days[i]),
                    trailing: Text(
                      hoursLabel((space['hours'] as Map)['${i + 1}']),
                    ),
                  ),
              ],
            ),
            if (canReserve) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: minutes,
                decoration: const InputDecoration(labelText: 'Maximum stay'),
                items: [
                  for (var duration = 15; duration <= 240; duration += 15)
                    DropdownMenuItem(
                      value: duration,
                      child: Text('$duration minutes'),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (value) => setState(() {
                        minutes = value!;
                        slide = 0;
                      }),
              ),
              const SizedBox(height: 12),
              Text(
                'Up to $quote for $minutes min. Arrive within 15 minutes. Pay at the space.',
              ),
              const SizedBox(height: 16),
              Semantics(
                button: true,
                label: 'Confirm reservation and navigate',
                onTap: busy ? null : reserve,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    const thumb = 48.0;
                    final travel = (constraints.maxWidth - thumb - 8).clamp(
                      1.0,
                      double.infinity,
                    );
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragUpdate: busy
                          ? null
                          : (details) => setState(() {
                              slide = (slide + details.delta.dx / travel).clamp(
                                0.0,
                                1.0,
                              );
                            }),
                      onHorizontalDragCancel: () => setState(() => slide = 0),
                      onHorizontalDragEnd: busy
                          ? null
                          : (_) {
                              if (slide >= .9) {
                                unawaited(reserve());
                              } else {
                                setState(() => slide = 0);
                              }
                            },
                      child: Container(
                        key: const Key('reservation-slider'),
                        height: 56,
                        decoration: BoxDecoration(
                          color: lime,
                          borderRadius: BorderRadius.circular(30),
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 52,
                              ),
                              child: Text(
                                busy ? 'Confirming…' : 'Slide to confirm',
                                textAlign: TextAlign.center,
                              ),
                            ),
                            Positioned(
                              left: 4 + travel * slide,
                              top: 4,
                              child: Container(
                                width: thumb,
                                height: thumb,
                                decoration: const BoxDecoration(
                                  color: pine,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.arrow_forward,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ] else
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  isDemo
                      ? 'Example listing for map exploration.'
                      : space['owner'] == widget.market?.uid
                      ? 'You host this space.'
                      : 'Reservations are unavailable for this space.',
                ),
              ),
          ],
        ),
      ),
    );
  }
}
