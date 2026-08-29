import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'embedded_client.dart';
import 'publish_api.dart';

/// Client for the embedded server's Channels endpoints (the PUBLIC
/// content space — docs/PLAN-personal-vs-channels.md; `PublishApi`
/// covers the private Upload space).
///
/// All routes are guarded by the FFI-provided auth token: publishing
/// spends real ANT and handles the channel signing key. Errors surface
/// as [PublishApiException] with the server's user-facing text.
class ChannelsApi {
  ChannelsApi({String? base, String? token})
      : _baseOverride = base,
        _tokenOverride = token;

  final String? _baseOverride;
  final String? _tokenOverride;

  String get _base {
    final base = _baseOverride ?? EmbeddedClient.baseUrl();
    if (base == null) {
      throw PublishApiException('the embedded client is not running');
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

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Object? body,
  }) async {
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
      if (res.statusCode != 200 && res.statusCode != 204) {
        throw PublishApiException(res.body.trim().isEmpty
            ? 'request failed (${res.statusCode})'
            : res.body.trim());
      }
      if (res.statusCode == 204 || res.body.isEmpty) return const {};
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } on PublishApiException {
      rethrow;
    } catch (e) {
      throw PublishApiException('could not reach the embedded client: $e');
    } finally {
      client.close();
    }
  }

  Future<ChannelsStatus> status() async {
    final json = await _request('GET', '/channels');
    return ChannelsStatus.fromJson(json);
  }

  /// A fresh 12-word channel phrase + the code it derives. Nothing is
  /// stored until [create] runs after the backup ceremony.
  Future<GeneratedChannel> generate() async {
    final json = await _request('POST', '/channel/generate');
    return GeneratedChannel(
      mnemonic: json['mnemonic'] as String,
      code: json['code'] as String,
    );
  }

  Future<CreatedChannel> create({
    required String name,
    required String description,
    String author = '',
    required String mnemonic,
  }) async {
    final json = await _request('POST', '/channel/create', body: {
      'name': name,
      'description': description,
      'author': author,
      'mnemonic': mnemonic,
    });
    return CreatedChannel(
      code: json['code'] as String,
      pubkey: json['pubkey'] as String,
      keyStorage: json['key_storage'] as String?,
    );
  }

  Future<CreatedChannel> restore(String mnemonic) async {
    final json =
        await _request('POST', '/channel/restore', body: {'mnemonic': mnemonic});
    return CreatedChannel(
      code: json['code'] as String,
      pubkey: json['pubkey'] as String,
      keyStorage: json['key_storage'] as String?,
    );
  }

  /// Update the locally displayed channel name/description/author (the
  /// canonical copy travels in the published manifest). An empty
  /// [author] clears it — the field is optional.
  Future<void> setMeta({
    required String name,
    required String description,
    String author = '',
  }) =>
      _request('POST', '/channel/meta', body: {
        'name': name,
        'description': description,
        'author': author,
      });

  /// Delete the channel key + config from this device.
  Future<void> removeOwn() => _request('DELETE', '/channel');

  /// The Settings switch: off stops the channels x0x agent (topic gossip
  /// and relay traffic) without touching the key, config or
  /// subscriptions; on starts it again.
  Future<void> setEnabled(bool enabled) =>
      _request('POST', '/channel/enabled', body: {'enabled': enabled});

  /// Publish the manifest zip at [path] publicly and announce the signed
  /// head. Returns the job id to poll with [PublishApi.jobStatus].
  Future<int> publishManifest(String path, {String? name}) async {
    final json = await _request('POST', '/channel/publish', body: {
      'path': path,
      'name': ?name,
    });
    return json['id'] as int;
  }

  Future<String> subscribe(String code) async {
    final json = await _request('POST', '/channel/subscribe', body: {'code': code});
    return json['pubkey'] as String;
  }

  Future<void> unsubscribe(String pubkey) =>
      _request('DELETE', '/channel/subscribe/$pubkey');

  /// Fetch a channel manifest (the zip bytes) from the network by its
  /// public address. Slow — one network round per call.
  Future<List<int>> fetchManifest(String address) async {
    final client = http.Client();
    try {
      final res = await client.get(
        Uri.parse('$_base/channel/manifest/$address'),
        headers: _headers,
      );
      if (res.statusCode != 200) {
        throw PublishApiException(res.body.trim().isEmpty
            ? 'manifest fetch failed (${res.statusCode})'
            : res.body.trim());
      }
      return res.bodyBytes;
    } on PublishApiException {
      rethrow;
    } catch (e) {
      throw PublishApiException('could not reach the embedded client: $e');
    } finally {
      client.close();
    }
  }

  /// One byte range of a channel manifest — the delta import's building
  /// block. [range] is a `bytes=`-form Range header value. A 200 answer
  /// (an embedded core from before range support) carries the whole
  /// manifest; the caller uses it as-is.
  Future<ManifestRangeResponse> fetchManifestRange(
      String address, String range) async {
    final client = http.Client();
    try {
      final res = await client.get(
        Uri.parse('$_base/channel/manifest/$address'),
        headers: {..._headers, 'range': range},
      );
      if (res.statusCode != 200 && res.statusCode != 206) {
        throw PublishApiException(res.body.trim().isEmpty
            ? 'manifest fetch failed (${res.statusCode})'
            : res.body.trim());
      }
      int? start, total;
      final contentRange = res.headers['content-range'];
      final m = contentRange == null
          ? null
          : RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(contentRange);
      if (m != null) {
        start = int.parse(m.group(1)!);
        total = int.parse(m.group(3)!);
      }
      return ManifestRangeResponse(
        status: res.statusCode,
        bytes: res.bodyBytes,
        start: start,
        total: total,
      );
    } on PublishApiException {
      rethrow;
    } catch (e) {
      throw PublishApiException('could not reach the embedded client: $e');
    } finally {
      client.close();
    }
  }
}

