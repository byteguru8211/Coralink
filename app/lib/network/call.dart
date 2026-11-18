import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/config.dart';
import '../core/log.dart';
import 'realtime.dart';

enum CallStatus { idle, outgoing, incoming, active, ended }

/// Peer-to-peer audio/video calls. Signaling rides the existing WebSocket;
/// media is WebRTC. On a tailnet peers are directly reachable, so no TURN is
/// required (STUN is used opportunistically).
class CallService {
  CallService(this._config, this._realtime) {
    _subscription = _realtime.events.listen(
      _onEvent,
      onError: (Object error) => Log.e('call.stream', error),
    );
  }

  final AppConfig _config;
  final RealtimeService _realtime;
  late final StreamSubscription<RealtimeEvent> _subscription;

  final _changes = StreamController<CallStatus>.broadcast();
  Stream<CallStatus> get changes => _changes.stream;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool _renderersReady = false;

  CallStatus status = CallStatus.idle;
  String? peerId;
  bool video = false;
  bool muted = false;
  bool cameraOn = true;

  RTCPeerConnection? _pc;
  MediaStream? _local;
  String? _pendingOffer;
  String? _selfId;

  // ICE candidates can arrive before the remote description (e.g. the caller's
  // trickle reaches the callee while it is still ringing and has no peer
  // connection). Buffer them and flush once a remote description is set,
  // otherwise the negotiation stalls and the call never connects.
  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _pendingCandidates = <RTCIceCandidate>[];

  void _markRemoteSet() {
    _remoteDescriptionSet = true;
    final pc = _pc;
    if (pc == null) return;
    final queued = List<RTCIceCandidate>.from(_pendingCandidates);
    _pendingCandidates.clear();
    for (final candidate in queued) {
      unawaited(pc.addCandidate(candidate));
    }
  }

  void identify(String userId) => _selfId = userId;

  bool get inCall =>
      status == CallStatus.outgoing ||
      status == CallStatus.incoming ||
      status == CallStatus.active;

  bool get renderersReady => _renderersReady;

  Map<String, dynamic> get _iceServers => {
        'iceServers': [
          {'urls': _config.stunUrl},
          if (_config.turnUrl != null)
            {
              'urls': _config.turnUrl,
              'username': _config.turnUsername,
              'credential': _config.turnCredential,
            },
        ],
        'sdpSemantics': 'unified-plan',
      };

  Future<void> start(String remotePeerId, {bool withVideo = false}) async {
    if (inCall || !_realtime.isConnected) return;
    peerId = remotePeerId;
    video = withVideo;
    cameraOn = withVideo;
    _setStatus(CallStatus.outgoing);
    try {
      await _setupMedia();
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      _realtime.sendCall(remotePeerId, {
        'action': 'call',
        'mode': withVideo ? 'video' : 'audio',
        'sdp': offer.sdp,
      });
    } catch (error) {
      Log.e('call.start', error);
      await _teardown();
    }
  }

  Future<void> accept() async {
    if (status != CallStatus.incoming || _pendingOffer == null) return;
    _setStatus(CallStatus.active);
    try {
      await _setupMedia();
      await _pc!
          .setRemoteDescription(RTCSessionDescription(_pendingOffer, 'offer'));
      _markRemoteSet();
      _pendingOffer = null;
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      _realtime.sendCall(peerId!, {'action': 'answer', 'sdp': answer.sdp});
    } catch (error) {
      Log.e('call.accept', error);
      await _teardown(notifyPeer: true);
    }
  }

  Future<void> decline() async {
    if (status != CallStatus.incoming) return;
    _realtime.sendCall(peerId ?? '', {'action': 'decline'});
    await _teardown();
  }

  Future<void> hangup() async {
    if (!inCall) return;
    if (peerId != null) _realtime.sendCall(peerId!, {'action': 'hangup'});
    await _teardown();
  }

