import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'publish_api.dart';

/// Watches the embedded core's Trezor attention beacon
/// (`GET /trezor/activity`) while a hardware-wallet flow is in flight,
/// so the UI can pop an explanation — and play a chime — the moment the
/// device is waiting for a human (a confirmation tap, the address
/// screen).
///
/// Polling only runs while at least one flow holds a [during] scope
/// (setup ceremony, a backup/restore, a batch upload): outside those
/// windows nothing can possibly be waiting on the device, and the app
/// does no background work. Poll errors are swallowed — a core without
/// the route (or no core at all, as in widget tests) simply reads as
/// "nothing is waiting".
class TrezorAttentionService extends ChangeNotifier {
  TrezorAttentionService({
    PublishApi? api,
    this.pollInterval = const Duration(milliseconds: 800),
  }) : _apiOverride = api;

  /// Replaceable in tests.
  static TrezorAttentionService instance = TrezorAttentionService();

  final PublishApi? _apiOverride;
  final Duration pollInterval;

  PublishApi get _api => _apiOverride ?? PublishApi();

  /// The action the device is waiting on right now, or null. Actions:
  /// `sign-identity` | `confirm-address` | `sign-payment`.
  TrezorActivity? current;

  int _scopes = 0;
  bool _polling = false;
  Timer? _napTimer;
  Completer<void>? _nap;

  /// True while any hardware-wallet flow is armed (visible for tests).
  bool get armed => _scopes > 0;

  /// Run [body] with the beacon watched: whatever Trezor taps it needs,
  /// listeners hear about them as they happen. Scopes nest — polling
  /// stops when the last one finishes. Cheap for software wallets: the
  /// beacon just stays quiet.
  Future<T> during<T>(Future<T> Function() body) async {
    _scopes += 1;
    _ensurePolling();
    try {
      return await body();
    } finally {
      _scopes -= 1;
      if (_scopes == 0) {
        // Wake the poller so it exits NOW instead of leaving a sleeping
        // timer behind (widget tests fail on pending timers).
        _wake();
        if (current != null) {
          current = null;
          notifyListeners();
        }
      }
    }
  }

  void _ensurePolling() {
    if (_polling) return;
    _polling = true;
    unawaited(_pollLoop());
  }

  void _wake() {
    _napTimer?.cancel();
    _napTimer = null;
    final nap = _nap;
    _nap = null;
    if (nap != null && !nap.isCompleted) nap.complete();
  }

  Future<void> _pollLoop() async {
    try {
      while (_scopes > 0) {
        TrezorActivity? seen;
        try {
          seen = await _api.trezorActivity();
        } catch (_) {
          seen = null; // no core / old core — reads as "nothing waiting"
        }
        if (_scopes == 0) break;
        if (seen != null && seen.active) {
          final held = current;
          if (held == null || held.seq != seen.seq) {
            current = seen;
            notifyListeners();
          }
        } else if (current != null) {
          current = null;
          notifyListeners();
        }
        final nap = Completer<void>();
        _nap = nap;
        _napTimer = Timer(pollInterval, () {
          if (!nap.isCompleted) nap.complete();
        });
        await nap.future;
      }
    } finally {
      _wake();
      _polling = false;
      if (current != null) {
        current = null;
        notifyListeners();
      }
    }
  }
}

/// The short "look at your Trezor" chime played when the device starts
/// waiting for a tap. Desktop-only (hardware wallets are), and fail-soft:
/// a machine with no audio simply stays silent.
class TrezorChime {
  /// Test seam — set to capture plays instead of touching media_kit.
  static Future<void> Function()? playOverride;

  static Future<void> play() async {
    final override = playOverride;
    if (override != null) return override();
    if (kIsWeb ||
        !(Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
      return;
    }
    try {
      // media_kit opens file paths everywhere; stage the bundled asset
      // once. Sync writes — async dart:io hangs the fake-async test zone
      // (house rule), and the bytes are ~33 KB.
      final dir = await getTemporaryDirectory();
      final staged = File('${dir.path}/watchit-trezor-chime.wav');
      if (!staged.existsSync()) {
        final bytes = await rootBundle.load('assets/sounds/trezor-chime.wav');
        staged.writeAsBytesSync(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      }
      final player = Player();
      await player.open(Media(staged.path));
      unawaited(Future<void>.delayed(const Duration(seconds: 3))
          .then((_) => player.dispose()));
    } catch (e) {
      debugPrint('trezor chime failed: $e');
    }
  }
}
