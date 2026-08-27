import 'dart:convert';

import 'package:http/http.dart' as http;

import 'embedded_client.dart';

/// Client for the embedded server's My W@tch device-linking endpoints
/// (test implementation).
///
/// The routes are guarded by the FFI-provided auth token: the invite
/// secret admits a device to the user's private link, so only the app
/// may read or mint it. Errors surface as [MyWatchApiException] carrying
/// the server's plain-text explanation.
class MyWatchApi {
  MyWatchApi({String? base, String? token})
      : _baseOverride = base,
        _tokenOverride = token;

  final String? _baseOverride;
  final String? _tokenOverride;

  String get _base {
    final base = _baseOverride ?? EmbeddedClient.baseUrl();
    if (base == null) {
      throw MyWatchApiException('the embedded client is not running');
    }
    return base.replaceFirst(RegExp(r'/+$'), '');
  }

  Map<String, String> get _headers {
    final token = _tokenOverride ?? EmbeddedClient.authToken();
    return {
      'content-type': 'application/json',
      'x-watchit-auth': ?token,
    };
  }

  Future<Map<String, dynamic>> _request(String method, String path,
      {Object? body}) async {
    final client = http.Client();
    try {
      final uri = Uri.parse('$_base$path');
      final http.Response res = switch (method) {
        'GET' => await client.get(uri, headers: _headers),
        'POST' => await client.post(uri,
            headers: _headers, body: body == null ? null : jsonEncode(body)),
        'DELETE' => await client.delete(uri, headers: _headers),
        _ => throw ArgumentError(method),
      };
      // Decode as UTF-8 explicitly: the server sends application/json
      // without a charset parameter, which package:http decodes as
      // latin1 — mojibake for any non-ASCII synced text ("Amélie",
      // "S01E02 · Pilot").
      final text = utf8.decode(res.bodyBytes);
      if (res.statusCode != 200) {
        throw MyWatchApiException(text.trim().isEmpty
            ? 'request failed (${res.statusCode})'
            : text.trim());
      }
      if (text.isEmpty) return const {};
      return jsonDecode(text) as Map<String, dynamic>;
    } on MyWatchApiException {
      rethrow;
    } catch (e) {
      throw MyWatchApiException('could not reach the embedded client: $e');
    } finally {
      client.close();
    }
  }

  Future<MyWatchStatus> status() async =>
      MyWatchStatus.fromJson(await _request('GET', '/mywatch'));

  /// Create a new link on this device; returns the invite other devices
  /// join with (also rendered as a QR code).
  Future<String> createLink(String deviceName) async {
    final json = await _request('POST', '/mywatch/link',
        body: {'device_name': deviceName});
    return json['invite'] as String? ?? '';
  }

  /// Join a link created on another device from its invite string.
  Future<void> joinLink(String deviceName, String invite) => _request(
      'POST', '/mywatch/join',
      body: {'device_name': deviceName, 'invite': invite});

  /// The invite string of the existing link, for QR display.
  Future<String> invite() async {
    final json = await _request('GET', '/mywatch/invite');
    return json['invite'] as String? ?? '';
  }

  /// Publish this device's current library summary into its record.
  Future<void> announce({required int lists, required int entries}) =>
      _request('POST', '/mywatch/announce',
          body: {'lists': lists, 'entries': entries});

  /// Unlink this device and wipe its link artefacts (other devices keep
  /// the link).
  Future<void> unlink() => _request('DELETE', '/mywatch');

  /// Publish this device's library sync document. The embedded client
  /// attaches the shrunk data maps for the entries it holds locally
  /// before putting both into the link store.
  Future<void> publishSync(Map<String, dynamic> doc) =>
      _request('POST', '/mywatch/sync', body: {'doc': doc});

  /// Every remote device's sync document and entry maps, for the merge
  /// pass. Fails while the link is off or still starting.
  Future<List<RemoteSyncDoc>> syncDocs() async {
    final json = await _request('GET', '/mywatch/sync');
    return [
      for (final d in json['devices'] as List? ?? const [])
        RemoteSyncDoc.fromJson(d as Map<String, dynamic>),
    ];
  }

  /// Replace the set of user-artwork files this device serves to its
  /// linked peers (`sha256 → local file path`).
  Future<void> setArtIndex(List<({String sha256, String path})> files) =>
      _request('POST', '/mywatch/art/index', body: {
        'files': [
          for (final f in files) {'sha256': f.sha256, 'path': f.path},
        ],
      });

