import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/config.dart';
import '../core/log.dart';
import 'realtime.dart';

enum CallStatus { idle, outgoing, incoming, active, ended }

/// Peer-to-peer audio/video calls. Signaling rides the existing WebSocket;
/// media is WebRTC. On a tailnet peers are directly reachable, so no TURN is
/// required (STUN is used opportunistically).
class CallService {
  CallService(this._config, this._realtime) {
    _subscription = _realtime.events.listen(_onEvent);
  }

  final AppConfig _config;
  final RealtimeService _realtime;
  late final StreamSubscription<RealtimeEvent> _subscription;

  final _changes = StreamController<CallStatus>.broadcast();
  Stream<CallStatus> get changes => _changes.stream;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  CallStatus status = CallStatus.idle;
  String? peerId;
  bool video = false;
  bool muted = false;
  bool cameraOn = true;

  RTCPeerConnection? _pc;
  MediaStream? _local;
  String? _pendingOffer;
  String? _selfId;

  void identify(String userId) => _selfId = userId;

  bool get inCall =>
      status == CallStatus.outgoing ||
      status == CallStatus.incoming ||
      status == CallStatus.active;

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
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _pc = await createPeerConnection(_iceServers);
    _pc!.onIceCandidate = (candidate) {
      _realtime.sendCall(peerId ?? '', {
        'action': 'ice',
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };
    _pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        remoteRenderer.srcObject = event.streams[0];
      }
    };
    _pc!.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _teardown();
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _setStatus(CallStatus.active);
      }
    };
    _local = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': video
          ? {'facingMode': 'user'}
          : false,
    });
    localRenderer.srcObject = _local;
    await _pc!.addStream(_local!);
  }

  void _onEvent(RealtimeEvent event) async {
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
        await _pc?.setRemoteDescription(
          RTCSessionDescription(data['sdp'] as String, 'answer'),
        );
        _setStatus(CallStatus.active);
      case 'ice':
        final candidate = data['candidate'] as String?;
        if (candidate != null) {
          await _pc?.addCandidate(RTCIceCandidate(
            candidate,
            data['sdpMid'] as String?,
            (data['sdpMLineIndex'] as num?)?.toInt(),
          ));
        }
      case 'decline':
      case 'busy':
      case 'hangup':
        await _teardown();
      default:
        break;
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
