import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../services/app_settings.dart';
import '../services/embedded_client.dart';
import '../theme/tokens.dart';

/// Full-screen video playback of an HTTP stream via media_kit (libmpv).
///
/// Streaming from Autonomi has a slow cold start (every chunk comes off
/// the network the first time), so while mpv is buffering this screen
/// overlays live progress from the embedded client — bytes fetched so
/// far — instead of a bare spinner, and surfaces mpv errors that would
/// otherwise leave the spinner running forever.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.url,
    required this.title,
    this.bufferSizeMb = AppSettings.defaultBufferSizeMb,
  });

  final String url;
  final String title;

  /// mpv demuxer cache cap (Settings → Streaming → Buffer size).
  final int bufferSizeMb;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player;
  late final VideoController _controller;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<String>? _errorSub;
  Timer? _healthTimer;

  bool _buffering = true;
  String? _error;
  int _fetchedBytes = 0;

  @override
  void initState() {
    super.initState();
    _player = Player(
      configuration: PlayerConfiguration(
        bufferSize: widget.bufferSizeMb * 1024 * 1024,
      ),
    );
    _controller = VideoController(_player);
    final platform = _player.platform;
    if (platform is NativePlayer) {
      // Cold chunk fetches can exceed mpv's default 60s network timeout,
      // which kills playback with no visible error. Give the network room.
      platform.setProperty('network-timeout', '300');
    }
    _bufferingSub = _player.stream.buffering.listen((b) {
      if (mounted) setState(() => _buffering = b);
    });
    _errorSub = _player.stream.error.listen((e) {
      if (mounted) setState(() => _error = e);
    });
    _healthTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!_buffering || _error != null) return;
      final health = await EmbeddedClient.health();
      if (mounted) setState(() => _fetchedBytes = health.fetchedBytes);
    });
    _player.open(Media(widget.url));
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    _bufferingSub?.cancel();
    _errorSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Widget _bufferingOverlay(BuildContext context) {
    final t = WiTokens.of(context);
    return Container(
      color: Colors.black54,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: t.copper),
          const SizedBox(height: 16),
          Text(
            'Fetching from the Autonomi network…',
            style: TextStyle(color: t.bone, fontSize: 13),
          ),
          const SizedBox(height: 6),
          Text(
            _fetchedBytes > 0
                ? '${byteLabel(_fetchedBytes)} retrieved'
                : 'waiting for first chunks',
            style: TextStyle(color: t.boneDim, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Text(
            'First start can take a few minutes\nwhile chunks are located.',
            textAlign: TextAlign.center,
            style: TextStyle(color: t.ash, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _errorOverlay(BuildContext context) {
    final t = WiTokens.of(context);
    return Container(
      color: Colors.black87,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, color: t.copper, size: 40),
          const SizedBox(height: 12),
          Text(
            'Playback failed',
            style: TextStyle(
                color: t.bone, fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            _error ?? '',
            textAlign: TextAlign.center,
            style: TextStyle(color: t.boneDim, fontSize: 12),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title, style: const TextStyle(fontSize: 15)),
      ),
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The stock controls draw their own grey buffering spinner in
            // the centre of the video; our branded overlay already covers
            // buffering, so blank out the built-in one on all platforms.
            // The bottom controls default to zero bottom margin, which puts
            // them on top of the Android navigation buttons — lift them
            // clear, and draw the seek bar at twice the stock thickness.
            MaterialVideoControlsTheme(
              normal: kDefaultMaterialVideoControlsThemeData.copyWith(
                bufferingIndicatorBuilder: (_) => const SizedBox.shrink(),
                bottomButtonBarMargin:
                    const EdgeInsets.only(left: 16, right: 8, bottom: 48),
                seekBarMargin:
                    const EdgeInsets.only(left: 16, right: 16, bottom: 48),
                seekBarHeight: 4.8,
              ),
              fullscreen:
                  kDefaultMaterialVideoControlsThemeDataFullscreen.copyWith(
                bufferingIndicatorBuilder: (_) => const SizedBox.shrink(),
                bottomButtonBarMargin:
                    const EdgeInsets.only(left: 16, right: 8, bottom: 64),
                seekBarMargin:
                    const EdgeInsets.only(left: 16, right: 16, bottom: 64),
                seekBarHeight: 4.8,
              ),
              child: MaterialDesktopVideoControlsTheme(
                normal: kDefaultMaterialDesktopVideoControlsThemeData.copyWith(
                  bufferingIndicatorBuilder: (_) => const SizedBox.shrink(),
                ),
                fullscreen:
                    kDefaultMaterialDesktopVideoControlsThemeDataFullscreen
                        .copyWith(
                  bufferingIndicatorBuilder: (_) => const SizedBox.shrink(),
                ),
                child: Video(controller: _controller),
              ),
            ),
            if (_error != null)
              _errorOverlay(context)
            else if (_buffering)
              _bufferingOverlay(context),
          ],
        ),
      ),
    );
  }
}
