import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:watchit/screens/player_screen.dart';
import 'package:watchit/services/screen_wake.dart';

/// Records ScreenSaver calls without touching a real bus (DBusClient.session
/// never connects until a method is actually sent through it).
class _FakeScreenSaver extends DBusRemoteObject {
  _FakeScreenSaver({this.fail = false})
      : super(
          DBusClient(DBusAddress('unix:path=/nonexistent')),
          name: 'org.freedesktop.ScreenSaver',
          path: DBusObjectPath('/org/freedesktop/ScreenSaver'),
        );

  final bool fail;
  final List<String> calls = [];

  @override
  Future<DBusMethodSuccessResponse> callMethod(
      String? interface, String name, Iterable<DBusValue> values,
      {DBusSignature? replySignature,
      bool noReplyExpected = false,
      bool noAutoStart = false,
      bool allowInteractiveAuthorization = false}) async {
    if (fail) {
      throw DBusServiceUnknownException(
          DBusMethodErrorResponse('org.freedesktop.DBus.Error.ServiceUnknown'));
    }
    calls.add('$name(${values.map((v) => v.toNative()).join(', ')})');
    if (name == 'Inhibit') {
      return DBusMethodSuccessResponse([const DBusUint32(42)]);
    }
    return DBusMethodSuccessResponse([]);
  }
}

void main() {
  // These tests exercise the Linux path; ScreenWake is a no-op elsewhere
  // and the suite only runs on the Linux dev box / CI anyway.

  test('playback start inhibits, stop releases the same cookie', () async {
    final saver = _FakeScreenSaver();
    final wake = ScreenWake(objectFactory: () => saver);

    wake.setPlaying(true);
    await wake.idle;
    expect(saver.calls, ['Inhibit(W@tch, Playing media)']);

    wake.setPlaying(false);
    await wake.idle;
    expect(saver.calls, [
      'Inhibit(W@tch, Playing media)',
      'UnInhibit(42)',
    ]);
  });

  test('repeated same-state calls do not stack inhibits', () async {
    final saver = _FakeScreenSaver();
    final wake = ScreenWake(objectFactory: () => saver);

    wake.setPlaying(true);
    wake.setPlaying(true);
    wake.setPlaying(true);
    await wake.idle;
    expect(saver.calls, hasLength(1));

    wake.setPlaying(false);
    wake.setPlaying(false);
    await wake.idle;
    expect(saver.calls, hasLength(2));
  });

  test('play immediately followed by pause never acquires', () async {
    final saver = _FakeScreenSaver();
    final wake = ScreenWake(objectFactory: () => saver);

    wake.setPlaying(true);
    wake.setPlaying(false);
    await wake.idle;
    expect(saver.calls, isEmpty);
  });

  test('missing ScreenSaver service is tolerated silently', () async {
    final saver = _FakeScreenSaver(fail: true);
    final wake = ScreenWake(objectFactory: () => saver);

    wake.setPlaying(true);
    await wake.idle;
    wake.setPlaying(false);
    await wake.idle;
    expect(saver.calls, isEmpty);
  });

  test('desktop controls hide the mouse cursor once controls fade', () {
    final normal =
        desktopControlsTheme(kDefaultMaterialDesktopVideoControlsThemeData);
    final fullscreen = desktopControlsTheme(
        kDefaultMaterialDesktopVideoControlsThemeDataFullscreen);
    expect(normal.hideMouseOnControlsRemoval, isTrue);
    expect(fullscreen.hideMouseOnControlsRemoval, isTrue);
    // The branded buffering overlay replaces the stock spinner.
    expect(normal.bufferingIndicatorBuilder, isNotNull);
    expect(fullscreen.bufferingIndicatorBuilder, isNotNull);
  });
}
