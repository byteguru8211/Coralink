import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../app/dependencies.dart';
import '../../app/session.dart';
import '../../core/app_colors.dart';
import '../../core/strings.dart';
import '../../domain/models.dart';
import '../../network/call.dart';
import '../controllers.dart';
import '../widgets/coral_widgets.dart';

/// The full call surface: video with a picture-in-picture self view, or a calm
/// audio view with breathing coral rings, a live timer and the usual call
/// controls (mute, speaker, camera, flip, hang up).
class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({super.key, required this.peerId, this.initialVideo = false});
  final String peerId;
  final bool initialVideo;

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  late final CallService _call;
  Timer? _ticker;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _call = ref.read(callProvider);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
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
    if (mounted) setState(() {});
  }

  /// Resolves the caller's display name even when no chat exists yet (for
  /// example a caller who is only in the contact list, or a brand-new number).
  String _peerName(List<Contact> contacts) {
    final chats = ref.read(chatsProvider);
    for (final chat in [...chats.chats, ...chats.archived]) {
      if (chat.id == widget.peerId && chat.peerName.isNotEmpty) {
        return chat.peerName;
      }
    }
    for (final contact in contacts) {
      if (contact.user.id == widget.peerId && contact.user.name.isNotEmpty) {
        return contact.user.name;
      }
    }
    return 'Coralink';
  }

  String _duration(int seconds) =>
      '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(stringsProvider);
    final status = ref.watch(callStatusProvider).value ?? _call.status;

    if ((status == CallStatus.idle || status == CallStatus.ended) && !_closing) {
      _closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
    }

    final isVideo = _call.video && _call.renderersReady;
    final connected = status == CallStatus.active;
    final name = _peerName(ref.watch(contactsProvider).contacts);
    final showRemoteVideo = isVideo && connected && _call.video;

    final label = switch (status) {
      CallStatus.outgoing => strings.get('calling'),
      CallStatus.incoming => strings.get('incomingCall'),
      CallStatus.active => _duration(_call.elapsedSeconds),
      _ => '',
    };

    return Scaffold(
      backgroundColor: const Color(0xFF08120F),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Backdrop: remote video, or a deep emerald gradient with rings.
          if (showRemoteVideo)
            RTCVideoView(
              _call.remoteRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            )
          else
            _AudioBackdrop(
              peerId: widget.peerId,
              name: name,
              status: status,
              connected: connected,
            ),
          if (showRemoteVideo)
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.center,
                  colors: [Color(0x99000000), Color(0x00000000)],
                ),
              ),
            ),
          // Header: who you are talking to, and how long.
          Positioned(
            left: 20,
            right: 20,
            top: MediaQuery.paddingOf(context).top + 14,
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
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    _ModeBadge(
                      video: _call.video,
                      live: connected,
                      label: _call.video
                          ? strings.get('videoCall')
                          : strings.get('audioCall'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.75),
                    fontSize: 14,
                    letterSpacing: 0.4,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          // Draggable-looking self preview (top-right, below the header).
          if (showRemoteVideo)
            Positioned(
              right: 16,
              top: MediaQuery.paddingOf(context).top + 74,
              child: _SelfPreview(
                renderer: _call.localRenderer,
                visible: _call.cameraOn,
              ),
            ),
          // Controls.
          Positioned(
            left: 0,
            right: 0,
            bottom: 28 + MediaQuery.paddingOf(context).bottom,
            child: status == CallStatus.incoming
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _CallButton(
                        icon: Icons.call_end_rounded,
                        label: strings.get('decline'),
                        color: const Color(0xFFE2564B),
                        onTap: _decline,
                      ),
                      const SizedBox(width: 46),
                      _CallButton(
                        icon: Icons.call_rounded,
                        label: strings.get('accept'),
                        color: const Color(0xFF2FB894),
                        onTap: _accept,
                      ),
                    ],
                  )
                : _ControlBar(
                    strings: strings,
                    muted: _call.muted,
                    speaker: _call.speakerOn,
                    cameraOn: _call.cameraOn,
                    video: _call.video,
                    connected: connected,
                    onMute: () async {
                      await _call.toggleMute();
                      if (mounted) setState(() {});
                    },
                    onSpeaker: () async {
                      await _call.toggleSpeaker();
                      if (mounted) setState(() {});
                    },
                    onCamera: () async {
                      await _call.toggleCamera();
                      if (mounted) setState(() {});
                    },
                    onFlip: () async {
                      await _call.switchCamera();
                      if (mounted) setState(() {});
                    },
                    onHangup: _hangup,
                  ),
          ),
        ],
      ),
    );
  }
}

