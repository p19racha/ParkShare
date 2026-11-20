import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart' show StripeException;

import 'discover.dart';
import 'main.dart';
import 'market.dart';
import 'navigation.dart';

String bookingStatus(String stage) => switch (stage) {
  'hold' => 'Payment hold',
  'reserved' => 'Reserved',
  'active' => 'Parked',
  'overdue' => 'Overdue',
  'completed' => 'Completed',
  'cancelled' => 'Cancelled',
  'expired' => 'Expired',
  _ => stage,
};

class Trips extends StatefulWidget {
  const Trips({
    super.key,
    this.market,
    required this.updates,
    required this.visible,
  });
  final Market? market;
  final Listenable updates;
  final bool visible;
  @override
  State<Trips> createState() => _TripsState();
}

class _TripsState extends State<Trips> {
  List<RowData>? trips;
  String? error;
  DateTime? serverTime;
  final elapsed = Stopwatch();
  int request = 0;

  @override
  void initState() {
    super.initState();
    widget.updates.addListener(load);
  }

  @override
  void didUpdateWidget(Trips oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible && !oldWidget.visible) load();
  }

  @override
  void dispose() {
    widget.updates.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    final market = widget.market;
    if (!widget.visible || market == null) return;
    final id = ++request;
    try {
      final data = await market.call('trips');
      if (!mounted || id != request) return;
      setState(() {
        trips = List<RowData>.from(data['bookings'] as List);
        serverTime = DateTime.parse(data['now'] as String);
        elapsed.reset();
        elapsed.start();
        error = null;
      });
    } catch (_) {
      if (mounted && id == request) {
        setState(() => error = 'Could not refresh your trips.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.market == null) {
      return const EmptyState(
        icon: Icons.receipt_long_outlined,
        title: 'Your trips',
        detail: 'Connect the sandbox to reserve a space and view your parking receipts.',
      );
    }
    final records = trips;
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Your trips',
            style: Theme.of(context).textTheme.headlineMedium
                ?.copyWith(fontWeight: FontWeight.w900),
          ),
          if (error != null)
            TextButton(onPressed: load, child: Text('$error Tap to retry.')),
          if (records == null && error == null)
            const Center(child: CircularProgressIndicator()),
          if (records?.isEmpty ?? false)
            Padding(
              padding: const EdgeInsets.only(top: 35),
              child: EmptyState(
                icon: Icons.local_parking,
                title: 'No trips yet',
                detail: 'Reserve an available space from Explore.',
              ),
            ),
          for (final trip in records ?? <RowData>[])
            TripCard(
              key: ValueKey(trip['id']),
              market: widget.market!,
              booking: trip,
              now: () => serverTime!.add(elapsed.elapsed),
              changed: load,
            ),
        ],
      ),
    );
  }
}

class TripCard extends StatefulWidget {
  const TripCard({
    super.key,
    required this.market,
    required this.booking,
    required this.now,
    required this.changed,
  });
  final Market market;
  final RowData booking;
  final DateTime Function() now;
  final Future<void> Function() changed;
  @override
  State<TripCard> createState() => _TripCardState();
}

