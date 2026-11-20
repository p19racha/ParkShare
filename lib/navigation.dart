import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'discover.dart';
import 'main.dart';
import 'market.dart';

const routingUrl = String.fromEnvironment(
  'ROUTING_URL',
  defaultValue: 'https://routing.openstreetmap.de/routed-car/route/v1/driving',
);

double metresBetween(LatLng first, LatLng second) => Geolocator.distanceBetween(
  first.latitude,
  first.longitude,
  second.latitude,
  second.longitude,
);

Marker currentLocationMarker(LatLng point) => Marker(
  point: point,
  width: 26,
  height: 26,
  child: Semantics(
    label: 'Your current location',
    child: Container(
      decoration: BoxDecoration(
        color: const Color(0xff1769e0),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
      ),
    ),
  ),
);

Future<void> openParkingNavigation(
  BuildContext context,
  Market market,
  RowData booking,
) async {
  final details = await market.call('navigation', {'id': booking['id']});
  if (details['lat'] is! num || details['lng'] is! num) {
    throw Exception('The host has not set a parking entrance pin.');
  }
  if (!context.mounted) return;
  await Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => ParkingNavigation(
        booking: booking,
        entrance: pointOf(details),
        instructions: details['instructions'] as String,
      ),
    ),
  );
}

class ParkingNavigation extends StatefulWidget {
  const ParkingNavigation({
    super.key,
    required this.booking,
    required this.entrance,
    required this.instructions,
  });
  final RowData booking;
  final LatLng entrance;
  final String instructions;

  @override
  State<ParkingNavigation> createState() => _ParkingNavigationState();
}

class _ParkingNavigationState extends State<ParkingNavigation> {
  final map = MapController();
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  final requestAge = Stopwatch();
  StreamSubscription<Position>? subscription;
  LatLng? current;
  LatLng? lastRoutedFrom;
  List<LatLng> points = [];
  int? remainingMetres;
  int? remainingMinutes;
  String? problem;
  bool mapReady = false;
  bool following = true;
  bool routing = false;

  @override
  void dispose() {
    subscription?.cancel();
    client.close(force: true);
    map.dispose();
    super.dispose();
  }