class _AudioBackdrop extends StatefulWidget {
  const _AudioBackdrop({
    required this.peerId,
    required this.name,
    required this.status,
    required this.connected,
  });

  final String peerId;
  final String name;
  final CallStatus status;
  final bool connected;

  @override
  State<_AudioBackdrop> createState() => _AudioBackdropState();
}

class _AudioBackdropState extends State<_AudioBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.25),
          radius: 1.1,
          colors: [Color(0xFF123A2C), Color(0xFF08120F)],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 260,
              height: 260,
              child: AnimatedBuilder(
                animation: _breath,
                builder: (context, child) {
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      for (var ring = 0; ring < 3; ring++)
                        _breathRing(
                          progress: (_breath.value + ring / 3) % 1,
                          color: palette.halo,
                        ),
                      child!,
                    ],
                  );
                },
                child: SeedAvatar(
                  seedId: widget.peerId,
                  name: widget.name,
                  size: 128,
                  online: widget.status == CallStatus.active,
                  pulse: widget.status != CallStatus.active,
                ),
              ),
            ),
            const SizedBox(height: 120),
          ],
        ),
      ),
    );
  }

  Widget _breathRing({required double progress, required Color color}) {
    final size = 150 + 110 * progress;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: color.withValues(alpha: 0.30 * (1 - progress)),
          width: 1.6,
        ),
      ),
    );
  }
}

class _SelfPreview extends StatelessWidget {
  const _SelfPreview({required this.renderer, required this.visible});

  final RTCVideoRenderer renderer;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 112,
      height: 156,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: visible
          ? RTCVideoView(
              renderer,
              mirror: true,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            )
          : ColoredBox(
              color: const Color(0xFF16302A),
              child: Icon(
                Icons.videocam_off_rounded,
                color: Colors.white.withValues(alpha: 0.45),
              ),
            ),
    );
  }
}

class _ModeBadge extends StatelessWidget {
  const _ModeBadge({
    required this.video,
    required this.live,
    required this.label,
  });

  final bool video;
  final bool live;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            video ? Icons.videocam_rounded : Icons.call_rounded,
            size: 13,
            color: Colors.white.withValues(alpha: live ? 0.95 : 0.6),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.strings,
    required this.muted,
    required this.speaker,
    required this.cameraOn,
    required this.video,
    required this.connected,
    required this.onMute,
    required this.onSpeaker,
    required this.onCamera,
    required this.onFlip,
    required this.onHangup,
  });

  final AppStrings strings;
  final bool muted;
  final bool speaker;
  final bool cameraOn;
  final bool video;
  final bool connected;
  final VoidCallback onMute;
  final VoidCallback onSpeaker;
  final VoidCallback onCamera;
  final VoidCallback onFlip;
  final VoidCallback onHangup;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CallButton(
            icon: muted ? Icons.mic_off_rounded : Icons.mic_rounded,
            label: strings.get('mute'),
            active: muted,
            onTap: onMute,
          ),
          _CallButton(
            icon: speaker ? Icons.volume_up_rounded : Icons.volume_down_rounded,
            label: strings.get('speaker'),
            active: speaker,
            onTap: onSpeaker,
          ),
          if (video)
            _CallButton(
              icon: cameraOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
              label: strings.get('cameraOnOff'),
              active: !cameraOn,
              onTap: onCamera,
            ),
          if (video && connected)
            _CallButton(
              icon: Icons.cameraswitch_rounded,
              label: strings.get('flipCamera'),
              onTap: onFlip,
            ),
          _CallButton(
            icon: Icons.call_end_rounded,
            label: strings.get('hangup'),
            color: const Color(0xFFE2564B),
            onTap: onHangup,
          ),
        ],
        ),
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  const _CallButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final background = color ??
        (active ? Colors.white.withValues(alpha: 0.85) : Colors.white.withValues(alpha: 0.12));
    final foreground = color != null
        ? Colors.white
        : active
            ? const Color(0xFF0B1512)
            : Colors.white;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(shape: BoxShape.circle, color: background),
          child: Icon(icon, color: foreground, size: 24),
        ),
      ),
    );
  }
}
