import 'local_store.dart';
import 'local_store_memory.dart';

Future<LocalStore> openLocalStore(dynamic secure) async => MemoryLocalStore();
