import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parkshare/discover.dart';
import 'package:parkshare/main.dart';
import 'package:parkshare/market.dart';

class _Listings implements Market {
  RowData? reservation;
  @override
  Future<RowData> call(String action, [RowData body = const {}]) async {
    if (action == 'reserve_inr') {
      reservation = body;
      return {
        'booking': {'id': 'booking', 'title': 'Market Street space'},
      };
    }
    if (action == 'navigation') {
      return {'lat': 22.61, 'lng': 79.41, 'instructions': 'Ring the bell'};
    }
    return {
      'spaces': [
        {
          'id': 'space',
          'owner': 'host',
          'title': 'Market Street space',
          'area': 'Downtown',
          'lat': 22.6,
          'lng': 79.4,
          'method': 'Open driveway',
          'fit': 'Standard car',
          'rate': 12,
          'hourly_paise': 4000,
          'hours': allDayHours,
          'zone': 'Asia/Kolkata',
        },
      ],
    };
  }

  @override
  String get uid => 'driver';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('Missing configuration opens setup', (tester) async {
    await tester.pumpWidget(const ParkShare());
    expect(find.text('Connect ParkShare'), findsOneWidget);
    expect(find.byType(Discover), findsNothing);
  });

  test('Hourly rupee rates retain paise and round up billing', () {
    expect(parseHourlyPaise('75.50'), 7550);
    expect(parseHourlyPaise('1.234'), isNull);
    expect(hourlyRate(4000), '₹40/hr');
    expect(parkingCharge(4000, 15), 1000);
    expect(parkingCharge(7500, 5), 625);
  });

  testWidgets(
    'Parking sheet snaps, exposes attribution, and opens a selected listing',
    (tester) async {
      final updates = ValueNotifier(0);
      addTearDown(updates.dispose);
      final market = _Listings();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Discover(
              market: market,
              updates: updates,
              onBooking: () {},
              openProfile: () {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      final heading = find.text('Nearby parking');
      final attribution = find.text('© OpenStreetMap contributors');
      final handle = find.bySemanticsLabel('Parking sheet handle');
      final initialTop = tester.getTopLeft(heading).dy;
      expect(tester.getBottomLeft(attribution).dy, lessThan(initialTop));

      await tester.drag(handle, const Offset(0, 240));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(heading).dy, greaterThan(initialTop));

      await tester.tap(find.text('₹40/hr').first);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(heading).dy, closeTo(initialTop, 1));
      expect(tester.widget<ListTile>(find.byType(ListTile)).selected, isTrue);

      await tester.drag(handle, const Offset(0, -370));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(heading).dy, lessThan(initialTop));
      expect(
        tester.getBottomLeft(attribution).dy,
        lessThan(tester.getTopLeft(heading).dy),
      );

      await tester.tap(find.text('Market Street space'));
      await tester.pumpAndSettle();
      expect(find.text('Weekly hours'), findsOneWidget);
      expect(find.text('Slide to confirm'), findsOneWidget);
      final slider = find.byKey(const Key('reservation-slider'));
      await tester.ensureVisible(slider);
      await tester.tap(slider);
      await tester.drag(slider, const Offset(70, 0));
      await tester.pumpAndSettle();
      expect(market.reservation, isNull);
      final bounds = tester.getRect(slider);
      await tester.dragFrom(
        Offset(bounds.left + 20, bounds.center.dy),
        Offset(bounds.width - 25, 0),
      );
      await tester.pumpAndSettle();
      expect(market.reservation, {
        'space': 'space',
        'minutes': 60,
        'hourly_paise': 4000,
      });
      expect(find.text('Parking directions'), findsOneWidget);
    },
  );
}