  Future<void> locate() async {
    try {
      final point = await parkingLocation();
      if (!mounted) return;
      updateLocation(point);
      if (subscription != null) return;
      subscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 8,
            ),
          ).listen(
            (position) =>
                updateLocation(LatLng(position.latitude, position.longitude)),
            onError: (Object _) {
              if (mounted) {
                setState(
                  () => problem =
                      'GPS updates are unavailable. Check location settings.',
                );
              }
            },
          );
    } catch (_) {
      if (mounted) {
        setState(
          () => problem = 'Enable location to get directions to this space.',
        );
      }
    }
  }

  void updateLocation(LatLng point) {
    if (!mounted) return;
    setState(() => current = point);
    if (following && mapReady) map.move(point, map.camera.zoom);
    final last = lastRoutedFrom;
    if (last == null ||
        (requestAge.elapsed >= const Duration(seconds: 30) &&
            metresBetween(point, last) >= 100)) {
      unawaited(route(point));
    }
  }

  Future<void> route(LatLng origin) async {
    if (routing) return;
    setState(() {
      routing = true;
      problem = null;
    });
    lastRoutedFrom = origin;
    requestAge
      ..reset()
      ..start();
    try {
      final destination = widget.entrance;
      final coordinates =
          '${origin.longitude},${origin.latitude};${destination.longitude},${destination.latitude}';
      final url = Uri.parse('$routingUrl/$coordinates').replace(
        queryParameters: {
          'overview': 'full',
          'geometries': 'geojson',
          'generate_hints': 'false',
        },
      );
      final request = await client.getUrl(url);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'ParkShare/0.1 (com.parkshare.parkshare)',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      if (response.statusCode != 200) {
        throw const FormatException('Routing response');
      }
      final json = jsonDecode(
        await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 12)),
      ) as Map;
      final routes = json['routes'] as List?;
      if (routes == null || routes.isEmpty) {
        throw const FormatException('No driving route');
      }
      final path = routes.first as Map;
      final geometry = (path['geometry'] as Map)['coordinates'] as List;
      final routePoints = [
        for (final coordinate in geometry.cast<List>())
          LatLng(
            (coordinate[1] as num).toDouble(),
            (coordinate[0] as num).toDouble(),
          ),
      ];
      if (!mounted) return;
      final fit =
          points.isEmpty && following && mapReady && routePoints.length > 1;
      setState(() {
        points = routePoints;
        remainingMetres = (path['distance'] as num).round();
        remainingMinutes = ((path['duration'] as num) / 60).ceil();
      });
      if (fit) {
        map.fitCamera(
          CameraFit.coordinates(
            coordinates: [...routePoints, destination],
            padding: const EdgeInsets.fromLTRB(38, 140, 38, 168),
            maxZoom: 17,
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => problem =
              'Could not load driving directions. Retry or open Maps.',
        );
      }
    } finally {
      if (mounted) setState(() => routing = false);
    }
  }

  Future<void> openMaps() async {
    final destination = widget.entrance;
    final ok = await launchUrl(
      Uri.https('www.google.com', '/maps/dir/', {
        'api': '1',
        'destination': '${destination.latitude},${destination.longitude}',
        'travelmode': 'driving',
        'dir_action': 'navigate',
      }),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) feedback(context, 'Could not open Maps.');
  }

  void centre() {
    final location = current;
    if (location == null) {
      unawaited(locate());
    } else {
      following = true;
      map.move(location, 17);
    }
  }

  @override
  Widget build(BuildContext context) {
    final distance = remainingMetres;
    final distanceText = distance == null
        ? null
        : distance >= 1000
        ? '${(distance / 1000).toStringAsFixed(1)} km'
        : '$distance m';
    final position = current;
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          FlutterMap(
            mapController: map,
            options: MapOptions(
              initialCenter: widget.entrance,
              initialZoom: 16,
              onMapReady: () {
                mapReady = true;
                unawaited(locate());
              },
              onPositionChanged: (_, gesture) {
                if (gesture) following = false;
              },
            ),
            children: [
              parkingTiles(),
              if (points.length > 1)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: points,
                      strokeWidth: 6,
                      color: const Color(0xff1769e0),
                      borderStrokeWidth: 2,
                      borderColor: Colors.white,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  Marker(
                    point: widget.entrance,
                    width: 42,
                    height: 46,
                    child: const Icon(
                      Icons.location_pin,
                      color: pine,
                      size: 42,
                    ),
                  ),
                  if (position != null) currentLocationMarker(position),
                ],
              ),
            ],
          ),
          MapAttribution(bottom: MediaQuery.viewPaddingOf(context).bottom),
          Positioned(
            top: 0,
            left: 10,
            right: 10,
            child: SafeArea(
              bottom: false,
              child: Card(
                child: ListTile(
                  leading: const BackButton(),
                  title: Text(widget.booking['title'] as String),
                  subtitle: Text(
                    distanceText == null
                        ? 'Parking directions'
                        : '$distanceText · About $remainingMinutes min',
                  ),
                  trailing: IconButton(
                    tooltip: 'Follow my location',
                    icon: const Icon(Icons.my_location),
                    onPressed: centre,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 25,
            left: 10,
            right: 10,
            child: SafeArea(
              top: false,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (routing) const LinearProgressIndicator(),
                      if (problem != null) Text(problem!),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed: openMaps,
                            child: const Text('Open Maps'),
                          ),
                          if (problem != null)
                            TextButton(
                              onPressed: routing
                                  ? null
                                  : () => position == null
                                        ? locate()
                                        : route(position),
                              child: const Text('Retry'),
                            ),
                          TextButton(
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('Arrival instructions'),
                                content: SingleChildScrollView(
                                  child: SelectableText(widget.instructions),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: const Text('Close'),
                                  ),
                                ],
                              ),
                            ),
                            child: const Text('Access instructions'),
                          ),
                        ],
                      ),
                      if (points.isNotEmpty)
                        Wrap(
                          spacing: 10,
                          children: [
                            InkWell(
                              onTap: () => launchUrl(
                                Uri.parse(
                                  'https://routing.openstreetmap.de/about.html',
                                ),
                              ),
                              child: const Text(
                                'OSRM · FOSSGIS',
                                style: TextStyle(fontSize: 10),
                              ),
                            ),
                            InkWell(
                              onTap: () => launchUrl(
                                Uri.parse(
                                  'https://www.openstreetmap.org/fixthemap',
                                ),
                              ),
                              child: const Text(
                                'Fix the map',
                                style: TextStyle(fontSize: 10),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
