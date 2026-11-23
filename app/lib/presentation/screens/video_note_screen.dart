import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_colors.dart';
import '../../core/strings.dart';

class VideoNoteCapture {
  const VideoNoteCapture({
    required this.bytes,
    required this.mime,
    required this.durationMs,
  });

  final Uint8List bytes;
  final String mime;
  final int durationMs;
}

/// In-app circular video note recorder. Unlike the system camera intent this
/// is a proper Telegram-style surface: the clip is framed in a circle, a tap
/// or a long press records, a ring shows the elapsed time, and there is no
/// built-in duration limit — only the relay's attachment size cap applies.
class VideoNoteRecorderScreen extends StatefulWidget {
  const VideoNoteRecorderScreen({super.key, required this.strings});

  final AppStrings strings;

  @override
  State<VideoNoteRecorderScreen> createState() =>
      _VideoNoteRecorderScreenState();
}

class _VideoNoteRecorderScreenState extends State<VideoNoteRecorderScreen>
    with WidgetsBindingObserver {
  static const int _maxBytes = 6 * 1024 * 1024;

  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  int _cameraIndex = 0;
  bool _initializing = true;
  bool _recording = false;
  bool _busy = false;
  bool _torch = false;
  String? _error;
  int _seconds = 0;
  Timer? _timer;
  DateTime? _startedAt;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _cancel();
    }
  }

  Future<void> _boot() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() {
          _initializing = false;
          _error = widget.strings.get('videoNoteNoCamera');
        });
        return;
      }
      final front = _cameras.indexWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
      );
      _cameraIndex = front >= 0 ? front : 0;
      await _open(_cameras[_cameraIndex]);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = '${widget.strings.get('videoNoteCameraError')}\n$error';
      });
    }
  }

  Future<void> _open(CameraDescription description) async {
    await _controller?.dispose();
    final controller = CameraController(
      description,
      ResolutionPreset.medium,
      enableAudio: true,
    );
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _initializing = false;
        _error = null;
        _torch = false;
      });
    } on CameraException catch (error) {
      await controller.dispose();
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = error.description ?? widget.strings.get('videoNoteCameraError');
      });
    }
  }

  Future<void> _flip() async {
    if (_recording || _cameras.length < 2) return;
    final next = (_cameraIndex + 1) % _cameras.length;
    setState(() {
      _cameraIndex = next;
      _initializing = true;
    });
    await _open(_cameras[next]);
  }

  Future<void> _toggleTorch() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.setFlashMode(
        _torch ? FlashMode.off : FlashMode.torch,
      );
      setState(() => _torch = !_torch);
    } catch (_) {
      // Some devices expose no torch on the selected lens.
    }
  }

  Future<void> _start() async {
    final controller = _controller;
    if (controller == null || _recording || _busy || _finishing) return;
    try {
      await controller.startVideoRecording();
      if (!mounted) return;
      setState(() {
        _recording = true;
        _seconds = 0;
        _startedAt = DateTime.now();
      });
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _seconds++);
      });
    } on CameraException catch (error) {
      setState(
        () => _error = error.description ?? widget.strings.get('videoNoteCameraError'),
      );
    }
  }

  Future<void> _stop() async {
    if (!_recording || _finishing) return;
    _finishing = true;
    _timer?.cancel();
    final controller = _controller;
    final started = _startedAt ?? DateTime.now();
    setState(() {
      _recording = false;
      _busy = true;
    });
    try {
      final file = await controller?.stopVideoRecording();
      if (file == null) throw StateError('no recording');
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      if (bytes.lengthInBytes > _maxBytes) {
        setState(() {
          _busy = false;
          _error = widget.strings.get('videoNoteTooLarge');
        });
        return;
      }
      if (bytes.isEmpty) throw StateError('empty recording');
      final duration = DateTime.now().difference(started).inMilliseconds;
      final mime = file.path.endsWith('.webm') ? 'video/webm' : 'video/mp4';
      Navigator.of(context).pop(
        VideoNoteCapture(bytes: bytes, mime: mime, durationMs: duration),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '${widget.strings.get('videoNoteCameraError')}\n$error';
      });
    } finally {
      _finishing = false;
    }
  }

  void _cancel() {
    if (_recording) {
      _timer?.cancel();
      final controller = _controller;
      setState(() {
        _recording = false;
        _busy = false;
      });
      unawaited(
        controller?.stopVideoRecording().then((_) {}, onError: (_) {}),
      );
      return;
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final strings = widget.strings;
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: _initializing || controller == null || !controller.value.isInitialized
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    )
                  : Center(
                      child: _roundPreview(controller),
                    ),
            ),
            Positioned(
              top: 6,
              left: 4,
              child: IconButton(
                onPressed: _busy ? null : _cancel,
                icon: const Icon(Icons.close_rounded, color: Colors.white),
              ),
            ),
            Positioned(
              top: 6,
              right: 4,
              child: Row(
                children: [
                  IconButton(
                    onPressed: _recording ? null : _toggleTorch,
                    icon: Icon(
                      _torch
                          ? Icons.flash_on_rounded
                          : Icons.flash_off_rounded,
                      color: Colors.white,
                    ),
                  ),
                  IconButton(
                    onPressed: _recording ? null : _flip,
                    icon: const Icon(
                      Icons.cameraswitch_rounded,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 24,
              right: 24,
              bottom: 26,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: palette.coral.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: palette.coral.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  Text(
                    _recording
                        ? '${_seconds ~/ 60}:${(_seconds % 60).toString().padLeft(2, '0')}'
                        : strings.get('videoNoteHint'),
                    style: TextStyle(
                      color: _recording
                          ? palette.coral
                          : Colors.white.withValues(alpha: 0.8),
                      fontSize: _recording ? 20 : 13,
                      fontWeight:
                          _recording ? FontWeight.w600 : FontWeight.w400,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: _busy ? null : (_recording ? _stop : _start),
                    onLongPressStart: _busy ? null : (_) => _start(),
                    onLongPressEnd: _busy ? null : (_) => _stop(),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 82,
                      height: 82,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 4),
                        color: _recording
                            ? palette.coral
                            : Colors.white.withValues(alpha: 0.25),
                        boxShadow: [
                          BoxShadow(
                            color: (_recording ? palette.coral : Colors.white)
                                .withValues(alpha: 0.35),
                            blurRadius: 22,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: Icon(
                        _recording
                            ? Icons.stop_rounded
                            : Icons.videocam_rounded,
                        color: Colors.white,
                        size: 34,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    strings.get('videoNoteNoLimit'),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 10.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roundPreview(CameraController controller) {
    final size = MediaQuery.sizeOf(context);
    final side = (size.width * 0.78).clamp(220.0, 360.0);
    final palette = context.palette;
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: side,
          height: side,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: 0.9), width: 3),
            boxShadow: [
              BoxShadow(
                color: palette.accent.withValues(alpha: 0.25),
                blurRadius: 40,
                spreadRadius: 8,
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: controller.value.previewSize?.height ?? side,
              height: controller.value.previewSize?.width ?? side,
              child: CameraPreview(controller),
            ),
          ),
        ),
        if (_recording)
          SizedBox(
            width: side + 16,
            height: side + 16,
            child: CircularProgressIndicator(
              value: (_seconds % 60) / 60,
              strokeWidth: 3,
              color: palette.coral,
              backgroundColor: Colors.white.withValues(alpha: 0.18),
            ),
          ),
      ],
    );
  }
}