/// One ranged read of a manifest: 206 partial content (with its
/// Content-Range position) or a 200 whole-manifest answer.
class ManifestRangeResponse {
  const ManifestRangeResponse({
    required this.status,
    required this.bytes,
    this.start,
    this.total,
  });

  final int status;
  final Uint8List bytes;

  /// Absolute offset of [bytes] in the manifest (206 answers only).
  final int? start;

  /// The manifest's total size (206 answers only).
  final int? total;
}

class GeneratedChannel {
  const GeneratedChannel({required this.mnemonic, required this.code});
  final String mnemonic;
  final String code;
}

class CreatedChannel {
  const CreatedChannel({required this.code, required this.pubkey, this.keyStorage});
  final String code;
  final String pubkey;

  /// `keychain` or `file` — `file` means the signing key sits in a
  /// mode-0600 app file because no OS keychain was available.
  final String? keyStorage;
}

class ChannelHead {
  const ChannelHead({required this.seq, required this.manifest});
  final int seq;

  /// Manifest address (64 hex chars) the head points at.
  final String manifest;

  static ChannelHead? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final seq = json['seq'] as int?;
    final manifest = json['manifest'] as String?;
    if (seq == null || manifest == null) return null;
    return ChannelHead(seq: seq, manifest: manifest);
  }
}

class OwnChannel {
  const OwnChannel({
    required this.name,
    required this.description,
    this.author = '',
    required this.pubkey,
    required this.code,
    required this.seq,
    required this.manifest,
    required this.createdAtMs,
    this.keyStorage,
    this.keyMissing = false,
    this.head,
  });

  final String name;
  final String description;

  /// Optional "by `<author>`" name/handle; empty = unset.
  final String author;
  final String pubkey;
  final String code;

  /// Highest head sequence this device has published (0 = never).
  final int seq;
  final String manifest;
  final int createdAtMs;
  final String? keyStorage;

  /// Config exists but the signing key is gone (wiped keychain) — the
  /// channel cannot publish until restored from its phrase.
  final bool keyMissing;

  /// Newest signature-verified head visible in the gossip store (what a
  /// restored device learns its own history from).
  final ChannelHead? head;
}

class SubscribedChannel {
  const SubscribedChannel({required this.pubkey, required this.code, this.head});
  final String pubkey;
  final String code;
  final ChannelHead? head;
}

class ChannelsStatus {
  const ChannelsStatus({
    required this.supported,
    required this.state,
    this.enabled = true,
    this.message,
    this.own,
    this.subs = const [],
  });

  final bool supported;

  /// The Settings switch (Built-in x0x client): false means the user
  /// turned Channels off — the agent stays down until switched back on.
  final bool enabled;

  /// `off` | `starting` | `ready` (the channels gossip agent).
  final String state;
  final String? message;
  final OwnChannel? own;
  final List<SubscribedChannel> subs;

  factory ChannelsStatus.fromJson(Map<String, dynamic> json) {
    final ownJson = json['own'] as Map<String, dynamic>?;
    return ChannelsStatus(
      supported: json['supported'] as bool? ?? false,
      enabled: json['enabled'] as bool? ?? true,
      state: json['state'] as String? ?? 'off',
      message: json['message'] as String?,
      own: ownJson == null
          ? null
          : OwnChannel(
              name: ownJson['name'] as String? ?? '',
              description: ownJson['description'] as String? ?? '',
              author: ownJson['author'] as String? ?? '',
              pubkey: ownJson['pubkey'] as String? ?? '',
              code: ownJson['code'] as String? ?? '',
              seq: ownJson['seq'] as int? ?? 0,
              manifest: ownJson['manifest'] as String? ?? '',
              createdAtMs: ownJson['created_at_ms'] as int? ?? 0,
              keyStorage: ownJson['key_storage'] as String?,
              keyMissing: ownJson['key_missing'] as bool? ?? false,
              head: ChannelHead.fromJson(
                  ownJson['head'] as Map<String, dynamic>?),
            ),
      subs: [
        for (final sub in json['subs'] as List<dynamic>? ?? const [])
          SubscribedChannel(
            pubkey: (sub as Map<String, dynamic>)['pubkey'] as String? ?? '',
            code: sub['code'] as String? ?? '',
            head: ChannelHead.fromJson(sub['head'] as Map<String, dynamic>?),
          ),
      ],
    );
  }
}
