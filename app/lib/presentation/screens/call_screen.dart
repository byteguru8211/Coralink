import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../app/dependencies.dart';
import '../../app/session.dart';
import '../../core/app_colors.dart';
import '../../network/call.dart';
import '../controllers.dart';
import '../widgets/coral_widgets.dart';

class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({super.key, required this.peerId, this.initialVideo = false});
  final String peerId;
  final bool initialVideo;

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  late final CallService _call;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _call = ref.read(callProvider);
  }

  Future<void> _hangup() async {
    await _call.hangup();
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _decline() async {
    await _call.decline();
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _accept() async {
    await _call.accept();
  }

  String _peerName() {
    final chats = ref.read(chatsProvider);
    for (final chat in [...chats.chats, ...chats.archived]) {
      if (chat.id == widget.peerId) return chat.peerName;
    }
    return 'Coralink';
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(stringsProvider);
    final palette = context.palette;
    final status = ref.watch(callStatusProvider).value ?? _call.status;

    if ((status == CallStatus.idle || status == CallStatus.ended) && !_closing) {
      _closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
    }

    final isVideo = _call.video;
    final connected = status == CallStatus.active;
    final name = _peerName();

    return Scaffold(
      backgroundColor: const Color(0xFF0B1512),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (isVideo && connected)
            RTCVideoView(_call.remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
          else
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SeedAvatar(
                    seedId: widget.peerId,
                    name: name,
                    size: 132,
                    online: connected,
                    pulse: !connected,
                  ),
                  const SizedBox(height: 22),
                  Text(name,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w300)),
                  const SizedBox(height: 10),
                  Text(
                    switch (status) {
                      CallStatus.outgoing => strings.get('calling'),
                      CallStatus.incoming => strings.get('incomingCall'),
                      CallStatus.active => strings.get('inCall'),
                      _ => '',
                    },
                    style: TextStyle(
                        color: isVideo ? Colors.white : palette.textMuted,
                        fontSize: 15),
                  ),
                ],
              ),
            ),
          if (isVideo && connected)
            Positioned(
              right: 16,
              top: 40,
              child: SizedBox(
                width: 120,
                height: 168,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: RTCVideoView(_call.localRenderer,
                      mirror: true,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 40,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (status == CallStatus.incoming) ...[
                  _CircleButton(
                    color: const Color(0xFF2FB894),
                    icon: Icons.call_rounded,
                    onTap: _accept,
                  ),
                  const SizedBox(width: 28),
                  _CircleButton(
                    color: const Color(0xFFE2564B),
                    icon: Icons.call_end_rounded,
                    onTap: _decline,
                  ),
                ] else ...[
                  _CircleButton(
                    color: Colors.white24,
                    icon: _call.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                    onTap: () async {
                      await _call.toggleMute();
                      if (mounted) setState(() {});
                    },
                  ),
                  const SizedBox(width: 20),
                  if (isVideo)
                    _CircleButton(
                      color: Colors.white24,
                      icon: _call.cameraOn
                          ? Icons.videocam_rounded
                          : Icons.videocam_off_rounded,
                      onTap: () async {
                        await _call.toggleCamera();
                        if (mounted) setState(() {});
                      },
                    ),
                  if (isVideo) const SizedBox(width: 20),
                  _CircleButton(
                    color: const Color(0xFFE2564B),
                    icon: Icons.call_end_rounded,
                    onTap: _hangup,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.color,
    required this.icon,
    required this.onTap,
  });
  final Color color;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        child: Icon(icon, color: Colors.white, size: 26),
      ),
    );
  }
}
