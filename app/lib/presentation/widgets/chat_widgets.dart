import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/app_colors.dart';
import '../../core/strings.dart';
import '../../core/utils.dart';
import '../../domain/models.dart';
import 'coral_widgets.dart';

class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.myId,
    required this.strings,
    this.onLongPress,
    this.onRetry,
    this.highlight = false,
  });

  final Message message;
  final String myId;
  final AppStrings strings;
  final VoidCallback? onLongPress;
  final VoidCallback? onRetry;
  final bool highlight;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> with SingleTickerProviderStateMixin {
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

    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: EdgeInsets.fromLTRB(15, message.isImage ? 6 : 11, 15, 9),
      decoration: BoxDecoration(
        color: mine ? palette.outgoingBubble : palette.incomingBubble,
        gradient: mine
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [palette.outgoingBubble, Color.lerp(palette.outgoingBubble, palette.accentSoft, 0.22)!],
              )
            : null,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(mine ? 18 : 5),
          bottomRight: Radius.circular(mine ? 5 : 18),
        ),
        border: widget.highlight
            ? Border.all(color: palette.halo.withValues(alpha: 0.75), width: 1.4)
            : null,
        boxShadow: [
          BoxShadow(
            color: (mine ? palette.accent : Colors.black).withValues(alpha: 0.10),
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
                color: mine ? palette.outgoingText.withValues(alpha: 0.7) : palette.incomingText.withValues(alpha: 0.65),
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
                    child: Icon(Icons.broken_image_outlined, color: palette.incomingText),
                  ),
                ),
              ),
            if (message.isImage) const SizedBox(height: 6),
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
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_showTime)
                Padding(
                  padding: const EdgeInsets.only(right: 7),
                  child: Text(
                    formatClock(message.createdAt),
                    style: TextStyle(
                      fontSize: 10,
                      color: (mine ? palette.outgoingText : palette.incomingText).withValues(alpha: 0.6),
                    ),
                  ),
                ),
              if (mine && !deleted) _StatusDrop(status: message.status),
            ],
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
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: (mine ? palette.outgoingText : palette.incomingText).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                        border: entry.value.contains(widget.myId)
                            ? Border.all(
                                color: (mine ? palette.outgoingText : palette.incomingText).withValues(alpha: 0.5),
                              )
                            : null,
                      ),
                      child: Text(
                        '${entry.key} ${entry.value.length}',
                        style: TextStyle(
                          fontSize: 12,
                          color: mine ? palette.outgoingText : palette.incomingText,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if (message.status == MessageStatus.failed && mine)
            Padding(
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
            ),
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

  Uint8List _bytes(String value) {
    try {
      return base64Decode(value);
    } catch (_) {
      return Uint8List(0);
    }
  }
}

class _StatusDrop extends StatelessWidget {
  const _StatusDrop({required this.status});
  final MessageStatus status;

  @override
  Widget build(BuildContext context) {
    final color = context.palette.outgoingText;
    final opacity = switch (status) {
      MessageStatus.sending => 0.25,
      MessageStatus.sent => 0.45,
      MessageStatus.delivered => 0.7,
      MessageStatus.read => 1.0,
      MessageStatus.failed => 1.0,
    };
    return Icon(
      Icons.water_drop_rounded,
      size: status == MessageStatus.read ? 12 : 10.5,
      color: status == MessageStatus.failed
          ? context.palette.coral
          : color.withValues(alpha: opacity),
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
              style: TextStyle(color: palette.textMuted, fontSize: 11.5, letterSpacing: 0.3),
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
  });

  final Chat chat;
  final AppStrings strings;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback? onArchive;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final unread = chat.unreadCount > 0;
    final online = chat.peerPresence != Presence.offline;
    final statusLabel = switch (chat.peerPresence) {
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
            SeedAvatar(
              seedId: chat.peerId,
              name: chat.peerName,
              colorHex: chat.peerAvatarColor,
              online: online,
              pulse: unread,
              size: 54,
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
                          child: Icon(Icons.push_pin_rounded, size: 13, color: palette.accent),
                        ),
                      Expanded(
                        child: Text(
                          chat.peerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
                            fontSize: 15.5,
                          ),
                        ),
                      ),
                      if (chat.muted)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Icon(Icons.volume_off_rounded, size: 14, color: palette.textMuted),
                        ),
                      const SizedBox(width: 6),
                      Text(
                        chat.lastMessageAt == null
                            ? ''
                            : formatChatStamp(chat.lastMessageAt!, strings),
                        style: TextStyle(
                          color: unread ? palette.accentSoft : palette.textMuted,
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
                          chat.lastMessageText.isEmpty ? statusLabel : chat.lastMessageText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: unread ? palette.textPrimary.withValues(alpha: 0.9) : palette.textMuted,
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
