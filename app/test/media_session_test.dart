import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watchit/services/media_session.dart';
import 'package:watchit/services/now_playing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('watchit/media_session');
  late List<MethodCall> calls;
  late NowPlaying nowPlaying;
  late MediaSessionBridge bridge;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    nowPlaying = NowPlaying();
    bridge = MediaSessionBridge(channel: channel, isAndroid: true);
    bridge.bind(nowPlaying);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  Future<void> platformCall(String method, [Object? arguments]) async {
    const codec = StandardMethodCodec();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'watchit/media_session',
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );
  }

  test('a session starting starts the service (after asking for '
      'notifications); ending it stops the service', () async {
    nowPlaying.setTrack(
        Object(),
        const NowPlayingTrack(
            title: 'Gimme Shelter',
            artist: 'The Rolling Stones',
            album: 'Let It Bleed',
            artworkPath: '/tmp/cover.jpg'),
        handlers: const NowPlayingHandlers(),
        canNext: true,
        canPrev: true);
    await settle();
    expect(calls.map((c) => c.method).toList(),
        ['requestNotifications', 'start']);
    final args = calls.last.arguments as Map<Object?, Object?>;
    expect(args['title'], 'Gimme Shelter');
    expect(args['artist'], 'The Rolling Stones');
    expect(args['album'], 'Let It Bleed');
    expect(args['artworkPath'], '/tmp/cover.jpg');
    expect(args['playing'], false);
    expect(args['canNext'], true);

    calls.clear();
    final owner = Object();
    nowPlaying.setTrack(owner, const NowPlayingTrack(title: 'Next Song'),
        handlers: const NowPlayingHandlers());
    nowPlaying.clear(owner);
    await Future<void>.delayed(MediaSessionBridge.syncInterval * 2);
    expect(calls.map((c) => c.method), contains('stop'));
  });

  test('position ticks are throttled to ~1/s', () async {
    final owner = Object();
    nowPlaying.setTrack(owner, const NowPlayingTrack(title: 'Song'),
        handlers: const NowPlayingHandlers());
    await settle();
    calls.clear();
    for (var ms = 0; ms < 3000; ms += 100) {
      nowPlaying.updatePlayback(owner,
          position: Duration(milliseconds: ms));
    }
    await Future<void>.delayed(MediaSessionBridge.syncInterval * 2);
    expect(calls.length, lessThanOrEqualTo(2));
    expect(calls.map((c) => c.method).toSet(), {'update'});
  });

  test('platform button events dispatch to the session handlers',
      () async {
    final log = <String>[];
    nowPlaying.setTrack(Object(), const NowPlayingTrack(title: 'Song'),
        handlers: NowPlayingHandlers(
          onPlay: () => log.add('play'),
          onPause: () => log.add('pause'),
          onNext: () => log.add('next'),
          onPrevious: () => log.add('prev'),
          onSeek: (pos) => log.add('seek:${pos.inMilliseconds}'),
        ));
    await platformCall('onPlay');
    await platformCall('onPause');
    await platformCall('onNext');
    await platformCall('onPrevious');
    await platformCall('onSeek', {'positionMs': 2500});
    expect(log, ['play', 'pause', 'next', 'prev', 'seek:2500']);
  });

  test('platform onStop ends the Dart session too', () async {
    nowPlaying.setTrack(Object(), const NowPlayingTrack(title: 'Song'),
        handlers: const NowPlayingHandlers());
    await settle();
    await platformCall('onStop');
    expect(nowPlaying.track, isNull);
  });

  test('non-Android bridge never touches the channel', () async {
    final desktop = MediaSessionBridge(channel: channel, isAndroid: false);
    final np = NowPlaying();
    desktop.bind(np);
    np.setTrack(Object(), const NowPlayingTrack(title: 'Song'),
        handlers: const NowPlayingHandlers());
    await settle();
    expect(calls, isEmpty);
  });
}
