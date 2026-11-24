import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/app_colors.dart';
import '../../core/strings.dart';
import '../../core/utils.dart';
import '../../domain/models.dart';
import '../../services/video_note_media.dart';
import 'coral_widgets.dart';
import 'pet_widgets.dart';
import 'stickers.dart';

class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.myId,
    required this.strings,
    this.onLongPress,
    this.onRetry,
    this.onOpenFile,
    this.onOpenPet,
    this.highlight = false,
  });

  final Message message;
  final String myId;
  final AppStrings strings;
  final VoidCallback? onLongPress;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenFile;
  final VoidCallback? onOpenPet;
  final bool highlight;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 460),
  );
  late final Animation<double> _scale = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutBack,
  );
  bool _showTime = false;

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final message = widget.message;
    final mine = message.senderId == widget.myId;
    final maxWidth = MediaQuery.sizeOf(context).width * 0.76;
    final deleted = message.deleted;

    // Stickers live outside the chat bubble: they are little illustrations of
    // their own, with the delivery drop tucked underneath.
    if (message.isPet && !deleted) {
      return PetEventChip(
        message: message,
        mine: mine,
        strings: widget.strings,
        highlight: widget.highlight,
        onTap: widget.onOpenPet,
        onLongPress: widget.onLongPress,
      );
    }

    if (message.isSticker && !deleted) {
      final sticker =
          stickerFromId(message.meta['sticker'] as String?) ??
          CoralSticker.wave;
      return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.fromLTRB(mine ? 56 : 14, 4, mine ? 14 : 56, 4),
          child: GestureDetector(
            onLongPress: widget.onLongPress,
            child: Column(
              crossAxisAlignment: mine
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: palette.surface.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(28),
                    border: widget.highlight
                        ? Border.all(
                            color: palette.halo.withValues(alpha: 0.75),
                            width: 1.4,
                          )
                        : null,
                  ),
                  child: StickerView(sticker: sticker, size: 132),
                ),
                const SizedBox(height: 2),
                _buildFooter(message, mine, palette.textMuted),
                if (message.status == MessageStatus.failed && mine)
                  _buildRetry(palette),
              ],
            ),
          ),
        ),
      );
    }

    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: EdgeInsets.fromLTRB(15, message.isImage ? 6 : 11, 15, 9),
      decoration: BoxDecoration(
        color: mine ? palette.outgoingBubble : palette.incomingBubble,
        gradient: mine
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  palette.outgoingBubble,
                  Color.lerp(palette.outgoingBubble, palette.accentSoft, 0.22)!,
                ],
              )
            : null,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(mine ? 18 : 5),
          bottomRight: Radius.circular(mine ? 5 : 18),
        ),
        border: widget.highlight
            ? Border.all(
                color: palette.halo.withValues(alpha: 0.75),
                width: 1.4,
              )
            : null,
        boxShadow: [
          BoxShadow(
            color: (mine ? palette.accent : Colors.black).withValues(
              alpha: 0.10,
            ),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (deleted)
            Text(
              widget.strings.get('messageDeleted'),
              style: TextStyle(
                color: mine
                    ? palette.outgoingText.withValues(alpha: 0.7)
                    : palette.incomingText.withValues(alpha: 0.65),
                fontStyle: FontStyle.italic,
                fontSize: 14,
              ),
            )
          else ...[
            if (message.isImage && message.imageBase64 != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(13),
                child: Image.memory(
                  _bytes(message.imageBase64!),
                  fit: BoxFit.cover,
                  width: maxWidth - 30,
                  errorBuilder: (_, __, ___) => Padding(
                    padding: const EdgeInsets.all(20),
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: palette.incomingText,
                    ),
                  ),
                ),
              ),
            if (message.isImage) const SizedBox(height: 6),
            if (message.isAudio) _AudioBubble(message: message, mine: mine),
            if (message.isAudio && message.text.isNotEmpty)
              const SizedBox(height: 6),
            if (message.isVideoNote)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: _VideoNoteBubble(
                  base64Data: (message.meta['data'] as String?) ?? '',
                  mime: (message.meta['mime'] as String?) ?? 'video/mp4',
                  mine: mine,
                ),
              ),
            if (message.isVideoNote && message.text.isNotEmpty)
              const SizedBox(height: 6),
            if (message.isFile || message.isVideo)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: widget.onOpenFile,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: (mine ? palette.accent : palette.accentSoft)
                              .withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          _fileIcon(message.meta['mime'] as String?),
                          color: mine ? palette.outgoingText : palette.accent,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              (message.meta['name'] as String?) ??
                                  widget.strings.get('file'),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: mine
                                    ? palette.outgoingText
                                    : palette.incomingText,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _formatSize(message.meta['size']),
                              style: TextStyle(
                                color: mine
                                    ? palette.outgoingText.withValues(
                                        alpha: 0.75,
                                      )
                                    : palette.textMuted,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.download_rounded,
                        size: 18,
                        color: mine ? palette.outgoingText : palette.accent,
                      ),
                    ],
                  ),
                ),
              ),
            if ((message.isFile || message.isVideo) && message.text.isNotEmpty)
              const SizedBox(height: 6),
            if (message.text.isNotEmpty)
              Text(
                message.text,
                style: TextStyle(
                  color: mine ? palette.outgoingText : palette.incomingText,
                  fontSize: 15,
                  height: 1.32,
                ),
              ),
          ],
          const SizedBox(height: 4),
          _buildFooter(
            message,
            mine,
            mine ? palette.outgoingText : palette.incomingText,
            deleted: deleted,
          ),
          if (message.reactions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Wrap(
                spacing: 5,
                runSpacing: 4,
                children: [
                  for (final entry in message.reactions.entries)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color:
                            (mine ? palette.outgoingText : palette.incomingText)
                                .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                        border: entry.value.contains(widget.myId)
                            ? Border.all(
                                color:
                                    (mine
                                            ? palette.outgoingText
                                            : palette.incomingText)
                                        .withValues(alpha: 0.5),
                              )
                            : null,
                      ),
                      child: Text(
                        '${entry.key} ${entry.value.length}',
                        style: TextStyle(
                          fontSize: 12,
                          color: mine
                              ? palette.outgoingText
                              : palette.incomingText,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if (message.status == MessageStatus.failed && mine)
            _buildRetry(palette),
        ],
      ),
    );

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.fromLTRB(mine ? 56 : 14, 3, mine ? 14 : 56, 3),
        child: FadeTransition(
          opacity: _controller,
          child: ScaleTransition(
            scale: _scale,
            alignment: mine ? Alignment.bottomRight : Alignment.bottomLeft,
            child: GestureDetector(
              onTap: () => setState(() => _showTime = !_showTime),
              onLongPress: widget.onLongPress,
              child: bubble,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFooter(
    Message message,
    bool mine,
    Color textColor, {
    bool deleted = false,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _showTime = !_showTime),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_showTime)
            Padding(
              padding: const EdgeInsets.only(right: 7),
              child: Text(
                formatClock(message.createdAt),
                style: TextStyle(
                  fontSize: 10,
                  color: textColor.withValues(alpha: 0.65),
                ),
              ),
            ),
          if (mine && !deleted)
            _StatusDrop(
              status: message.status,
              onTap: () => setState(() => _showTime = !_showTime),
            ),
        ],
      ),
    );
  }

  Widget _buildRetry(CoralinkPalette palette) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: InkWell(
      onTap: widget.onRetry,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.refresh_rounded, size: 14, color: palette.coral),
          const SizedBox(width: 4),
          Text(
            widget.strings.get('failedToSend'),
            style: TextStyle(fontSize: 11.5, color: palette.coral),
          ),
        ],
      ),
    ),
  );

  Uint8List _bytes(String value) {
    try {
      return base64Decode(value);
    } catch (_) {
      return Uint8List(0);
    }
  }

  IconData _fileIcon(String? mime) {
    if (mime == null) return Icons.insert_drive_file_rounded;
    if (mime.startsWith('image/')) return Icons.image_rounded;
    if (mime.startsWith('video/')) return Icons.movie_rounded;
    if (mime.startsWith('audio/')) return Icons.audiotrack_rounded;
    if (mime.contains('pdf')) return Icons.picture_as_pdf_rounded;
    if (mime.contains('zip') ||
        mime.contains('compressed') ||
        mime.contains('rar')) {
      return Icons.folder_zip_rounded;
    }
    if (mime.contains('sheet') || mime.contains('excel'))
      return Icons.table_chart_rounded;
    if (mime.contains('document') || mime.contains('word'))
      return Icons.description_rounded;
    if (mime.contains('text')) return Icons.article_rounded;
    return Icons.insert_drive_file_rounded;
  }

  String _formatSize(Object? raw) {
    final bytes = raw is num ? raw.toInt() : 0;
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Delivery drop: blue until read, green after the recipient opens the message.
class _StatusDrop extends StatelessWidget {
  const _StatusDrop({required this.status, this.onTap});
  final MessageStatus status;
  final VoidCallback? onTap;

  static const _unread = Color(0xFF63B3FF);
  static const _read = Color(0xFF73E2B4);
  static const _failed = Color(0xFFFF6B6B);

  String _label(AppStrings strings) => switch (status) {
    MessageStatus.sending => strings.get('statusSending'),
    MessageStatus.sent => strings.get('statusSent'),
    MessageStatus.delivered => strings.get('statusDelivered'),
    MessageStatus.read => strings.get('statusRead'),
    MessageStatus.failed => strings.get('failedToSend'),
  };

  @override
  Widget build(BuildContext context) {
    final (color, size, opacity) = switch (status) {
      MessageStatus.sending => (_unread, 11.0, 0.55),
      MessageStatus.sent => (_unread, 12.5, 0.85),
      MessageStatus.delivered => (_unread, 14.0, 1.0),
      MessageStatus.read => (_read, 14.5, 1.0),
      MessageStatus.failed => (_failed, 14.0, 1.0),
    };
    final read = status == MessageStatus.read;
    final delivered = status == MessageStatus.delivered;
    return Semantics(
      label: _label(AppStrings(Localizations.localeOf(context))),
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: (read || delivered)
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.55),
                      blurRadius: read ? 9 : 5,
                      spreadRadius: read ? 1.5 : 0.5,
                    ),
                  ]
                : null,
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                Icons.water_drop_rounded,
                size: size,
                color: color.withValues(alpha: opacity),
              ),
              if (read)
                Positioned(
                  bottom: 1.5,
                  child: Icon(
                    Icons.check_rounded,
                    size: 7.5,
                    color: const Color(0xFF0D2E1F),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class DateDivider extends StatelessWidget {
  const DateDivider({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 40),
      child: Row(
        children: [
          Expanded(child: Divider(color: palette.divider)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              label,
              style: TextStyle(
                color: palette.textMuted,
                fontSize: 11.5,
                letterSpacing: 0.3,
              ),
            ),
          ),
          Expanded(child: Divider(color: palette.divider)),
        ],
      ),
    );
  }
}

