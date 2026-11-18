import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/log.dart';

enum RealtimeStatus { idle, connecting, connected, reconnecting, stopped }

class RealtimeEvent {
  const RealtimeEvent(this.type, this.data);
  final String type;
  final Map<String, dynamic> data;

  String? get stringId => data['id'] as String?;
  List<String> get ids =>
      (data['ids'] as List?)?.map((e) => e as String).toList() ?? const [];
}

class RealtimeService {
  RealtimeService(this._url, this._token);

  final String _url;
  final String _token;

  final _events = StreamController<RealtimeEvent>.broadcast();
  final _status = StreamController<RealtimeStatus>.broadcast();
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _reconnectTimer;
  Timer? _heartbeat;
  bool _closed = false;
  int _attempt = 0;
  RealtimeStatus _current = RealtimeStatus.idle;

  Stream<RealtimeEvent> get events => _events.stream;
  Stream<RealtimeStatus> get statuses => _status.stream;
  RealtimeStatus get status => _current;
  bool get isConnected => _current == RealtimeStatus.connected;

  void _setStatus(RealtimeStatus value) {
    if (_current == value) return;
    _current = value;
    if (!_status.isClosed) _status.add(value);
  }

  Future<void> connect() async {
    if (_closed) return;
    _reconnectTimer?.cancel();
    _setStatus(_attempt == 0 ? RealtimeStatus.connecting : RealtimeStatus.reconnecting);
    try {
      final uri = Uri.parse(_url).replace(queryParameters: {'token': _token});
      final channel = WebSocketChannel.connect(uri);
      await channel.ready.timeout(const Duration(seconds: 12));
      _channel = channel;
      _attempt = 0;
      _setStatus(RealtimeStatus.connected);
      _subscription = channel.stream.listen(
        _onRaw,
        onError: (Object error) {
          Log.e('ws', error);
          _scheduleReconnect();
        },
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(const Duration(seconds: 25), (_) => sendRaw({'type': 'ping'}));
    } catch (error) {
      Log.e('ws', error);
      _scheduleReconnect();
    }
  }

  void _onRaw(dynamic raw) {
    if (raw is! String) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final type = decoded['type'] as String? ?? 'unknown';
      if (type == 'pong' || type == 'ping') return;
      if (!_events.isClosed) _events.add(RealtimeEvent(type, decoded));
    } catch (error) {
      Log.e('ws.parse', error);
    }
  }

  void _scheduleReconnect() {
    if (_closed) return;
    _heartbeat?.cancel();
    _subscription?.cancel();
    _channel = null;
    _setStatus(RealtimeStatus.reconnecting);
    _attempt++;
    final delay = Duration(seconds: min(30, pow(2, min(_attempt, 5)).toInt()));
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, connect);
  }

  void sendRaw(Map<String, dynamic> payload) {
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.sink.add(jsonEncode(payload));
    } catch (error) {
      Log.e('ws.send', error);
      _scheduleReconnect();
    }
  }

  void sendMessage({
    required String id,
    required String to,
    required String ciphertext,
    required String kind,
    required Map<String, dynamic> meta,
    required DateTime createdAt,
  }) =>
      sendRaw({
        'type': 'message',
        'id': id,
        'to': to,
        'ciphertext': ciphertext,
        'kind': kind,
        'meta': meta,
        'createdAt': createdAt.millisecondsSinceEpoch,
      });

  void ackMessages(List<String> ids) {
    if (ids.isEmpty) return;
    sendRaw({'type': 'message.ack', 'ids': ids});
  }

  void markRead(String chatWith, List<String> ids) {
    if (ids.isEmpty) return;
    sendRaw({'type': 'message.read', 'chatWith': chatWith, 'ids': ids});
  }

  void sendSignal(String to, Map<String, dynamic> data) =>
      sendRaw({'type': 'signal', 'to': to, 'data': data});

  void sendGroupMessage({
    required String id,
    required String groupId,
    required String ciphertext,
    required String kind,
    required Map<String, dynamic> meta,
    required DateTime createdAt,
  }) =>
      sendRaw({
        'type': 'group.send',
        'id': id,
        'groupId': groupId,
        'ciphertext': ciphertext,
        'kind': kind,
        'meta': meta,
        'createdAt': createdAt.millisecondsSinceEpoch,
      });

  void markGroupRead(String groupId, List<String> ids) {
    if (ids.isEmpty) return;
    sendRaw({'type': 'group.read', 'groupId': groupId, 'ids': ids});
  }

  void typing(String to, bool on) =>
      sendRaw({'type': 'typing', 'to': to, 'on': on});

  void setPresence(String status) => sendRaw({'type': 'presence', 'status': status});

  bool _disposed = false;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _closed = true;
    _reconnectTimer?.cancel();
    _heartbeat?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _setStatus(RealtimeStatus.stopped);
    await _events.close();
    await _status.close();
  }
}
