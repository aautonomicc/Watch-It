import 'package:flutter_test/flutter_test.dart';

import 'package:watchit/services/now_playing.dart';

void main() {
  test('setTrack starts a session; updatePlayback feeds it', () {
    final np = NowPlaying();
    final owner = Object();
    np.setTrack(owner, const NowPlayingTrack(title: 'Song', artist: 'A'),
        handlers: const NowPlayingHandlers(), canNext: true);
    expect(np.track!.title, 'Song');
    expect(np.canNext, isTrue);
    expect(np.canPrev, isFalse);
    expect(np.playing, isFalse);

    np.updatePlayback(owner,
        playing: true,
        position: const Duration(seconds: 3),
        duration: const Duration(seconds: 60));
    expect(np.playing, isTrue);
    expect(np.position, const Duration(seconds: 3));
    expect(np.duration, const Duration(seconds: 60));
  });

  test('a superseded player cannot update or end the new session', () {
    final np = NowPlaying();
    final first = Object();
    final second = Object();
    np.setTrack(first, const NowPlayingTrack(title: 'One'),
        handlers: const NowPlayingHandlers());
    np.updatePlayback(first, playing: true);
    np.setTrack(second, const NowPlayingTrack(title: 'Two'),
        handlers: const NowPlayingHandlers());
    // Track change resets playback state until the new owner reports.
    expect(np.playing, isFalse);

    np.updatePlayback(first, playing: true); // stale — ignored
    expect(np.playing, isFalse);
    np.clear(first); // stale — ignored
    expect(np.track!.title, 'Two');

    np.clear(second);
    expect(np.track, isNull);
  });

  test('remote controls dispatch to the registered handlers', () {
    final np = NowPlaying();
    final log = <String>[];
    np.setTrack(Object(), const NowPlayingTrack(title: 'Song'),
        handlers: NowPlayingHandlers(
          onPlay: () => log.add('play'),
          onPause: () => log.add('pause'),
          onNext: () => log.add('next'),
          onPrevious: () => log.add('prev'),
          onSeek: (pos) => log.add('seek:${pos.inMilliseconds}'),
        ));
    np.remotePlay();
    np.remotePause();
    np.remoteNext();
    np.remotePrevious();
    np.remoteSeek(const Duration(milliseconds: 1500));
    expect(log, ['play', 'pause', 'next', 'prev', 'seek:1500']);
  });

  test('remoteStop tells the owner and ends the session', () {
    final np = NowPlaying();
    var stopped = false;
    np.setTrack(Object(), const NowPlayingTrack(title: 'Song'),
        handlers: NowPlayingHandlers(onStop: () => stopped = true));
    np.remoteStop();
    expect(stopped, isTrue);
    expect(np.track, isNull);
  });

  test('clearing without a session is a no-op', () {
    final np = NowPlaying();
    np.clear(Object());
    np.remotePlay(); // no handlers — must not throw
    expect(np.track, isNull);
  });
}
