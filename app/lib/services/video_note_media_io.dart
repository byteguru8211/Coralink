import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

Future<VideoPlayerController> controllerFromBase64(
  String base64Data,
  String mime,
) async {
  final dir = await getTemporaryDirectory();
  final ext = mime.contains('webm')
      ? 'webm'
      : mime.contains('quicktime')
          ? 'mov'
          : 'mp4';
  final file = File(
    p.join(dir.path, 'note_${DateTime.now().microsecondsSinceEpoch}.$ext'),
  );
  await file.writeAsBytes(base64Decode(base64Data), flush: true);
  return VideoPlayerController.file(file);
}
