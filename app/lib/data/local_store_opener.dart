import 'local_store.dart';
import 'secure_store.dart';
import 'local_store_factory_web.dart'
    if (dart.library.io) 'local_store_factory_io.dart' as impl;

Future<LocalStore> openLocalStore(SecureStore secure) => impl.openLocalStore(secure);