  /// Pull one artwork file from the linked device [agentId] (which must
  /// be online) and return the local path of the verified copy.
  Future<String> fetchArt({
    required String agentId,
    required String sha256,
  }) async {
    final json = await _request('POST', '/mywatch/art/fetch',
        body: {'agent_id': agentId, 'sha256': sha256});
    final path = json['path'] as String? ?? '';
    if (path.isEmpty) throw MyWatchApiException('artwork fetch returned no file');
    return path;
  }
}

/// One remote device's published sync state: its document plus the
/// base64 shrunk data maps for the entries it holds.
class RemoteSyncDoc {
  const RemoteSyncDoc({
    required this.agentId,
    required this.doc,
    required this.maps,
  });

  factory RemoteSyncDoc.fromJson(Map<String, dynamic> json) => RemoteSyncDoc(
        agentId: json['agent_id'] as String? ?? '',
        doc: json['doc'] as Map<String, dynamic>? ?? const {},
        maps: {
          for (final e in (json['maps'] as Map<String, dynamic>? ?? const {})
              .entries)
            e.key: e.value as String,
        },
      );

  final String agentId;
  final Map<String, dynamic> doc;

  /// address → base64 shrunk data map.
  final Map<String, String> maps;
}

class MyWatchStatus {
  const MyWatchStatus({
    required this.supported,
    required this.linked,
    required this.state,
    required this.devices,
    this.raw = '',
    this.message,
    this.deviceName,
    this.agentId,
    this.linkedSinceMs,
    this.lastSyncMs,
  });

  factory MyWatchStatus.fromJson(Map<String, dynamic> json) => MyWatchStatus(
        raw: jsonEncode(json),
        supported: json['supported'] as bool? ?? false,
        linked: json['linked'] as bool? ?? false,
        state: json['state'] as String? ?? 'off',
        message: json['message'] as String?,
        deviceName: json['device_name'] as String?,
        agentId: (json['agent_id'] as String?)?.isEmpty ?? true
            ? null
            : json['agent_id'] as String?,
        linkedSinceMs: json['linked_since_ms'] as int?,
        lastSyncMs: (json['last_sync_ms'] as int? ?? 0) == 0
            ? null
            : json['last_sync_ms'] as int,
        devices: [
          for (final d in json['devices'] as List? ?? const [])
            MyWatchDevice.fromJson(d as Map<String, dynamic>),
        ],
      );

  /// The status body as received — lets the screen skip rebuilds when a
  /// background refresh returns an unchanged snapshot.
  final String raw;

  final bool supported;
  final bool linked;

  /// `off`, `starting` (agent still coming up / retrying) or `ready`.
  final String state;

  /// Last startup problem, user-readable; null when all is well.
  final String? message;
  final String? deviceName;
  final String? agentId;
  final int? linkedSinceMs;

  /// Wall-clock ms when another device's record last changed under us —
  /// the last demonstrable sync. Null when it has never happened.
  final int? lastSyncMs;
  final List<MyWatchDevice> devices;
}

class MyWatchDevice {
  const MyWatchDevice({
    required this.agentId,
    required this.name,
    required this.platform,
    required this.isSelf,
    required this.online,
    required this.lists,
    required this.entries,
    this.updatedAtMs,
  });

  factory MyWatchDevice.fromJson(Map<String, dynamic> json) => MyWatchDevice(
        agentId: json['agent_id'] as String? ?? '',
        name: json['name'] as String? ?? 'unknown device',
        platform: json['platform'] as String? ?? '?',
        isSelf: json['self'] as bool? ?? false,
        online: json['online'] as bool? ?? false,
        lists: json['lists'] as int? ?? 0,
        entries: json['entries'] as int? ?? 0,
        updatedAtMs: (json['updated_at_ms'] as int? ?? 0) == 0
            ? null
            : json['updated_at_ms'] as int,
      );

  final String agentId;
  final String name;
  final String platform;
  final bool isSelf;
  final bool online;
  final int lists;
  final int entries;

  /// The device's own heartbeat stamp (its clock) — "last heard".
  final int? updatedAtMs;
}

class MyWatchApiException implements Exception {
  MyWatchApiException(this.message);
  final String message;
  @override
  String toString() => message;
}
