import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:watchit/services/android_saf.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('watchit/export');

  setUp(() {
    PathProviderPlatform.instance = _FakePathProvider();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('saveFile hands a temp copy to the channel and returns the '
      'display name', () async {
    Map<Object?, Object?>? args;
    List<int>? bytesAtCallTime;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'saveFile');
      args = call.arguments as Map<Object?, Object?>;
      // The temp file must hold the export while the native side copies.
      bytesAtCallTime =
          File(args!['path'] as String).readAsBytesSync();
      return 'pack.watch-list';
    });

    final saved = await AndroidSaf.saveFile(
      Uint8List.fromList([1, 2, 3]),
      fileName: 'pack.watch-list',
      mimeType: 'application/zip',
    );

    expect(saved, 'pack.watch-list');
    expect(bytesAtCallTime, [1, 2, 3]);
    expect(args!['fileName'], 'pack.watch-list');
    expect(args!['mimeType'], 'application/zip');
  });

  test('a cancelled dialog returns null', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    expect(
      await AndroidSaf.saveFile(Uint8List.fromList([1]),
          fileName: 'a.watch-list', mimeType: 'application/zip'),
      isNull,
    );
  });

  test('a native write error surfaces as PlatformException', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
          code: 'write', message: 'Could not write the file');
    });
    expect(
      () => AndroidSaf.saveFile(Uint8List.fromList([1]),
          fileName: 'a.watch-list', mimeType: 'application/zip'),
      throwsA(isA<PlatformException>()),
    );
  });
}
