import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'account.dart';
import 'auth.dart';
import 'discover.dart';
import 'host.dart';
import 'market.dart';
import 'trips.dart';

const ink = Color(0xff212b25);
const paper = Color(0xfff8f8f1);
const pine = Color(0xff244638);
const lime = Color(0xffd8ef9a);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SupabaseClient? client;
  String? setupError;
  if (supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty) {
    try {
      client = (await Supabase.initialize(
        url: supabaseUrl,
        publishableKey: supabaseKey,
        authOptions: const FlutterAuthClientOptions(
          authFlowType: AuthFlowType.pkce,
          detectSessionInUriPredicate: isGoogleCallback,
        ),
      )).client;
    } catch (_) {
      setupError = 'ParkShare could not start. Check the Supabase configuration and restart the app.';
    }
  }
  if (client != null && checkoutEnabled) {
    Stripe.publishableKey = stripeKey;
    await Stripe.instance.applySettings();
  }
  runApp(ParkShare(client: client, setupError: setupError));
}

class ParkShare extends StatelessWidget {
  const ParkShare({super.key, this.client, this.setupError});
  final String? setupError;
  final SupabaseClient? client;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.fromSeed(seedColor: pine, surface: paper)
        .copyWith(
          primary: pine,
          onPrimary: Colors.white,
          secondaryContainer: lime,
          onSurface: ink,
        );
    return MaterialApp(
      title: 'ParkShare',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colors,
        scaffoldBackgroundColor: paper,
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Colors.white,
          indicatorColor: lime,
          height: 68,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      home: client == null
          ? Scaffold(
              appBar: AppBar(title: const Brand()),
              body: EmptyState(
                icon: Icons.settings_outlined,
                title: 'Connect ParkShare',
                detail: setupError ?? 'This build needs a Supabase project URL and publishable key. See the setup guide in the project README.',
              ),
            )
          : StreamBuilder<AuthState>(
              stream: client!.auth.onAuthStateChange,
              builder: (context, snapshot) {
                final auth = client!.auth;
                final user = auth.currentUser;
                if (auth.currentSession == null || user == null) {
                  return SignIn(
                    client: client!,
                    callbackError: snapshot.hasError
                        ? authMessage(snapshot.error!)
                        : null,
                  );
                }
                if (needsGoogleUsername(user)) {
                  return ChooseUsername(
                    key: ValueKey(user.id),
                    client: client!,
                  );
                }
                return Home(key: ValueKey(user.id), market: Market(client!));
              },
            ),
    );
  }
}

void feedback(BuildContext context, Object message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message.toString().replaceFirst('Exception: ', ''))),
  );
}

class Brand extends StatelessWidget {
  const Brand({super.key});
  @override
  Widget build(BuildContext context) => const Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      DecoratedBox(
        decoration: BoxDecoration(
          color: pine,
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        child: Padding(
          padding: EdgeInsets.all(8),
          child: Icon(Icons.local_parking_rounded, color: lime, size: 22),
        ),
      ),
      SizedBox(width: 9),
      Text(
        'ParkShare',
        style: TextStyle(
          fontSize: 21,
          fontWeight: FontWeight.w900,
          letterSpacing: -0.7,
        ),
      ),
    ],
  );
}

class Home extends StatefulWidget {
  const Home({super.key, required this.market});
  final Market market;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  int index = 0;
  final updates = ValueNotifier(0);
  RealtimeChannel? channel;
  Timer? refresh;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final market = widget.market;
    channel = market.client
        .channel('parking-updates')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          table: 'availability_updates',
          schema: 'public',
          callback: (_) => changed(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          table: 'bookings',
          schema: 'public',
          callback: (_) => changed(),
        )
        .subscribe((status, _) {
          if (status == RealtimeSubscribeStatus.subscribed) changed();
        });
    refresh = Timer.periodic(const Duration(seconds: 25), (_) => changed());
  }

  void changed() {
    if (mounted) updates.value++;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) changed();
  }

  @override
  void dispose() {
    refresh?.cancel();
    final activeChannel = channel;
    if (activeChannel != null) {
      unawaited(widget.market.client.removeChannel(activeChannel));
    }
    WidgetsBinding.instance.removeObserver(this);
    updates.dispose();
    super.dispose();
  }

  Future<void> signOut() async {
    try {
      await widget.market.client.auth.signOut(scope: SignOutScope.local);
    } catch (_) {
      if (mounted) feedback(context, 'Could not sign out. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: index == 0
        ? null
        : AppBar(backgroundColor: paper, title: const Brand()),
    body: IndexedStack(
      index: index,
      children: [
        Discover(
          market: widget.market,
          openProfile: () => setState(() => index = 3),
          updates: updates,
          onBooking: () {
            changed();
            setState(() => index = 1);
          },
        ),
        Trips(market: widget.market, updates: updates, visible: index == 1),
        Host(market: widget.market, updates: updates, visible: index == 2),
        Profile(client: widget.market.client, signOut: signOut),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: index,
      onDestinationSelected: (value) => setState(() => index = value),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.explore_outlined),
          selectedIcon: Icon(Icons.explore),
          label: 'Explore',
        ),
        NavigationDestination(
          icon: Icon(Icons.receipt_long_outlined),
          label: 'Trips',
        ),
        NavigationDestination(
          icon: Icon(Icons.garage_outlined),
          selectedIcon: Icon(Icons.garage),
          label: 'Host',
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person),
          label: 'Profile',
        ),
      ],
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
  });
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 30,
            backgroundColor: lime,
            child: Icon(icon, color: pine, size: 28),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(detail, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}
