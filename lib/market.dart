import 'package:supabase_flutter/supabase_flutter.dart';

typedef RowData = Map<String, dynamic>;

const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseKey = String.fromEnvironment('SUPABASE_ANON_KEY');
const stripeKey = String.fromEnvironment('STRIPE_PUBLISHABLE_KEY');
final checkoutEnabled = stripeKey.startsWith('pk_test_');
const tileUrl = String.fromEnvironment(
  'TILE_URL',
  defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
);

String dollars(num cents) => '\$${(cents / 100).toStringAsFixed(2)}';

String rupees(int paise) =>
    '₹${(paise / 100).toStringAsFixed(paise % 100 == 0 ? 0 : 2)}';
String hourlyRate(int paise) => '${rupees(paise)}/hr';
int parkingCharge(int paisePerHour, int minutes) =>
    (paisePerHour * minutes + 59) ~/ 60;

int? parseHourlyPaise(String value) {
  final parts = value.trim().split('.');
  if (!RegExp(r'^\d{1,5}(\.\d{1,2})?$').hasMatch(value.trim())) return null;
  final paise =
      int.parse(parts.first) * 100 +
      (parts.length == 2 ? int.parse(parts.last.padRight(2, '0')) : 0);
  return paise >= 100 && paise <= 1000000 ? paise : null;
}

class Market {
  Market(this.client);
  final SupabaseClient client;
  String get uid => client.auth.currentUser!.id;

  Future<RowData> call(String action, [RowData body = const {}]) async {
    try {
      final response = await client.functions.invoke(
        'market',
        body: {...body, 'action': action},
      );
      if (response.data case final Map payload) {
        return Map<String, dynamic>.from(payload);
      }
      throw Exception(
        'The parking service returned an unexpected response. Try again.',
      );
    } on FunctionException catch (error) {
      throw Exception(marketErrorMessage(error));
    }
  }

  Future<List<RowData>> listings() async =>
      await client.from('spaces').select().eq('owner', uid).order('title');
}

String marketErrorMessage(FunctionException error) {
  final details = error.details;
  final message = details is Map
      ? details['error'] ?? details['message']
      : null;
  if (error.status == 404) {
    return 'The parking service is missing. Deploy the market Edge Function in Supabase.';
  }
  if (error.status == 401 &&
      details is Map &&
      details['code'] == 'UNAUTHORIZED_INVALID_JWT_FORMAT') {
    return 'Check the market function settings in Supabase. Turn off legacy JWT verification.';
  }
  if (message is String && message.trim().isNotEmpty) return message;
  if (error.status == 401) {
    return 'Your session could not be verified. Sign in again.';
  }
  return 'The parking service could not complete the request. Try again.';
}

const allDayHours = {
  '1': [0, 1440],
  '2': [0, 1440],
  '3': [0, 1440],
  '4': [0, 1440],
  '5': [0, 1440],
  '6': [0, 1440],
  '7': [0, 1440],
};

String clockLabel(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

String hoursLabel(Object? window) {
  if (window is! List) return 'Closed';
  if (window[0] == 0 && window[1] == 1440) return 'Open 24 hours';
  return '${clockLabel(window[0] as int)}–${clockLabel(window[1] as int)}';
}

const days = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