  Future<void> toggleMute() async {
    muted = !muted;
    for (final track in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
  }

  Future<void> toggleCamera() async {
    cameraOn = !cameraOn;
    for (final track in _local?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = cameraOn;
    }
  }

  Future<void> _setupMedia() async {
    if (!_renderersReady) {
      await localRenderer.initialize();
      await remoteRenderer.initialize();
      _renderersReady = true;
    }
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
    _pc = await createPeerConnection(_iceServers);
    _pc!.onIceCandidate = (candidate) {
      try {
        _realtime.sendCall(peerId ?? '', {
          'action': 'ice',
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      } catch (error) {
        Log.e('call.ice', error);
      }
    };
    _pc!.onTrack = (event) {
      try {
        if (event.streams.isNotEmpty) {
          remoteRenderer.srcObject = event.streams[0];
        }
      } catch (error) {
        Log.e('call.track', error);
      }
    };
    _pc!.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        // A remote hangup closes the peer connection; 'disconnected' is the
        // first state observed, so tearing down here ends the call promptly
        // even if the explicit hangup signal is missed.
        unawaited(_teardown());
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _setStatus(CallStatus.active);
      }
    };
    // Ask the OS for capture permission before getUserMedia. On Android this
    // triggers the runtime prompt; on desktop/unsupported platforms the call
    // is best-effort and never blocks the negotiation.
    try {
      final toRequest = <Permission>[
        Permission.microphone,
        if (video) Permission.camera,
      ];
      await toRequest.request();
    } catch (error) {
      Log.e('call.permission', error);
    }
    _local = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': video
          ? {'facingMode': 'user'}
          : false,
    });
    localRenderer.srcObject = _local;
    // Add tracks individually (Unified Plan). The legacy addStream path can
    // hit a native WebRTC CHECK on the signaling thread and abort the process.
    final stream = _local!;
    for (final track in stream.getAudioTracks()) {
      await _pc!.addTrack(track, stream);
    }
    for (final track in stream.getVideoTracks()) {
      await _pc!.addTrack(track, stream);
    }
  }

  void _onEvent(RealtimeEvent event) {
    // Never let a signaling/media error escape: an uncaught async error in a
    // stream callback crashes the whole app on Windows and Android.
    unawaited(_handleCallEvent(event));
  }

  Future<void> _handleCallEvent(RealtimeEvent event) async {
    try {
      if (event.type != 'call') return;
      final from = event.data['from'] as String?;
      final data = (event.data['data'] as Map?)?.cast<String, dynamic>();
      if (from == null || data == null || from == _selfId) return;
      final action = data['action'] as String?;

      switch (action) {
        case 'call':
          if (inCall) {
            _realtime.sendCall(from, {'action': 'busy'});
            return;
          }
          peerId = from;
          video = data['mode'] == 'video';
          cameraOn = video;
          _pendingOffer = data['sdp'] as String?;
          _setStatus(CallStatus.incoming);
        case 'answer':
          final sdp = data['sdp'];
          if (_pc != null && sdp is String) {
            await _pc!
                .setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
            _markRemoteSet();
            _setStatus(CallStatus.active);
          }
        case 'ice':
          final candidate = data['candidate'];
          if (candidate is String) {
            final ice = RTCIceCandidate(
              candidate,
              data['sdpMid'] as String?,
              (data['sdpMLineIndex'] as num?)?.toInt(),
            );
            if (_pc != null && _remoteDescriptionSet) {
              await _pc!.addCandidate(ice);
            } else {
              _pendingCandidates.add(ice);
            }
          }
        case 'decline':
        case 'busy':
        case 'hangup':
          await _teardown();
        default:
          break;
      }
    } catch (error, stack) {
      Log.e('call.event', error, stack);
      await _teardown();
    }
  }

  void _setStatus(CallStatus value) {
    status = value;
    if (!_changes.isClosed) _changes.add(value);
  }

  Future<void> _teardown({bool notifyPeer = false}) async {
    if (notifyPeer && peerId != null) {
      _realtime.sendCall(peerId!, {'action': 'hangup'});
    }
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    try {
      _local?.dispose();
    } catch (_) {}
    _local = null;
    _pendingOffer = null;
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
    final wasActive = inCall;
    peerId = null;
    video = false;
    muted = false;
    cameraOn = true;
    if (wasActive) _setStatus(CallStatus.ended);
    _setStatus(CallStatus.idle);
  }

  Future<void> dispose() async {
    await _teardown();
    await _subscription.cancel();
    try {
      localRenderer.dispose();
      remoteRenderer.dispose();
    } catch (_) {}
    await _changes.close();
  }
}
