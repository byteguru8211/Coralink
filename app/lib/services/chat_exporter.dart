import '../data/local_store.dart';
import 'chat_exporter_stub.dart' if (dart.library.io) 'chat_exporter_io.dart' as impl;

Future<String?> exportChats(LocalStore store, String myId) => impl.exportChatsImpl(store, myId);
