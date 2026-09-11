import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:watchit/services/trezor_suite.dart';

class _FakeClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  final bodies = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final body = await request.finalize().bytesToString();
    bodies.add(body);
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    final method = decoded['method'] as String;
    final response = switch (method) {
      'initialize' => {
          'jsonrpc': '2.0',
          'id': decoded['id'],
          'result': {
            'protocolVersion': '2025-03-26',
            'serverInfo': {'name': 'Trezor Suite', 'version': '1.0.0'},
          },
        },
      'notifications/initialized' => null,
      'tools/call' => {
          'jsonrpc': '2.0',
          'id': decoded['id'],
          'result': {
            'structuredContent': {
              'address': '0x1234567890abcdef1234567890abcdef12345678',
            },
          },
        },
      _ => throw StateError('unexpected method $method'),
    };
    final bytes = response == null
        ? <int>[]
        : utf8.encode(jsonEncode(response));
    return http.StreamedResponse(
      Stream.fromIterable([bytes]),
      200,
      headers: {'content-type': 'application/json', 'mcp-session-id': 'session-1'},
    );
  }
}

void main() {
  test('initializes and reads a Trezor address without persisting the token', () async {
    final fake = _FakeClient();
    final client = TrezorSuiteClient(token: 'secret-token', httpClient: fake);
    final server = await client.initialize();
    final address = await client.getAddress();

    expect(server.name, 'Trezor Suite');
    expect(address, '0x1234567890abcdef1234567890abcdef12345678');
    expect(fake.requests, hasLength(3));
    expect(fake.requests.every((request) => request.headers['authorization'] == 'Bearer secret-token'), isTrue);
    expect(fake.requests.every((request) => request.url.queryParameters['token'] == 'secret-token'), isTrue);
    expect(fake.bodies[1], contains('notifications/initialized'));
    client.close();
  });

  test('rejects an empty token before making a request', () async {
    final fake = _FakeClient();
    final client = TrezorSuiteClient(token: '  ', httpClient: fake);
    expect(client.initialize, throwsA(isA<TrezorSuiteException>()));
    expect(fake.requests, isEmpty);
    client.close();
  });
}