class ChatTile extends StatelessWidget {
  const ChatTile({
    super.key,
    required this.chat,
    required this.strings,
    required this.onTap,
    required this.onLongPress,
    this.onArchive,
    this.growing = false,
  });

  final Chat chat;
  final AppStrings strings;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback? onArchive;

  /// Plays the "new coral grew" animation for a freshly appeared chat.
  final bool growing;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final unread = chat.unreadCount > 0;
    final online = chat.peerPresence != Presence.offline;
    final statusLabel = chat.isGroup
        ? strings
              .get('membersCount')
              .replaceAll('{count}', '${chat.memberCount}')
        : switch (chat.peerPresence) {
            Presence.online => strings.get('online'),
            Presence.active => strings.get('active'),
            Presence.away => strings.get('away'),
            Presence.offline => lastSeenLabel(chat.peerLastSeen, strings),
          };

    final content = InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 14, 10),
        child: Row(
          children: [
            SizedBox(
              width: 54,
              height: 54,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  if (growing)
                    OverflowBox(
                      maxWidth: 94,
                      maxHeight: 94,
                      child: const GrowingCoral(size: 94),
                    ),
                  SeedAvatar(
                    seedId: chat.peerId,
                    name: chat.peerName,
                    colorHex: chat.peerAvatarColor,
                    avatar: chat.peerAvatar,
                    online: online,
                    pulse: unread,
                    size: 54,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (chat.pinned)
                        Padding(
                          padding: const EdgeInsets.only(right: 5),
                          child: Icon(
                            Icons.push_pin_rounded,
                            size: 13,
                            color: palette.accent,
                          ),
                        ),
                      Expanded(
                        child: Text(
                          chat.peerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontWeight: unread
                                ? FontWeight.w600
                                : FontWeight.w500,
                            fontSize: 15.5,
                          ),
                        ),
                      ),
                      if (chat.muted)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Icon(
                            Icons.volume_off_rounded,
                            size: 14,
                            color: palette.textMuted,
                          ),
                        ),
                      const SizedBox(width: 6),
                      Text(
                        chat.lastMessageAt == null
                            ? ''
                            : formatChatStamp(chat.lastMessageAt!, strings),
                        style: TextStyle(
                          color: unread
                              ? palette.accentSoft
                              : palette.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          chat.lastMessageText.isEmpty
                              ? statusLabel
                              : chat.lastMessageText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: unread
                                ? palette.textPrimary.withValues(alpha: 0.9)
                                : palette.textMuted,
                            fontSize: 13.4,
                          ),
                        ),
                      ),
                      if (unread)
                        Container(
                          width: 9,
                          height: 9,
                          margin: const EdgeInsets.only(left: 8),
                          decoration: BoxDecoration(
                            color: palette.accent,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: palette.accent.withValues(alpha: 0.6),
                                blurRadius: 8,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return Dismissible(
      key: ValueKey('chat-${chat.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 28),
        color: palette.surfaceElevated,
        child: Icon(Icons.arrow_downward_rounded, color: palette.accent),
      ),
      onDismissed: (_) => onArchive?.call(),
      child: content,
    );
  }
}

/// A call entry inside the conversation timeline (like the call rows of other
/// messengers). Data comes from the persisted call history.
class CallHistoryChip extends StatelessWidget {
  const CallHistoryChip({
    super.key,
    required this.record,
    required this.strings,
    this.onTap,
  });

  final CallRecord record;
  final AppStrings strings;
  final VoidCallback? onTap;

  String _duration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final missed = record.missed;
    final color = missed ? palette.coral : palette.accentSoft;
    final label = missed
        ? strings.get('callMissed')
        : record.outgoing
        ? strings.get('callOutgoing')
        : strings.get('callIncoming');
    final detail = record.answered
        ? _duration(record.durationSeconds)
        : missed
        ? ''
        : strings.get('callNoAnswer');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 5),
      child: Center(
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: palette.surface.withValues(alpha: 0.62),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: palette.divider),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  record.video ? Icons.videocam_rounded : Icons.call_rounded,
                  size: 14,
                  color: color,
                ),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(
                    detail,
                    style: TextStyle(
                      color: palette.textMuted,
                      fontSize: 11.5,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
                const SizedBox(width: 7),
                Text(
                  formatClock(record.startedAt),
                  style: TextStyle(color: palette.textMuted, fontSize: 10.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AudioBubble extends StatefulWidget {
  const _AudioBubble({required this.message, required this.mine});
  final Message message;
  final bool mine;

  @override
  State<_AudioBubble> createState() => _AudioBubbleState();
}

class _AudioBubbleState extends State<_AudioBubble> {
  final AudioPlayer _player = AudioPlayer();
  bool _playing = false;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;

  @override
  void initState() {
    super.initState();
    final ms = (widget.message.meta['durationMs'] as num?)?.toInt() ?? 0;
    _dur = Duration(milliseconds: ms);
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _pos = p);
    });
    _player.onDurationChanged.listen((d) {
      if (mounted && d > Duration.zero) setState(() => _dur = d);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _pos = Duration.zero;
        });
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      if (mounted) setState(() => _playing = false);
      return;
    }
    final data = widget.message.meta['data'];
    if (data is! String) return;
    try {
      await _player.play(BytesSource(base64Decode(data)));
      if (mounted) setState(() => _playing = true);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final total = _dur.inMilliseconds;
    final progress = total == 0
        ? 0.0
        : (_pos.inMilliseconds / total).clamp(0.0, 1.0);
    final shown = (_playing || _pos > Duration.zero) ? _pos : _dur;
    return SizedBox(
      width: 220,
      child: Row(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: _toggle,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (widget.mine ? palette.accent : palette.accentSoft)
                    .withValues(alpha: 0.22),
              ),
              child: Icon(
                _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: widget.mine ? palette.outgoingText : palette.accent,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                backgroundColor: palette.divider,
                valueColor: AlwaysStoppedAnimation(palette.accent),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatClock(shown),
            style: TextStyle(
              color: widget.mine ? palette.outgoingText : palette.textMuted,
              fontSize: 11.5,
            ),
          ),
        ],
      ),
    );
  }

  String _formatClock(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}

