import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dependencies.dart';
import '../../app/session.dart';
import '../../core/app_colors.dart';
import '../../core/utils.dart';
import '../../domain/models.dart';
import '../../services/echo.dart';
import '../widgets/coral_widgets.dart';
import 'chat_screen.dart';

class EchoScreen extends ConsumerStatefulWidget {
  const EchoScreen({super.key});

  @override
  ConsumerState<EchoScreen> createState() => _EchoScreenState();
}

class _EchoScreenState extends ConsumerState<EchoScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<EchoHit> _hits = const [];
  Map<String, Chat> _chats = const {};
  bool _loading = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _loadChats();
  }

  Future<void> _loadChats() async {
    final all = await ref.read(clientProvider).store.getChats();
    if (!mounted) return;
    setState(() => _chats = {for (final chat in all) chat.id: chat});
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _query = value;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 280), () => _search(value));
  }

  Future<void> _search(String value) async {
    if (value.trim().length < 2) {
      setState(() {
        _hits = const [];
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    final hits = await ref.read(clientProvider).echo.search(value.trim());
    if (!mounted) return;
    setState(() {
      _hits = hits;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(stringsProvider);
    final palette = context.palette;
    return Scaffold(
      appBar: AppBar(title: Text(strings.get('echoTitle'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
            child: TextField(
              controller: _controller,
              autofocus: true,
              onChanged: _onChanged,
              style: TextStyle(color: palette.textPrimary, fontSize: 16),
              decoration: InputDecoration(
                hintText: strings.get('echoHint'),
                prefixIcon: Icon(Icons.graphic_eq_rounded, color: palette.accent),
                suffixIcon: _loading
                    ? Padding(
                        padding: const EdgeInsets.all(14),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: palette.accent),
                        ),
                      )
                    : null,
              ),
            ),
          ),
          Expanded(
            child: _query.trim().length < 2
                ? EmptyState(
                    title: strings.get('echoTitle'),
                    subtitle: strings.get('echoSubtitle'),
                    icon: Icons.graphic_eq_rounded,
                  )
                : _hits.isEmpty && !_loading
                    ? EmptyState(
                        title: strings.get('echoNoResults'),
                        subtitle: strings.get('echoSubtitle'),
                        icon: Icons.waves_rounded,
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
                        itemCount: _hits.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final hit = _hits[index];
                          final chat = _chats[hit.message.chatId];
                          final name = chat?.peerName ?? 'Coralink';
                          return InkWell(
                            borderRadius: BorderRadius.circular(18),
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => ChatScreen(
                                    chatId: hit.message.chatId,
                                    initialTitle: name,
                                  ),
                                ),
                              );
                            },
                            child: GlassPanel(
                              margin: EdgeInsets.zero,
                              padding: const EdgeInsets.all(14),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SeedAvatar(
                                    seedId: hit.message.chatId,
                                    name: name,
                                    colorHex: chat?.peerAvatarColor,
                                    size: 40,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: palette.textPrimary,
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                            Text(
                                              formatChatStamp(hit.message.createdAt, strings),
                                              style: TextStyle(color: palette.textMuted, fontSize: 11),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 5),
                                        _Highlighted(
                                          text: hit.message.isImage
                                              ? (hit.message.text.isEmpty ? 'Фото' : hit.message.text)
                                              : hit.message.text,
                                          query: _query.trim(),
                                          color: palette.textMuted,
                                          highlight: palette.accentSoft,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
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

class _Highlighted extends StatelessWidget {
  const _Highlighted({
    required this.text,
    required this.query,
    required this.color,
    required this.highlight,
  });

  final String text;
  final String query;
  final Color color;
  final Color highlight;

  @override
  Widget build(BuildContext context) {
    final lower = text.toLowerCase();
    final needle = query.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (needle.isNotEmpty) {
      final index = lower.indexOf(needle, start);
      if (index < 0) break;
      if (index > start) {
        spans.add(TextSpan(text: text.substring(start, index)));
      }
      spans.add(TextSpan(
        text: text.substring(index, index + needle.length),
        style: TextStyle(color: highlight, fontWeight: FontWeight.w600),
      ));
      start = index + needle.length;
    }
    if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
    return RichText(
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: TextStyle(color: color, fontSize: 13, height: 1.4),
        children: spans.isEmpty ? [TextSpan(text: text)] : spans,
      ),
    );
  }
}
