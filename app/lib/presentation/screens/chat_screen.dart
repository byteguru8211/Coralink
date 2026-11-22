import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';

import '../../app/dependencies.dart';
import '../../app/session.dart';
import '../../core/app_colors.dart';
import '../../core/strings.dart';
import '../../core/utils.dart';
import '../../domain/models.dart';
import '../../network/realtime.dart';
import '../../security/signal_service.dart';
import '../../services/audio_service.dart';
import '../../services/voice_recorder.dart';
import '../controllers.dart';
import '../widgets/chat_widgets.dart';
import '../widgets/coral_widgets.dart';
import '../widgets/stickers.dart';
import 'call_screen.dart';

enum _Attach { gallery, camera, file, video, videoNote }

enum _AvatarChoice { gallery, camera, remove }

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.chatId, this.initialTitle});
  final String chatId;
  final String? initialTitle;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  bool _canSend = false;
  bool _rustling = false;
  bool _sendPulse = false;
  int _lastCount = 0;
  AudioService? _audio;
  VoiceRecorder? _recorder;
  bool _recording = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;

  @override
  void initState() {
    super.initState();
    _audio = ref.read(audioProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom(animate: false);
      _syncRustle(ref.read(messagesProvider(widget.chatId)));
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    _recordTimer?.cancel();
    if (_recording) {
      _recorder?.cancel();
    }
    _recorder?.dispose();
    // Stop the ambient rustle when leaving the chat. `ref` is unusable in
    // dispose, so the service was captured in initState.
    _rustling = false;
    _audio?.stopPresence();
    super.dispose();
  }

  Future<void> _toggleRecord() async {
    final strings = ref.read(stringsProvider);
    if (_recording) {
      _recordTimer?.cancel();
      try {
        final recording = await _recorder!.stop();
        setState(() {
          _recording = false;
          _recordSeconds = 0;
        });
        await ref.read(messagesProvider(widget.chatId).notifier).sendAudio(
              base64Encode(recording.bytes),
              recording.mimeType,
              recording.bytes.length,
              recording.durationMs,
            );
        _scrollToBottom();
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_errorText(error, strings))),
        );
      }
      return;
    }
    _recorder ??= VoiceRecorder();
    try {
      final granted = await _recorder!.hasPermission();
      if (!granted) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(strings.get('micPermissionRequired'))),
        );
        return;
      }
      await _recorder!.start();
      setState(() {
        _recording = true;
        _recordSeconds = 0;
      });
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() => _recordSeconds++);
        if (_recordSeconds >= 120) _toggleRecord();
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_errorText(error, strings))),
      );
    }
  }

  void _scrollToBottom({bool animate = true}) {
    if (!_scroll.hasClients) return;
    final target = _scroll.position.maxScrollExtent;
    if (animate) {
      _scroll.animateTo(target, duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
    } else {
      _scroll.jumpTo(target);
    }
  }

  void _syncRustle(MessagesState state) {
    final settings = ref.read(settingsProvider);
    final shouldPlay = settings.presenceSoundId.isNotEmpty &&
        state.presence != Presence.offline;
    if (shouldPlay && !_rustling) {
      _rustling = true;
      _audio?.startPresence(settings.presenceSoundId);
    } else if (!shouldPlay && _rustling) {
      _rustling = false;
      _audio?.stopPresence();
    }
  }

  Chat? _findChat(ChatsState chats) {
    for (final chat in [...chats.chats, ...chats.archived]) {
      if (chat.id == widget.chatId) return chat;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(stringsProvider);
    final palette = context.palette;
    final state = ref.watch(messagesProvider(widget.chatId));
    final chats = ref.watch(chatsProvider);
    final chat = _findChat(chats);
    final name = chat?.peerName ?? widget.initialTitle ?? 'Coralink';

    ref.listen<MessagesState>(messagesProvider(widget.chatId), (previous, next) {
      if (previous == null) return;
      if (next.messages.length != previous.messages.length || next.messages.length != _lastCount) {
        _lastCount = next.messages.length;
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
      if (next.presence != previous.presence || next.lastSeen != previous.lastSeen) {
        _syncRustle(next);
      }
    });

    final connection = ref.watch(chatsProvider.select((s) => s.connection));
    final connected = connection == RealtimeStatus.connected;

    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(
        titleSpacing: 0,
        leading: IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: Row(
          children: [
            SeedAvatar(
              seedId: widget.chatId,
              name: name,
              colorHex: chat?.peerAvatarColor,
              avatar: chat?.peerAvatar,
              online: state.presence != Presence.offline,
              size: 36,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (state.peerTyping) ...[
                        TypingDots(color: palette.accentSoft),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(
                          (chat?.isGroup ?? false)
                              ? strings
                                  .get('membersCount')
                                  .replaceAll('{count}', '${chat!.memberCount}')
                              : state.peerTyping
                                  ? strings.get('typing')
                                  : switch (state.presence) {
                                      Presence.online => strings.get('online'),
                                      Presence.active => strings.get('active'),
                                      Presence.away => strings.get('away'),
                                      Presence.offline =>
                                        lastSeenLabel(state.lastSeen, strings),
                                    },
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: palette.textMuted, fontSize: 11.5),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (state.direct)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(Icons.bolt_rounded, color: palette.halo, size: 22),
            ),
          if (!connected)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(Icons.cloud_off_rounded, color: palette.coral, size: 18),
            ),
          if (!(chat?.isGroup ?? false)) ...[
            IconButton(
              tooltip: strings.get('audioCall'),
              onPressed: () => _startCall(false),
              icon: Icon(Icons.call_rounded, color: palette.accent),
            ),
            IconButton(
              tooltip: strings.get('videoCall'),
              onPressed: () => _startCall(true),
              icon: Icon(Icons.videocam_rounded, color: palette.accent),
            ),
          ],
          IconButton(
            onPressed: () => _showChatMenu(chat, strings),
            icon: const Icon(Icons.more_vert_rounded),
          ),
        ],
      ),
      body: CoralBackground(
        child: Column(
        children: [
          Expanded(
            child: state.loading
                ? Center(child: CircularProgressIndicator(color: palette.accent))
                : _buildMessages(state, strings, chat),
          ),
          if (state.peerTyping)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 2, 24, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    TypingDots(color: palette.accentSoft),
                    const SizedBox(width: 8),
                    Text(
                      strings.get('typing'),
                      style: TextStyle(color: palette.textMuted, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            ),
          _buildInput(strings, palette),
        ],
        ),
      ),
    );
  }

  Widget _buildMessages(MessagesState state, AppStrings strings, Chat? chat) {
    final palette = context.palette;
    final widgets = <Widget>[];
    if (state.archivedCount > 0) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => ref.read(messagesProvider(widget.chatId).notifier).toggleArchive(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: palette.surface.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: palette.divider),
              ),
              child: Row(
                children: [
                  Icon(Icons.waves_rounded, size: 16, color: palette.accentSoft),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      state.showArchive
                          ? strings.get('hideArchive')
                          : '${strings.get('showArchive')} (${state.archivedCount})',
                      style: TextStyle(color: palette.textMuted, fontSize: 12.5),
                    ),
                  ),
                  Icon(
                    state.showArchive
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: palette.textMuted,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    widgets.add(
      Padding(
        padding: const EdgeInsets.fromLTRB(30, 10, 30, 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline_rounded, size: 12, color: palette.textMuted),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                strings.get('encryptionNotice'),
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.textMuted, fontSize: 10.5),
              ),
            ),
          ],
        ),
      ),
    );

    if (state.messages.isEmpty && state.calls.isEmpty) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 50),
          child: Column(
            children: [
              Icon(Icons.spa_outlined, size: 40, color: palette.accentSoft),
              const SizedBox(height: 14),
              Text(
                strings.get('chatEmpty'),
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.textMuted, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }

    // Messages and call history share one chronological timeline, so the
    // conversation shows "Аудиозвонок · 2:31" exactly where it happened.
    final entries = <({DateTime at, Widget child})>[];
    final myId = ref.read(sessionProvider).user?.id ?? '';
    for (final message in state.messages) {
      entries.add((
        at: message.createdAt,
        child: MessageBubble(
          key: ValueKey(message.id),
          message: message,
          myId: myId,
          strings: strings,
          onLongPress: () => _showMessageActions(message, strings),
          onOpenFile: message.isFile ? () => _saveFile(message, strings) : null,
          onRetry: message.status == MessageStatus.failed
              ? () => ref.read(messagesProvider(widget.chatId).notifier).retry(message)
              : null,
        ),
      ));
    }
    for (final call in state.calls) {
      entries.add((
        at: call.startedAt,
        child: CallHistoryChip(
          key: ValueKey('call-${call.id}'),
          record: call,
          strings: strings,
        ),
      ));
    }
    entries.sort((a, b) => a.at.compareTo(b.at));

    DateTime? lastDay;
    for (final entry in entries) {
      final local = entry.at.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      if (lastDay == null || day != lastDay) {
        widgets.add(DateDivider(label: relativeDay(entry.at, strings)));
        lastDay = day;
      }
      widgets.add(entry.child);
    }

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(top: 6, bottom: 12),
      itemCount: widgets.length,
      itemBuilder: (context, index) => widgets[index],
    );
  }

  Widget _buildInput(AppStrings strings, CoralinkPalette palette) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: palette.navBackground.withValues(alpha: 0.92),
        border: Border(top: BorderSide(color: palette.divider)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!_recording)
              IconButton(
                onPressed: () => _showAttachments(strings),
                icon: Icon(Icons.add_circle_outline_rounded, color: palette.accentSoft),
              ),
            if (!_recording)
              IconButton(
                tooltip: strings.get('stickersTitle'),
                onPressed: () => _showStickers(strings),
                icon: Icon(Icons.emoji_emotions_outlined, color: palette.accentSoft),
              ),
            Expanded(
              child: _recording
                  ? Container(
                      height: 48,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        color: palette.inputFill,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.mic_rounded, color: palette.coral),
                          const SizedBox(width: 10),
                          Text(
                            '${_recordSeconds ~/ 60}:${(_recordSeconds % 60).toString().padLeft(2, '0')}',
                            style: TextStyle(
                              color: palette.textPrimary,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              strings.get('recording'),
                              style: TextStyle(color: palette.textMuted, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    )
                  : TextField(
                      controller: _text,
                      focusNode: _focus,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      style: TextStyle(color: palette.textPrimary, fontSize: 15),
                      decoration: InputDecoration(
                        hintText: strings.get('messageHint'),
                        isDense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                      onChanged: (value) {
                        setState(() => _canSend = value.trim().isNotEmpty);
                        ref
                            .read(messagesProvider(widget.chatId).notifier)
                            .onTextChanged(value);
                      },
                      onSubmitted: (_) => _send(strings),
                    ),
            ),
            const SizedBox(width: 6),
            if (_recording)
              GestureDetector(
                onTap: _toggleRecord,
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: palette.coral,
                  ),
                  child: const Icon(Icons.stop_rounded, color: Colors.white, size: 22),
                ),
              )
            else if (_canSend)
              GestureDetector(
                onTap: () => _send(strings),
                child: AnimatedScale(
                  scale: _sendPulse ? 1.18 : 1,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutBack,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [palette.accent, palette.accentSoft],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: palette.accent.withValues(alpha: 0.4),
                          blurRadius: 14,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.arrow_upward_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ),
              )
            else
              IconButton(
                onPressed: _toggleRecord,
                icon: Icon(Icons.mic_rounded, color: palette.accentSoft),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _send(AppStrings strings) async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    _text.clear();
    setState(() => _canSend = false);
    _sendPulse = true;
    Future.delayed(const Duration(milliseconds: 220), () {
      if (mounted) setState(() => _sendPulse = false);
    });
    try {
      await ref.read(messagesProvider(widget.chatId).notifier).sendText(text);
      _scrollToBottom();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_errorText(error, strings))),
      );
    }
  }

  Future<void> _showStickers(AppStrings strings) async {
    final palette = context.palette;
    final picked = await showModalBottomSheet<CoralSticker>(
      context: context,
      showDragHandle: true,
      backgroundColor: palette.surface,
      builder: (context) => StickerPicker(
        strings: strings,
        onPick: (sticker) => Navigator.pop(context, sticker),
      ),
    );
    if (picked == null) return;
    try {
      await ref
          .read(messagesProvider(widget.chatId).notifier)
          .sendSticker(stickerIdOf(picked));
      _scrollToBottom();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_errorText(error, strings))),
      );
    }
  }

  Future<void> _showAttachments(AppStrings strings) async {
    final mobile = defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final choice = await showModalBottomSheet<_Attach>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SettingsTile(
              icon: Icons.photo_library_outlined,
              title: strings.get('gallery'),
              onTap: () => Navigator.pop(context, _Attach.gallery),
            ),
            if (mobile)
              SettingsTile(
                icon: Icons.photo_camera_outlined,
                title: strings.get('camera'),
                onTap: () => Navigator.pop(context, _Attach.camera),
              ),
            SettingsTile(
              icon: Icons.attach_file_rounded,
              title: strings.get('file'),
              onTap: () => Navigator.pop(context, _Attach.file),
            ),
            SettingsTile(
              icon: Icons.videocam_rounded,
              title: strings.get('videoMessage'),
              onTap: () => Navigator.pop(context, _Attach.video),
            ),
            if (mobile)
              SettingsTile(
                icon: Icons.crop_rounded,
                title: strings.get('videoNote'),
                onTap: () => Navigator.pop(context, _Attach.videoNote),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    switch (choice) {
      case _Attach.gallery:
        await _pickImage(ImageSource.gallery, strings);
      case _Attach.camera:
        await _pickImage(ImageSource.camera, strings);
      case _Attach.file:
        await _pickFile(strings);
      case _Attach.video:
        await _pickVideo(strings);
      case _Attach.videoNote:
        await _recordVideoNote(strings);
      case null:
        break;
    }
  }

  Future<void> _pickImage(ImageSource source, AppStrings strings) async {
    try {
      final file = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1280,
        imageQuality: 65,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.lengthInBytes > 340 * 1024) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(strings.get('imageTooLarge'))),
        );
        return;
      }
      final mime = lookupMimeType(file.name) ?? 'image/jpeg';
      await ref.read(messagesProvider(widget.chatId).notifier).sendImage(
            base64Encode(bytes),
            mime,
            file.name,
          );
      _scrollToBottom();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_errorText(error, strings))),
      );
    }
  }

  Future<void> _pickFile(AppStrings strings) async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.any);
      if (files.isEmpty) return;
      final picked = files.single;
      final bytes = await picked.readAsBytes();
      if (bytes.lengthInBytes > 6 * 1024 * 1024) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(strings.get('fileTooLarge'))),
        );
        return;
      }
      final mime = picked.extension != null
          ? (lookupMimeType('x.${picked.extension}') ?? 'application/octet-stream')
          : 'application/octet-stream';
      await ref.read(messagesProvider(widget.chatId).notifier).sendFile(
            base64Encode(bytes),
            mime,
            picked.name,
            bytes.lengthInBytes,
          );
      _scrollToBottom();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_errorText(error, strings))),
      );
    }
  }

  String _errorText(Object error, AppStrings strings) {
    if (error is ArgumentError) {
      final message = '${error.message}';
      if (message.contains('image_too_large')) return strings.get('imageTooLarge');
      if (message.contains('file_too_large')) return strings.get('fileTooLarge');
      if (message.contains('long')) return strings.get('imageTooLarge');
    }
    if (error is EncryptionException) {
      return switch (error.code) {
        'no_keys' => strings.get('noKeys'),
        'identity_changed' => strings.get('identityChanged'),
        _ => strings.get('networkError'),
      };
    }
    return strings.get('networkError');
  }

  Future<void> _pickVideo(AppStrings strings) async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.video);
      if (files.isEmpty) return;
      final picked = files.single;
      final bytes = await picked.readAsBytes();
      if (bytes.lengthInBytes > 6 * 1024 * 1024) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(strings.get('fileTooLarge'))),
        );
        return;
      }
      final mime = picked.extension != null
          ? (lookupMimeType('x.${picked.extension}') ?? 'video/mp4')
          : 'video/mp4';
      await ref.read(messagesProvider(widget.chatId).notifier).sendVideo(
            base64Encode(bytes),
            mime,
            picked.name,
            bytes.lengthInBytes,
          );
      _scrollToBottom();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_errorText(error, strings))),
      );
    }
  }

  // Captures a short front-facing clip for a circular video note. Kept brief
  // and low-res by the native camera, and re-checked against the relay cap.
  Future<void> _recordVideoNote(AppStrings strings) async {
    try {
      final file = await ImagePicker().pickVideo(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        maxDuration: const Duration(seconds: 12),
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.lengthInBytes > 6 * 1024 * 1024) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(strings.get('fileTooLarge'))),
        );
        return;
      }
      final mime = file.name.endsWith('.webm')
          ? 'video/webm'
          : (lookupMimeType(file.name) ?? 'video/mp4');
      await ref.read(messagesProvider(widget.chatId).notifier).sendVideoNote(
            base64Encode(bytes),
            mime,
            bytes.lengthInBytes,
            0,
          );
      _scrollToBottom();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_errorText(error, strings))),
      );
    }
  }

  Future<void> _saveFile(Message message, AppStrings strings) async {
    final data = message.meta['data'];
    if (data is! String) return;
    final bytes = base64Decode(data);
    final name = (message.meta['name'] as String?) ?? 'file';
    try {
      final saved = await FilePicker.saveFile(fileName: name, bytes: bytes);
      if (!mounted) return;
      final where = saved != null && saved.scheme == 'file'
          ? ' ${saved.toFilePath()}'
          : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${strings.get('savedTo')}$where')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_errorText(error, strings))),
      );
    }
  }

  Future<void> _showMessageActions(Message message, AppStrings strings) async {
    final palette = context.palette;
    final mine = message.senderId == ref.read(sessionProvider).user?.id;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
              child: Row(
                children: [
                  for (final emoji in const ['💧', '🌿', '🪷', '✨'])
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: () {
                          Navigator.pop(sheetContext);
                          ref
                              .read(messagesProvider(widget.chatId).notifier)
                              .react(message.id, emoji);
                        },
                        child: Container(
                          width: 46,
                          height: 46,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: palette.surfaceElevated,
                            border: Border.all(color: palette.divider),
                          ),
                          child: Text(emoji, style: const TextStyle(fontSize: 21)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (message.text.isNotEmpty && !message.deleted)
              SettingsTile(
                icon: Icons.copy_rounded,
                title: strings.get('copy'),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: message.text));
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(strings.get('copied'))),
                  );
                },
              ),
            SettingsTile(
              icon: Icons.delete_sweep_outlined,
              title: strings.get('deleteForMe'),
              onTap: () {
                Navigator.pop(sheetContext);
                ref.read(messagesProvider(widget.chatId).notifier).deleteForMe(message.id);
              },
            ),
            if (mine)
              SettingsTile(
                icon: Icons.delete_forever_outlined,
                title: strings.get('deleteForEveryone'),
                danger: true,
                onTap: () async {
                  Navigator.pop(sheetContext);
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      backgroundColor: palette.surface,
                      title: Text(strings.get('deleteMessage')),
                      content: Text(strings.get('deleteForEveryone')),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: Text(strings.get('cancel')),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: Text(strings.get('delete'), style: TextStyle(color: palette.coral)),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    await ref
                        .read(messagesProvider(widget.chatId).notifier)
                        .deleteForEveryone(message.id);
                  }
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _startCall(bool withVideo) async {
    final call = ref.read(callProvider);
    if (call.inCall) return;
    await call.start(widget.chatId, withVideo: withVideo);
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CallScreen(peerId: widget.chatId, initialVideo: withVideo),
      ),
    );
  }

  Future<void> _showGroupMembers(Chat chat, AppStrings strings) async {
    final palette = context.palette;
    final client = ref.read(clientProvider);
    Group group;
    try {
      group = await client.api.groupDetail(chat.id);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_errorText(error, strings))),
      );
      return;
    }
    if (!mounted) return;
    final myId = ref.read(sessionProvider).user?.id;
    final isAdmin = group.members.any(
      (m) => m.id == myId && (m.role == 'owner' || m.role == 'admin'),
    );
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Row(
                  children: [
                    SeedAvatar(
                      seedId: chat.id,
                      name: group.title,
                      avatar: group.avatar,
                      size: 44,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            group.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.textPrimary,
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            strings
                                .get('membersCount')
                                .replaceAll('{count}', '${group.memberCount}'),
                            style: TextStyle(color: palette.textMuted, fontSize: 12.5),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              for (final member in group.members)
                ListTile(
                  leading: SeedAvatar(
                    seedId: member.id,
                    name: member.name,
                    colorHex: member.avatarColor,
                    avatar: member.avatar,
                    size: 44,
                  ),
                  title: Text(
                    member.id == myId
                        ? '${member.name} (${strings.get('you')})'
                        : member.name,
                    style: TextStyle(color: palette.textPrimary),
                  ),
                  subtitle: Text(
                    member.username.isNotEmpty
                        ? '@${member.username}'
                        : '',
                    style: TextStyle(color: palette.textMuted, fontSize: 12.5),
                  ),
                  trailing: (member.role == 'owner' || member.role == 'admin')
                      ? Chip(
                          label: Text(strings.get('roleAdmin'),
                              style: TextStyle(fontSize: 11, color: palette.accent)),
                          backgroundColor:
                              palette.accent.withValues(alpha: 0.12),
                          side: BorderSide(color: palette.divider),
                        )
                      : null,
                ),
              if (isAdmin)
                SettingsTile(
                  icon: Icons.edit_outlined,
                  title: strings.get('renameGroup'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _renameGroup(chat.id, group.title, strings);
                  },
                ),
              if (isAdmin)
                SettingsTile(
                  icon: Icons.image_outlined,
                  title: strings.get('groupAvatar'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _setGroupAvatar(chat.id, strings);
                  },
                ),
              SettingsTile(
                icon: Icons.person_add_alt_1_rounded,
                title: strings.get('inviteToGroup'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _inviteToGroup(chat.id, strings);
                },
              ),
              SettingsTile(
                icon: Icons.logout_rounded,
                title: strings.get('leaveGroup'),
                danger: true,
                onTap: () async {
                  Navigator.pop(sheetContext);
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      backgroundColor: palette.surface,
                      title: Text(strings.get('leaveGroup')),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: Text(strings.get('cancel')),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: Text(
                            strings.get('leaveGroup'),
                            style: TextStyle(color: palette.coral),
                          ),
                        ),
                      ],
                    ),
                  );
                  if (confirmed != true) return;
                  await client.messages.leaveGroup(chat.id);
                  await ref.read(chatsProvider.notifier).refresh();
                  if (!mounted) return;
                  Navigator.of(context).pop();
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _renameGroup(String groupId, String current, AppStrings strings) async {
    final palette = context.palette;
    final controller = TextEditingController(text: current);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: palette.surface,
        title: Text(strings.get('renameGroup')),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 64,
          decoration: InputDecoration(labelText: strings.get('groupTitle')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(strings.get('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.get('save')),
          ),
        ],
      ),
    );
    final title = controller.text.trim();
    controller.dispose();
    if (saved != true || title.isEmpty || title == current) return;
    try {
      await ref.read(clientProvider).messages.updateGroup(groupId, title: title);
      await ref.read(chatsProvider.notifier).refresh();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_errorText(error, strings))),
      );
    }
  }

  Future<void> _setGroupAvatar(String groupId, AppStrings strings) async {
    final mobile = defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final source = await showModalBottomSheet<_AvatarChoice>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SettingsTile(
              icon: Icons.photo_library_outlined,
              title: strings.get('gallery'),
              onTap: () => Navigator.pop(context, _AvatarChoice.gallery),
            ),
            if (mobile)
              SettingsTile(
                icon: Icons.photo_camera_outlined,
                title: strings.get('camera'),
                onTap: () => Navigator.pop(context, _AvatarChoice.camera),
              ),
            SettingsTile(
              icon: Icons.delete_outline_rounded,
              title: strings.get('removePhoto'),
              onTap: () => Navigator.pop(context, _AvatarChoice.remove),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null) return;
    try {
      String avatar = '';
      if (source != _AvatarChoice.remove) {
        final file = await ImagePicker().pickImage(
          source: source == _AvatarChoice.camera ? ImageSource.camera : ImageSource.gallery,
          maxWidth: 320,
          maxHeight: 320,
          imageQuality: 82,
        );
        if (file == null) return;
        final bytes = await file.readAsBytes();
        if (bytes.lengthInBytes > 360 * 1024) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(strings.get('imageTooLarge'))),
          );
          return;
        }
        avatar = 'data:image/jpeg;base64,${base64Encode(bytes)}';
      }
      await ref.read(clientProvider).messages.updateGroup(groupId, avatar: avatar);
      await ref.read(chatsProvider.notifier).refresh();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_errorText(error, strings))),
      );
    }
  }

  Future<void> _inviteToGroup(String groupId, AppStrings strings) async {
    final palette = context.palette;
    final client = ref.read(clientProvider);
    final controller = TextEditingController();
    var results = <User>[];
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: palette.surface,
          title: Text(strings.get('inviteToGroup')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: strings.get('nicknamePlaceholder'),
                  prefixIcon: Icon(Icons.search_rounded, color: palette.accent),
                ),
                onChanged: (value) async {
                  final query = value.trim();
                  if (query.length < 2) {
                    setDialogState(() => results = const []);
                    return;
                  }
                  try {
                    final found = await client.api.searchUsers(
                      query.startsWith('@') ? query.substring(1) : query,
                    );
                    setDialogState(() => results = found);
                  } catch (_) {
                    setDialogState(() => results = const []);
                  }
                },
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final user in results)
                      ListTile(
                        title: Text(user.name,
                            style: TextStyle(color: palette.textPrimary)),
                        subtitle: user.username.isNotEmpty
                            ? Text('@${user.username}',
                                style: TextStyle(color: palette.textMuted))
                            : null,
                        onTap: () async {
                          Navigator.pop(dialogContext);
                          await client.messages.inviteToGroup(groupId, user.id);
                          await ref.read(chatsProvider.notifier).refresh();
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(strings.get('cancel')),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
  }

  Future<void> _showChatMenu(Chat? chat, AppStrings strings) async {
    final palette = context.palette;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (chat != null) ...[
              SettingsTile(
                icon: chat.pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
                title: strings.get(chat.pinned ? 'unpin' : 'pinned'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  ref.read(chatsProvider.notifier).togglePin(chat.id);
                },
              ),
              SettingsTile(
                icon: chat.muted ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                title: chat.muted
                    ? (strings.locale.languageCode == 'en' ? 'Unmute' : 'Включить звук')
                    : (strings.locale.languageCode == 'en' ? 'Mute' : 'Без звука'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  ref.read(chatsProvider.notifier).toggleMute(chat.id);
                },
              ),
              SettingsTile(
                icon: chat.archived ? Icons.unarchive_rounded : Icons.archive_outlined,
                title: strings.get(chat.archived ? 'unarchive' : 'archiveAction'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  if (chat.archived) {
                    ref.read(chatsProvider.notifier).unarchive(chat.id);
                  } else {
                    ref.read(chatsProvider.notifier).archive(chat.id);
                  }
                },
              ),
              if (chat.isGroup)
                SettingsTile(
                  icon: Icons.groups_rounded,
                  title: strings.get('groupMembers'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showGroupMembers(chat, strings);
                  },
                ),
            ],
            SettingsTile(
              icon: Icons.cleaning_services_outlined,
              title: strings.get('clearHistory'),
              onTap: () async {
                Navigator.pop(sheetContext);
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    backgroundColor: palette.surface,
                    title: Text(strings.get('clearHistory')),
                    content: Text(strings.get('clearHistoryConfirm')),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(strings.get('cancel')),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: Text(strings.get('clearHistory'), style: TextStyle(color: palette.coral)),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await ref.read(clientProvider).store.deleteMessages(widget.chatId);
                  await ref.read(messagesProvider(widget.chatId).notifier).reload();
                  ref.read(chatsProvider.notifier).refresh();
                }
              },
            ),
            SettingsTile(
              icon: Icons.block_rounded,
              title: strings.get('blocked'),
              subtitle: strings.get('blockedInfo'),
              danger: true,
              onTap: () {
                Navigator.pop(sheetContext);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(strings.get('blockedInfo'))),
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
