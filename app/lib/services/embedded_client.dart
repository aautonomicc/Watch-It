import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import '../models/media_list.dart';

/// Embedded Autonomi client (the native watchit_core Rust library).
///
/// The library runs an ant-core network client plus a localhost HTTP
/// streaming server in-process; playback streams from
/// `http://127.0.0.1:{port}/xor/{address}`. Fully self-contained — no
/// external gateway and nothing for the user to configure.
class EmbeddedClient {
  static int _port = 0;

  /// Base URL of the in-process streaming server, starting the native
  /// library on first use. Returns null where the library is unavailable
  /// (widget tests, or a desktop build without the .so).
  static String? baseUrl() {
    if (_port > 0) return 'http://127.0.0.1:$_port';
    try {
      final lib = DynamicLibrary.open('libwatchit_core.so');
      final start = lib.lookupFunction<Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)>('watchit_core_start');
      final port = start(nullptr);
      if (port <= 0) return null;
      _port = port;
      return 'http://127.0.0.1:$_port';
    } catch (_) {
      return null;
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
        message: map['message'] as String?,
      );
    } catch (e) {
      return ClientHealth(state: 'error', message: '$e');
    } finally {
      client.close();
    }
  }
}

class ClientHealth {
  const ClientHealth({required this.state, this.peers = 0, this.message});

  /// `connecting`, `ready`, `error`, or `unavailable` (no native library).
  final String state;
  final int peers;
  final String? message;

  String get label => switch (state) {
        'ready' =>
          'Connected ($peers ${peers == 1 ? 'peer' : 'peers'})',
        'connecting' => 'Connecting to the network…',
        'unavailable' => 'Native client not available on this platform',
        _ => 'Error: ${message ?? 'unknown'}',
      };
}

/// HTTP URL that streams [entry] from the embedded server at [base], or
/// null when the server is not running.
String? streamUrl(String? base, MediaEntry entry) {
  if (base == null || base.trim().isEmpty) return null;
  final b = base.trim().replaceFirst(RegExp(r'/+$'), '');
  final addr = entry.address.toLowerCase().replaceFirst('0x', '');
  return '$b/xor/$addr';
}
