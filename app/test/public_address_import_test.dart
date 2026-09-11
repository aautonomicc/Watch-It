import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/services/public_address_import.dart';
import 'package:watchit/services/list_import.dart' show ListImportException;

void main() {
  test('normalizes an optional 0x prefix', () {
    expect(normalizePublicAddress('  0x${'AB' * 32} '), 'ab' * 32);
  });

  test('rejects malformed addresses before making a request', () async {
    try {
      await inspectPublicAddress('not-an-address', base: 'http://127.0.0.1:1');
      fail('expected ListImportException');
    } on ListImportException catch (e) {
      expect(e.message, contains('64 hexadecimal'));
    }
  });

  test('inspects a public address through the local client', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      expect(request.method, 'HEAD');
      expect(request.uri.path, '/public/${'cd' * 32}');
      request.response.headers.contentLength = 4567;
      await request.response.close();
    });
    try {
      final result = await inspectPublicAddress(
        '0x${'CD' * 32}',
        base: 'http://127.0.0.1:${server.port}',
      );
      expect(result.address, 'cd' * 32);
      expect(result.sizeBytes, 4567);
    } finally {
      await server.close(force: true);
    }
  });
}
