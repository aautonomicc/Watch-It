import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';

import '../models/media_list.dart';

/// Embedded Autonomi client (the native watchit_core Rust library).
///
/// The library runs an ant-core network client plus a localhost HTTP
/// streaming server in-process; playback streams from
/// `http://127.0.0.1:{port}/xor/{address}`. Fully self-contained — no
/// external gateway and nothing for the user to configure.
class EmbeddedClient {
  static int _port = 0;
  static String? _dataDir;

  /// Start the native library, first resolving the app's writable data
  /// directory so ant-core has a `$HOME` to use. Android app processes
  /// have no `$HOME`, and without one every connect attempt dies with a
  /// `HomeDirNotFound` panic inside ant-core. Call once from main()
  /// before anything else touches [baseUrl].
  static Future<void> start() async {
    if (_port > 0) return;
    try {
      _dataDir = (await getApplicationSupportDirectory()).path;
    } catch (_) {
      // path_provider unavailable (tests, bare desktop): the native side
      // falls back to a temp-dir $HOME rather than panicking.
    }
    baseUrl();
  }

  /// Base URL of the in-process streaming server, starting the native
  /// library on first use. Returns null where the library is unavailable
  /// (widget tests, or a desktop build without the .so).
  static String? baseUrl() {
    if (_port > 0) return 'http://127.0.0.1:$_port';
    try {
      final lib = _openLibrary();
      if (lib == null) return null;
      final start = lib.lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Utf8>, Pointer<Utf8>)>('watchit_core_start');
      final dirPtr = _dataDir?.toNativeUtf8() ?? nullptr;
      final port = start(nullptr, dirPtr);
      if (dirPtr != nullptr) malloc.free(dirPtr);
      if (port <= 0) return null;
      _port = port;
      return 'http://127.0.0.1:$_port';
    } catch (_) {
      return null;
    }
  }

  static String? _authToken;

  /// Shared secret guarding the embedded server's wallet/upload routes
  /// (sent as the `x-watchit-auth` header). Those endpoints can spend
  /// money, and the localhost port is visible to every process on the
  /// machine — only the app, which reads the token over FFI, may call
  /// them. Null where the native library is unavailable (widget tests).
  static String? authToken() {
    if (_authToken != null) return _authToken;
    if (baseUrl() == null) return null;
    try {
      final lib = _openLibrary();
      if (lib == null) return null;
      final token = lib.lookupFunction<Pointer<Utf8> Function(),
          Pointer<Utf8> Function()>('watchit_core_auth_token');
      final ptr = token();
      if (ptr == nullptr) return null;
      _authToken = ptr.toDartString();
      return _authToken;
    } catch (_) {
      return null;
    }
  }

  /// Load the native library. A plain name works on Android and Windows
  /// (the loader search path covers the exe dir), and on Linux when the
  /// loader path covers it (e.g. the AppImage's AppRun); desktop builds
  /// also carry the library next to the executable — Linux in the
  /// bundle's lib/ dir, Windows beside the .exe — so fall back to that
  /// explicit path.
  static DynamicLibrary? _openLibrary() {
    final name =
        Platform.isWindows ? 'watchit_core.dll' : 'libwatchit_core.so';
    try {
      return DynamicLibrary.open(name);
    } catch (_) {
      if (!Platform.isLinux && !Platform.isWindows) return null;
    }
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final path = Platform.isWindows
          ? '$exeDir\\watchit_core.dll'
          : '$exeDir/lib/libwatchit_core.so';
      return DynamicLibrary.open(path);
    } catch (_) {
      return null;
    }
  }

  /// Nudge the embedded client's reconnect supervisor: cancels its
  /// current backoff sleep so a connect attempt starts immediately.
  /// Fire-and-forget; harmless while connected (the supervisor just
  /// re-samples its peer count). Used on app resume and OS network
  /// changes so recovery feels instant instead of waiting out backoff.
  static Future<void> reconnectKick() async {
    final base = baseUrl();
    if (base == null) return;
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse('$base/reconnect'));
      final res = await req.close();
      await res.drain<void>();
    } catch (_) {
      // Best-effort: the supervisor reconnects on its own timer anyway.
    } finally {
      client.close(force: true);
    }
  }

  /// Health snapshot from the embedded server.
  static Future<ClientHealth> health() async {
    final base = baseUrl();
    if (base == null) {
      return const ClientHealth(state: 'unavailable');
    }
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('$base/health'));
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      final map = jsonDecode(body) as Map<String, dynamic>;
      return ClientHealth(
        state: map['state'] as String? ?? 'unknown',
        peers: map['peers'] as int? ?? 0,
        attempts: map['attempts'] as int? ?? 0,
        message: map['message'] as String?,
        fetchedBytes: map['fetched_bytes'] as int? ?? 0,
      );
    } catch (e) {
      return ClientHealth(state: 'error', message: '$e');
    } finally {
      client.close();
    }
  }

  /// Network-stack versions compiled into the native library (open
  /// `GET /versions`; the values are baked out of Cargo.lock at build
  /// time, so they can never drift from what actually shipped). Null
  /// when the embedded client is unavailable or the call fails.
  static Future<ClientVersions?> versions({String? baseOverride}) async {
    final base = baseOverride ?? baseUrl();
    if (base == null) return null;
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(
          '${base.replaceFirst(RegExp(r'/+$'), '')}/versions'));
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return null;
      return ClientVersions.fromJson(
          jsonDecode(body) as Map<String, dynamic>);
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Data-usage period counters (auth-guarded `GET /stats` — unlike
  /// `/health` it stays fully populated while the network is paused).
  /// Null when the embedded client is unavailable or the call fails.
  static Future<DataUsageStats?> stats(
          {String? baseOverride, String? tokenOverride}) =>
      _statsCall('GET', '/stats',
          baseOverride: baseOverride, tokenOverride: tokenOverride);

  /// Zero all data-usage counters and start a fresh period
  /// (`POST /stats/reset`); returns the fresh counters.
  static Future<DataUsageStats?> resetStats(
          {String? baseOverride, String? tokenOverride}) =>
      _statsCall('POST', '/stats/reset',
          baseOverride: baseOverride, tokenOverride: tokenOverride);

  static Future<DataUsageStats?> _statsCall(String method, String path,
      {String? baseOverride, String? tokenOverride}) async {
    final base = baseOverride ?? baseUrl();
    if (base == null) return null;
    final token = tokenOverride ?? authToken();
    final client = HttpClient();
    try {
      final uri =
          Uri.parse('${base.replaceFirst(RegExp(r'/+$'), '')}$path');
      final req = method == 'POST'
          ? await client.postUrl(uri)
          : await client.getUrl(uri);
      if (token != null) req.headers.set('x-watchit-auth', token);
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return null;
      return DataUsageStats.fromJson(jsonDecode(body) as Map<String, dynamic>);
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }
}

/// The `GET /versions` body: versions of the network stack compiled
/// into the native library (see watchit_core's build.rs). An old core
/// without the route just yields null from [EmbeddedClient.versions].
class ClientVersions {
  const ClientVersions({
    required this.x0x,
    required this.antCore,
    required this.saorsaCore,
    required this.saorsaGossip,
    required this.antQuic,
  });

  final String x0x;
  final String antCore;
  final String saorsaCore;
  final String saorsaGossip;
  final String antQuic;

  factory ClientVersions.fromJson(Map<String, dynamic> json) =>
      ClientVersions(
        x0x: json['x0x'] as String? ?? '',
        antCore: json['ant_core'] as String? ?? '',
        saorsaCore: json['saorsa_core'] as String? ?? '',
        saorsaGossip: json['saorsa_gossip'] as String? ?? '',
        antQuic: json['ant_quic'] as String? ?? '',
      );
}

/// Up/down byte pair of one `GET /stats` component.
class UsageBytes {
  const UsageBytes({this.rx = 0, this.tx = 0});
  final int rx;
  final int tx;
  int get total => rx + tx;

  factory UsageBytes.fromJson(dynamic json) => json is Map
      ? UsageBytes(rx: json['rx'] as int? ?? 0, tx: json['tx'] as int? ?? 0)
      : const UsageBytes();
}

/// The `GET /stats` body: period data-usage totals per component (see
/// native datausage.rs). All values are bytes since the period start.
class DataUsageStats {
  const DataUsageStats({
    required this.periodStart,
    required this.total,
    required this.ant,
    required this.myWatch,
    required this.channels,
    this.antMediaRx = 0,
    this.antStaleSecs,
  });

  final DateTime periodStart;
  final UsageBytes total;
  final UsageBytes ant;
  final UsageBytes myWatch;
  final UsageBytes channels;

  /// Of the ant bytes: media chunk payload (live counter, no staleness).
  final int antMediaRx;

  /// Age of the Autonomi row's numbers — they come from a 5-minute
  /// summary. Null before the first summary of this app run.
  final int? antStaleSecs;

  factory DataUsageStats.fromJson(Map<String, dynamic> json) =>
      DataUsageStats(
        periodStart: DateTime.fromMillisecondsSinceEpoch(
            json['period_start_ms'] as int? ?? 0),
        total: UsageBytes.fromJson(json['total']),
        ant: UsageBytes.fromJson(json['ant']),
        myWatch: UsageBytes.fromJson(json['mywatch']),
        channels: UsageBytes.fromJson(json['channels']),
        antMediaRx: (json['ant'] as Map?)?['media_rx'] as int? ?? 0,
        antStaleSecs: (json['ant'] as Map?)?['stale_secs'] as int?,
      );
}

class ClientHealth {
  const ClientHealth({
    required this.state,
    this.peers = 0,
    this.attempts = 0,
    this.message,
    this.fetchedBytes = 0,
  });

  /// `connecting`, `ready`, `paused` (user switched all network use
  /// off), `error`, or `unavailable` (no native library).
  final String state;
  final int peers;

  /// Connect attempts started by the embedded client (while `connecting`).
  final int attempts;

  /// While `connecting`: the last attempt's failure, if any. The client
  /// retries forever in the background, so this is detail, not a dead end.
  final String? message;

  /// Network bytes fetched by the embedded client since app start. The
  /// player polls this while buffering to show that data is flowing.
  final int fetchedBytes;

  String get label => switch (state) {
        'ready' =>
          'Connected ($peers ${peers == 1 ? 'peer' : 'peers'})',
        'paused' => 'Paused — no network activity',
        'connecting' => message == null
            ? 'Connecting to the network…'
                '${attempts > 1 ? ' (attempt $attempts)' : ''}'
            : 'Connecting (attempt $attempts) — last error: $message',
        'unavailable' => 'Native client not available on this platform',
        _ => 'Error: ${message ?? 'unknown'}',
      };
}

/// Human-readable size for buffering progress, e.g. `870 KB` / `12.4 MB`.
String byteLabel(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  final mb = bytes / (1024 * 1024);
  return mb >= 100 ? '${mb.round()} MB' : '${mb.toStringAsFixed(1)} MB';
}

/// HTTP URL that streams [entry] from the embedded server at [base], or
/// null when the server is not running.
String? streamUrl(String? base, MediaEntry entry) {
  if (base == null || base.trim().isEmpty) return null;
  final b = base.trim().replaceFirst(RegExp(r'/+$'), '');
  final addr = entry.address.toLowerCase().replaceFirst('0x', '');
  return '$b/xor/$addr';
}
