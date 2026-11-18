import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/config.dart';
import '../core/log.dart';
import 'realtime.dart';

typedef P2PPayloadHandler = Future<void> Function(String peerId, String id, String payload);

class _PeerLink {
  _PeerLink(this.peerId, this.pc);
  final String peerId;
  final RTCPeerConnection pc;
  RTCDataChannel? channel;
  final pendingAcks = <String, Completer<void>>{};
  bool closed = false;
}

/// WebRTC DataChannel transport. Messages are still acknowledged through the
/// signaling server, so a P2P failure falls back to the encrypted relay.
class P2PManager {
  P2PManager(this._config, this._realtime) {
    _subscription = _realtime.events.listen(_onEvent);
    _connectionSubscription = _realtime.statuses.listen((status) {
      if (status == RealtimeStatus.connected) _resumeOpenLinks();
    });
  }

  final AppConfig _config;
  final RealtimeService _realtime;
  final _links = <String, _PeerLink>{};
  late final StreamSubscription<RealtimeEvent> _subscription;
  late final StreamSubscription<RealtimeStatus> _connectionSubscription;
  P2PPayloadHandler? onPayload;
  void Function(String peerId, bool connected)? onLinkChanged;

  static const _label = 'coralink-data';

  // WebRTC DataChannels abort the process under the bundled libwebrtc's forced
  // Unified Plan, so direct P2P links are disabled; the relay handles delivery.
  static final bool _dataChannelSupported = false;

  bool isDirect(String peerId) => _links[peerId]?.channel?.state ==
      RTCDataChannelState.RTCDataChannelOpen;

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
        // DataChannels require Plan-B in the bundled libwebrtc; creating a
        // data channel under Unified Plan trips a native CHECK and aborts the
        // whole process. Media calls (this file's peer connections only carry
        // data channels) therefore pin plan-b.
        'sdpSemantics': 'plan-b',
      };

  Future<void> ensureLink(String peerId) async {
    // P2P direct links rely on WebRTC DataChannels, but the libwebrtc bundled
    // with flutter_webrtc 1.6.3 forces Unified Plan and aborts the process on
    // createDataChannel (native CHECK `!IsUnifiedPlan()`). The WebSocket relay
    // already delivers every message end-to-end, so the direct-link
    // optimization is disabled to keep the app stable. isDirect() stays false
    // and all sends take the relay path.
    if (!_dataChannelSupported) return;
    if (_links.containsKey(peerId)) return;
    if (!_realtime.isConnected) return;
    final initiator = _identityOfSelf.compareTo(peerId) < 0;
    try {
      final pc = await createPeerConnection(_iceServers);
      final link = _PeerLink(peerId, pc);
      _links[peerId] = link;
      pc.onIceCandidate = (candidate) {
        _realtime.sendSignal(peerId, {
          'kind': 'ice',
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      };
      pc.onConnectionState = (state) {
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          onLinkChanged?.call(peerId, false);
        }
      };
      if (initiator) {
        final channel = await pc.createDataChannel(_label, RTCDataChannelInit());
        _wireChannel(link, channel);
        final offer = await pc.createOffer();
        await pc.setLocalDescription(offer);
        _realtime.sendSignal(peerId, {'kind': 'offer', 'sdp': offer.sdp});
      } else {
        pc.onDataChannel = (channel) => _wireChannel(link, channel);
      }
    } catch (error) {
      Log.e('p2p', error);
      await _close(peerId);
    }
  }

  void _wireChannel(_PeerLink link, RTCDataChannel channel) {
    link.channel = channel;
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        onLinkChanged?.call(link.peerId, true);
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        onLinkChanged?.call(link.peerId, false);
      }
    };
    channel.onMessage = (message) {
      if (message.type == MessageType.binary) return;
      _onData(link, message.text);
    };
  }

  Future<void> _onData(_PeerLink link, String raw) async {
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final type = data['type'] as String?;
      if (type == 'msg') {
        final id = data['id'] as String;
        final payload = data['payload'] as String;
        await onPayload?.call(link.peerId, id, payload);
        link.channel?.send(RTCDataChannelMessage(jsonEncode({'type': 'ack', 'id': id})));
      } else if (type == 'ack') {
        final id = data['id'] as String;
        link.pendingAcks.remove(id)?.complete();
      }
    } catch (error) {
      Log.e('p2p.data', error);
    }
  }

  /// Sends through the open DataChannel and waits for a peer ack.
  /// Returns false when there is no direct link or the ack timed out.
  Future<bool> sendAndWaitAck(
    String peerId,
    String id,
    String payload, {
    Duration timeout = const Duration(milliseconds: 1600),
  }) async {
    final link = _links[peerId];
    final channel = link?.channel;
    if (link == null || channel == null || channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      return false;
    }
    final completer = Completer<void>();
    link.pendingAcks[id] = completer;
    try {
      channel.send(RTCDataChannelMessage(jsonEncode({'type': 'msg', 'id': id, 'payload': payload})));
      await completer.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    } finally {
      link.pendingAcks.remove(id);
    }
  }

  String get _identityOfSelf => _selfId;
  String _selfId = '';

  void identify(String userId) {
    _selfId = userId;
  }

  Future<void> _onEvent(RealtimeEvent event) async {
    if (event.type != 'signal') return;
    final from = event.data['from'] as String?;
    final data = (event.data['data'] as Map?)?.cast<String, dynamic>();
    if (from == null || data == null) return;
    final kind = data['kind'] as String?;
    try {
      if (kind == 'offer') {
        await _close(from);
        final pc = await createPeerConnection(_iceServers);
        final link = _PeerLink(from, pc);
        _links[from] = link;
        pc.onIceCandidate = (candidate) {
            _realtime.sendSignal(from, {
            'kind': 'ice',
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          });
        };
        pc.onDataChannel = (channel) => _wireChannel(link, channel);
        await pc.setRemoteDescription(RTCSessionDescription(data['sdp'] as String, 'offer'));
        final answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        _realtime.sendSignal(from, {'kind': 'answer', 'sdp': answer.sdp});
      } else if (kind == 'answer') {
        final link = _links[from];
        await link?.pc.setRemoteDescription(
          RTCSessionDescription(data['sdp'] as String, 'answer'),
        );
      } else if (kind == 'ice') {
        final link = _links[from];
        final candidate = data['candidate'] as String?;
        if (link != null && candidate != null) {
          await link.pc.addCandidate(RTCIceCandidate(
            candidate,
            data['sdpMid'] as String?,
            (data['sdpMLineIndex'] as num?)?.toInt(),
          ));
        }
      }
    } catch (error) {
      Log.e('p2p.signal', error);
    }
  }

  Future<void> _resumeOpenLinks() async {
    for (final peerId in _links.keys.toList()) {
      await _close(peerId);
    }
  }

  Future<void> _close(String peerId) async {
    final link = _links.remove(peerId);
    if (link == null) return;
    link.closed = true;
    for (final pending in link.pendingAcks.values) {
      if (!pending.isCompleted) pending.completeError(StateError('closed'));
    }
    link.pendingAcks.clear();
    try {
      await link.channel?.close();
      await link.pc.close();
    } catch (_) {}
    onLinkChanged?.call(peerId, false);
  }

  Future<void> dispose() async {
    await _subscription.cancel();
    await _connectionSubscription.cancel();
    for (final peerId in _links.keys.toList()) {
      await _close(peerId);
    }
  }
}
