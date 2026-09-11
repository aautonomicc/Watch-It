import 'dart:convert';

import 'package:http/http.dart' as http;

/// Small client for the local Trezor Suite MCP server.
///
/// The server is deliberately localhost-only and requires the token shown by
/// Trezor Suite. This client keeps the token in memory for the current app
/// session; it never writes it to W@tch settings, logs, or the network.
/// Signing and sending are intentionally not exposed here yet. The first
/// integration milestone is read-only address/account discovery so a user
/// can verify the hardware wallet before it is offered for a paid upload.
class TrezorSuiteClient {
  TrezorSuiteClient({
    required this.token,
    this.endpoint = defaultEndpoint,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  static const defaultEndpoint = 'http://127.0.0.1:21340/mcp';

  final String token;
  final String endpoint;
  final http.Client _http;
  String? _sessionId;
  int _nextId = 1;

  Uri get _uri {
    final base = Uri.parse(endpoint);
    final query = Map<String, String>.from(base.queryParameters);
    query['token'] = token;
    return base.replace(queryParameters: query);
  }

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        'accept': 'application/json, text/event-stream',
        'authorization': 'Bearer $token',
        'mcp-protocol-version': '2025-03-26',
        if (_sessionId != null) 'mcp-session-id': _sessionId!,
      };

  Future<TrezorSuiteServer> initialize() async {
    final result = await _request('initialize', {
      'protocolVersion': '2025-03-26',
      'capabilities': <String, dynamic>{},
      'clientInfo': {'name': 'W@tch', 'version': '0.1.0'},
    });
    final serverInfo = result['serverInfo'];
    await _notify('notifications/initialized', const {});
    return TrezorSuiteServer(
      name: serverInfo is Map ? serverInfo['name'] as String? : null,
      version: serverInfo is Map ? serverInfo['version'] as String? : null,
      protocolVersion: result['protocolVersion'] as String?,
    );
  }

  /// Read a receive address from the connected device. With
  /// [showOnTrezor] false this is a read-only operation; setting it true
  /// asks the user to verify the address on the physical device.
  Future<String> getAddress({
    String coin = 'eth',
    String path = "m/44'/60'/0'/0/0",
    bool showOnTrezor = false,
  }) async {
    final result = await callTool('trezor_get_address', {
      'coin': coin,
      'path': path,
      'showOnTrezor': showOnTrezor,
    });
    final address = result['address'];
    if (address is! String || address.trim().isEmpty) {
      throw const TrezorSuiteException('Trezor Suite returned no address');
    }
    return address.trim();
  }

  /// Call a read-only Suite tool. This is kept public for account discovery
  /// as the supported coin/path matrix grows; signing methods are deliberately
  /// not wrapped until the upload pipeline has an explicit confirmation UI.
  Future<Map<String, dynamic>> callTool(
      String name, Map<String, dynamic> arguments) async {
    final result = await _request('tools/call', {
      'name': name,
      'arguments': arguments,
    });
    final structured = result['structuredContent'];
    if (structured is Map<String, dynamic>) return structured;
    final content = result['content'];
    if (content is List) {
      for (final item in content) {
        if (item is Map && item['type'] == 'text' && item['text'] is String) {
          try {
            final decoded = jsonDecode(item['text'] as String);
            if (decoded is Map<String, dynamic>) return decoded;
          } catch (_) {
            // The server may return a human-readable text result.
          }
        }
      }
    }
    return result;
  }

  Future<void> _notify(String method, Map<String, dynamic> params) async {
    final response = await _http
        .post(_uri, headers: _headers, body: jsonEncode({
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    }))
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200 && response.statusCode != 202) {
      throw TrezorSuiteException(
          'Trezor Suite unavailable (${response.statusCode})');
    }
    final session = response.headers['mcp-session-id'];
    if (session != null && session.isNotEmpty) _sessionId = session;
  }

  Future<Map<String, dynamic>> _request(
      String method, Map<String, dynamic> params) async {
    if (token.trim().isEmpty) {
      throw const TrezorSuiteException('Trezor Suite token is empty');
    }
    final id = _nextId++;
    final response = await _http
        .post(_uri, headers: _headers, body: jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }))
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200 && response.statusCode != 202) {
      throw TrezorSuiteException(
          'Trezor Suite unavailable (${response.statusCode})');
    }
    final session = response.headers['mcp-session-id'];
    if (session != null && session.isNotEmpty) _sessionId = session;
    final body = response.body.trim();
    if (body.isEmpty) {
      throw const TrezorSuiteException('Trezor Suite returned an empty response');
    }
    final decoded = _decodeStreamableBody(body);
    final error = decoded['error'];
    if (error is Map) {
      final message = error['message'] as String? ?? 'MCP request failed';
      throw TrezorSuiteException(message);
    }
    final result = decoded['result'];
    if (result is! Map<String, dynamic>) {
      throw const TrezorSuiteException(
          'Trezor Suite returned an invalid response');
    }
    return result;
  }

  /// Streamable HTTP may return plain JSON or a one-event SSE body.
  static Map<String, dynamic> _decodeStreamableBody(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      for (final line in body.split('\n').reversed) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('data:')) continue;
        final data = trimmed.substring('data:'.length).trim();
        if (data.isEmpty || data == '[DONE]') continue;
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) return decoded;
      }
      throw const TrezorSuiteException('Trezor Suite returned unreadable data');
    }
  }

  void close() => _http.close();
}

class TrezorSuiteServer {
  const TrezorSuiteServer({this.name, this.version, this.protocolVersion});
  final String? name;
  final String? version;
  final String? protocolVersion;
}

class TrezorSuiteException implements Exception {
  const TrezorSuiteException(this.message);
  final String message;
  @override
  String toString() => message;
}
