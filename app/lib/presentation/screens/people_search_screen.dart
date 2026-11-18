import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dependencies.dart';
import '../../app/session.dart';
import '../../core/app_colors.dart';
import '../../core/utils.dart';
import '../../data/api_client.dart';
import '../../domain/models.dart';
import '../controllers.dart';
import '../widgets/coral_widgets.dart';
import 'chat_screen.dart';

class PeopleSearchScreen extends ConsumerStatefulWidget {
  const PeopleSearchScreen({super.key});

  @override
  ConsumerState<PeopleSearchScreen> createState() => _PeopleSearchScreenState();
}

class _PeopleSearchScreenState extends ConsumerState<PeopleSearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<User> _results = const [];
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(value));
  }

  Future<void> _search(String value) async {
    if (value.trim().length < 2) {
      setState(() => _results = const []);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final users = await ref.read(contactsProvider.notifier).search(value);
      if (!mounted) return;
      setState(() => _results = users);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(User user) async {
    final client = ref.read(clientProvider);
    await ref.read(contactsProvider.notifier).add(user);
    final chat = await client.messages.ensureChat(user.id, peer: user);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ChatScreen(chatId: chat.id, initialTitle: user.name),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(stringsProvider);
    final palette = context.palette;
    return Scaffold(
      appBar: AppBar(title: Text(strings.get('searchPeople'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: TextField(
              controller: _controller,
              autofocus: true,
              onChanged: _onChanged,
              keyboardType: TextInputType.text,
              style: TextStyle(color: palette.textPrimary, fontSize: 16),
              decoration: InputDecoration(
                hintText: strings.get('searchByPhone'),
                prefixIcon: Icon(Icons.search_rounded, color: palette.accent),
                suffixIcon: _loading
                    ? Padding(
                        padding: const EdgeInsets.all(14),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: palette.accent,
                          ),
                        ),
                      )
                    : null,
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(_error!, style: TextStyle(color: palette.coral, fontSize: 13)),
            ),
          Expanded(
            child: _results.isEmpty
                ? EmptyState(
                    title: _controller.text.trim().length < 2
                        ? strings.get('searchPeople')
                        : strings.get('noResults'),
                    subtitle: strings.get('searchByPhone'),
                    icon: Icons.travel_explore_rounded,
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 40),
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final user = _results[index];
                      final online = user.presence != Presence.offline;
                      return ListTile(
                        onTap: () => _open(user),
                        leading: SeedAvatar(
                          seedId: user.id,
                          name: user.name,
                          colorHex: user.avatarColor,
                          avatar: user.avatar,
                          online: online,
                          size: 48,
                        ),
                        title: Text(
                          user.name,
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        subtitle: Text(
                          user.username.isNotEmpty
                              ? '@${user.username}'
                              : (user.about.isNotEmpty ? user.about : maskPhone(user.phone)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: palette.textMuted, fontSize: 12.5),
                        ),
                        trailing: IconButton(
                          onPressed: () => _open(user),
                          icon: Icon(Icons.arrow_forward_rounded, color: palette.accent),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
