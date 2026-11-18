import 'dart:convert';
import 'dart:html' as html;

import 'package:video_player/video_player.dart';

Future<VideoPlayerController> controllerFromBase64(
  String base64Data,
  String mime,
) async {
  final bytes = base64Decode(base64Data);
  final blob = html.Blob([bytes], mime.isEmpty ? 'video/mp4' : mime);
  final url = html.Url.createObjectUrlFromBlob(blob);
  return VideoPlayerController.networkUrl(Uri.parse(url));
}
