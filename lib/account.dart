import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'main.dart';

class Profile extends StatefulWidget {
  const Profile({super.key, required this.client, required this.signOut});
  final SupabaseClient client;
  final Future<void> Function() signOut;

  @override
  State<Profile> createState() => _ProfileState();
}

class _ProfileState extends State<Profile> {
  late final name = TextEditingController(text: displayName);
  bool busy = false;

  String get displayName {
    final metadata = widget.client.auth.currentUser?.userMetadata;
    final value = metadata?['display_name'] ?? metadata?['username'];
    return value is String ? value : '';
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final value = name.text.trim();
    if (value.isEmpty) {
      feedback(context, 'Enter a display name.');
      return;
    }
    setState(() => busy = true);
    try {
      await widget.client.auth.updateUser(
        UserAttributes(data: {'display_name': value}),
      );
      if (mounted) feedback(context, 'Profile saved.');
    } on AuthException catch (error) {
      if (mounted) feedback(context, error.message);
    } catch (_) {
      if (mounted) feedback(context, 'Could not save your profile. Try again.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.client.auth.currentUser;
    final email = user?.email ?? '';
    final username = user?.userMetadata?['username'];
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Align(
          alignment: Alignment.centerLeft,
          child: CircleAvatar(
            radius: 30,
            backgroundColor: lime,
            child: Icon(Icons.person, color: pine),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Profile',
          style: Theme.of(context).textTheme.headlineMedium
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 24),
        if (username is String && username.isNotEmpty) ...[
          const Text('Username'),
          SelectableText(username),
          const SizedBox(height: 12),
        ],
        const Text('Account email'),
        SelectableText(email),
        const SizedBox(height: 18),
        TextField(
          controller: name,
          maxLength: 60,
          enabled: !busy,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Display name'),
        ),
        FilledButton(
          onPressed: busy ? null : save,
          child: const Text('Save profile'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: busy ? null : widget.signOut,
          icon: const Icon(Icons.logout),
          label: const Text('Sign out'),
        ),
      ],
    );
  }
}