/// A Telegram-style circular video note. The clip autoplays and loops inside a
/// round mask; while playing a coral ripple emanates from the edge and a thin
/// progress arc traces the ring, giving the note a distinct "living seal" look.
class _VideoNoteBubble extends StatefulWidget {
  const _VideoNoteBubble({
    required this.base64Data,
    required this.mime,
    required this.mine,
  });

  final String base64Data;
  final String mime;
  final bool mine;

  @override
  State<_VideoNoteBubble> createState() => _VideoNoteBubbleState();
}

class _VideoNoteBubbleState extends State<_VideoNoteBubble>
    with TickerProviderStateMixin {
  static const double _size = 118;
  VideoPlayerController? _controller;
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();
  Timer? _repaint;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.base64Data.isEmpty) {
      setState(() {
        _loading = false;
        _failed = true;
      });
      return;
    }
    try {
      final controller = await controllerFromBase64(
        widget.base64Data,
        widget.mime,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      controller.setLooping(true);
      setState(() {
        _controller = controller;
        _loading = false;
      });
      await controller.play();
      _repaint = Timer.periodic(
        const Duration(milliseconds: 120),
        (_) => setState(() {}),
      );
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _repaint?.cancel();
    _ripple.dispose();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final controller = _controller;
    final playing = controller?.value.isPlaying ?? false;

    final progress =
        (controller != null && controller.value.duration > Duration.zero)
        ? (controller.value.position.inMilliseconds /
                  controller.value.duration.inMilliseconds)
              .clamp(0.0, 1.0)
        : 0.0;

    final accent = widget.mine ? palette.accent : palette.accentSoft;

    return SizedBox(
      width: _size + 18,
      height: _size + 18,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Emanating ripple ring (only while playing).
          if (playing)
            AnimatedBuilder(
              animation: _ripple,
              builder: (context, _) {
                final t = _ripple.value;
                return Transform.scale(
                  scale: 1.0 + (t * 0.35),
                  child: Container(
                    width: _size,
                    height: _size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: accent.withValues(alpha: (1.0 - t) * 0.6),
                        width: 2.5,
                      ),
                    ),
                  ),
                );
              },
            ),
          // The circular video itself.
          InkWell(
            onTap: _toggle,
            customBorder: const CircleBorder(),
            child: Container(
              width: _size,
              height: _size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: palette.incomingBubble,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.22),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: _buildContent(context, palette),
            ),
          ),
          // Progress arc tracing the ring.
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _ProgressRingPainter(
                  progress: progress,
                  color: accent,
                  trackColor: Colors.white.withValues(alpha: 0.18),
                ),
              ),
            ),
          ),
          if (!playing && controller != null)
            Icon(
              Icons.play_arrow_rounded,
              color: Colors.white.withValues(alpha: 0.92),
              size: 40,
            ),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context, CoralinkPalette palette) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
    }
    if (_failed || _controller == null) {
      return Icon(
        Icons.videocam_off_rounded,
        color: palette.textMuted,
        size: 34,
      );
    }
    final value = _controller!.value;
    if (!value.isInitialized) return const SizedBox.shrink();
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: value.size.width,
          height: value.size.height,
          child: VideoPlayer(_controller!),
        ),
      ),
    );
  }
}

class _ProgressRingPainter extends CustomPainter {
  const _ProgressRingPainter({
    required this.progress,
    required this.color,
    required this.trackColor,
  });

  final double progress;
  final Color color;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 6;
    final track = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final arc = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, track);
    if (progress > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * progress,
        false,
        arc,
      );
    }
  }

  @override
  bool shouldRepaint(_ProgressRingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.trackColor != trackColor;
}