class _TripCardState extends State<TripCard> {
  Timer? timer;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    updateTimer();
  }

  @override
  void didUpdateWidget(TripCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.booking['stage'] != widget.booking['stage']) updateTimer();
  }

  void updateTimer() {
    timer?.cancel();
    if (['hold', 'reserved', 'active'].contains(widget.booking['stage'])) {
      timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => setState(() {}),
      );
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> act(String action) async {
    setState(() => busy = true);
    try {
      if (action == 'navigation') {
        await openParkingNavigation(context, widget.market, widget.booking);
        return;
      }
      final data = await widget.market.call(action, {
        'id': widget.booking['id'],
      });
      if (action == 'retry_checkout' && data['client_secret'] is String) {
        await presentCheckout(data['client_secret'] as String);
        await widget.market.call('sync', {'id': widget.booking['id']});
      }
      if (action == 'access' && mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Arrival instructions'),
            content: SingleChildScrollView(
              child: SelectableText(data['instructions'] as String),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }
    } on StripeException catch (error) {
      if (mounted) {
        feedback(
          context,
          error.error.localizedMessage ?? 'Checkout was interrupted.',
        );
      }
    } catch (error) {
      if (mounted) feedback(context, error);
    } finally {
      if (mounted) {
        await widget.changed();
        if (mounted) setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.booking;
    final stage = b['stage'] as String;
    final expires = DateTime.parse(b['expires'] as String);
    final now = widget.now();
    final remaining = math.max(0, expires.difference(now).inSeconds);
    final live = stage == 'active';
    final started = b['started'] == null
        ? null
        : DateTime.parse(b['started'] as String);
    final seconds = live
        ? math.max(
            0,
            (now.isBefore(expires) ? now : expires)
                .difference(started!)
                .inSeconds,
          )
        : remaining;
    final time =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    final hourly = b['hourly_paise'] as int?;
    final elapsedMinutes = (seconds + 59) ~/ 60;
    final estimate = hourly == null
        ? dollars(math.max(50, elapsedMinutes * (b['rate'] as int)))
        : rupees(parkingCharge(hourly, elapsedMinutes));
    final payment = (b['payment'] as String).replaceAll('_', ' ');
    final priceLabel = hourly == null
        ? '${dollars(b['rate'] as int)}/min'
        : hourlyRate(hourly);
    final amount = b['amount'] as int?;
    final total = amount == null
        ? null
        : hourly == null
        ? dollars(amount)
        : rupees(amount);

    return Card(
      margin: const EdgeInsets.only(top: 12),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              b['title'] as String,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
            Text('${bookingStatus(stage)} · $payment'),
            if (live || stage == 'reserved' || stage == 'hold') ...[
              const SizedBox(height: 9),
              Text(
                time,
                style: Theme.of(context).textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              Text(
                live
                    ? '$estimate estimated · ${b['minutes']} min limit'
                    : stage == 'reserved'
                    ? 'Time left to arrive'
                    : 'Time left to authorize your card',
              ),
            ],
            if (stage == 'overdue')
              const Text(
                'Billing has stopped. Check out once you leave the space.',
              ),
            if (total != null) Text('$total · $priceLabel'),
            Wrap(
              spacing: 8,
              children: [
                if (stage == 'hold' && remaining > 0 && checkoutEnabled)
                  FilledButton(
                    onPressed: busy ? null : () => act('retry_checkout'),
                    child: const Text('Continue checkout'),
                  ),
                if (stage == 'hold' || stage == 'reserved')
                  TextButton(
                    onPressed: busy ? null : () => act('cancel'),
                    child: const Text('Cancel'),
                  ),
                if ((stage == 'reserved' && remaining > 0) ||
                    live ||
                    stage == 'overdue')
                  OutlinedButton(
                    onPressed: busy ? null : () => act('access'),
                    child: const Text('Access instructions'),
                  ),
                if (hourly != null && stage == 'reserved' && remaining > 0)
                  OutlinedButton.icon(
                    onPressed: busy ? null : () => act('navigation'),
                    icon: const Icon(Icons.directions),
                    label: const Text('Navigate'),
                  ),
                if (stage == 'reserved' && remaining > 0)
                  FilledButton(
                    onPressed: busy ? null : () => act('start'),
                    child: const Text('Start parking'),
                  ),
                if (live || stage == 'overdue')
                  FilledButton(
                    onPressed: busy ? null : () => act('end'),
                    child: const Text('Check out'),
                  ),
                if (['capture pending', 'release pending'].contains(payment))
                  TextButton(
                    onPressed: busy ? null : () => act('sync'),
                    child: const Text('Refresh payment'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
