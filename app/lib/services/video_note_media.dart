import 'package:video_player/video_player.dart';

import 'video_note_media_io.dart'
    if (dart.library.html) 'video_note_media_web.dart' as impl;

/// Builds a [VideoPlayerController] from in-memory base64 bytes so a circle
/// video note can play straight from the decrypted message payload without a
/// prior save to disk. The byte-to-source bridge differs per platform.
Future<VideoPlayerController> controllerFromBase64(String base64Data, String mime) =>
    impl.controllerFromBase64(base64Data, mime);
