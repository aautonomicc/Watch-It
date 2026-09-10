import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:watchit/services/caption_file.dart';
import 'package:watchit/services/tv_settings.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/tv_app_frame.dart';
import 'package:watchit/widgets/tv_track_menu.dart';
import 'package:watchit/widgets/tv_player_controls.dart';

void main() {
  setUp(() => TvSettings.instance = TvSettings(enabled: true));
  tearDown(() {
    TvSettings.instance.dispose();
    TvSettings.instance = TvSettings();
  });
  const audioLv = AudioTrack('1', 'Original recording', 'lav');
  const audioEn = AudioTrack('2', 'English dub · machine draft', 'eng');
  const captionLv = SubtitleTrack('1', 'Latvian captions', 'lv');
  const captionEn = SubtitleTrack(
    '2',
    'English captions · machine draft',
    'en',
  );
  const tracks = Tracks(
    audio: [audioLv, audioEn],
    subtitle: [captionLv, captionEn],
  );

  Widget app(Widget child) => MaterialApp(
    theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
    builder: (_, child) => TvAppFrame(child: child!),
    home: Scaffold(body: child),
  );

  Widget menu({
    Tracks available = tracks,
    Track selected = const Track(),
    Future<void> Function(AudioTrack)? audio,
    Future<void> Function(SubtitleTrack)? caption,
    Future<void> Function()? load,
  }) => app(
    Builder(
      builder: (context) => TextButton(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => TvTrackMenu(
            tracks: available,
            selected: selected,
            onAudio: audio ?? (_) async {},
            onCaption: caption ?? (_) async {},
            onLoadCaptions: load,
          ),
        ),
        child: const Text('Open'),
      ),
    ),
  );

  testWidgets(
    'remote picks a named audio track without calling caption selection',
    (tester) async {
      AudioTrack? picked;
      var captionCalls = 0;
      await tester.pumpWidget(
        menu(
          audio: (t) async => picked = t,
          caption: (_) async {
            captionCalls++;
          },
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Latvian'), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(picked, audioLv);
      expect(captionCalls, 0);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(TvTrackMenu), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'remote can select a caption and then turn captions off',
    (tester) async {
      final chosen = <SubtitleTrack>[];
      await tester.pumpWidget(menu(caption: (t) async => chosen.add(t)));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 5; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(chosen, [captionLv]);
      await tester.ensureVisible(find.text('Captions off'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Captions off'));
      await tester.pumpAndSettle();
      expect(chosen.last.id, 'no');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'failed selection is named and cannot falsely mark the requested track selected',
    (tester) async {
      await tester.pumpWidget(
        menu(
          selected: const Track(audio: audioLv),
          audio: (_) async => throw StateError('private uri must not appear'),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English dub · machine draft'));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not change audio. Try another track.'),
        findsOneWidget,
      );
      expect(find.textContaining('private uri'), findsNothing);
      expect(
        tester
            .widget<ListTile>(
              find.widgetWithText(ListTile, 'Original recording'),
            )
            .selected,
        isTrue,
      );
    },
  );

  testWidgets(
    'missing tracks are explicit and do not synthesize a language choice',
    (tester) async {
      await tester.pumpWidget(menu(available: const Tracks()));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('No audio tracks reported yet.'), findsOneWidget);
      expect(find.textContaining('No caption tracks'), findsOneWidget);
      expect(find.text('Latvian'), findsNothing);
      expect(find.text('Automatic captions'), findsNothing);
    },
  );

  testWidgets(
    'transport keeps controls open during menu, Back returns focus to Play',
    (tester) async {
      var plays = 0;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TvPlayerControls(
              title: 'Movie',
              position: const Duration(seconds: 30),
              duration: const Duration(minutes: 2),
              playing: true,
              onPlayPause: () => plays++,
              onSeek: (_) => fail('Menu must not seek'),
              onExit: () => fail('Menu must not exit'),
              onNext: () {},
              onTracks: () => showDialog<void>(
                context: context,
                builder: (_) => TvTrackMenu(
                  tracks: tracks,
                  selected: const Track(),
                  onAudio: (_) async {},
                  onCaption: (_) async {},
                ),
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Audio & Captions'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 9));
      expect(find.byType(TvTrackMenu), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tv-transport')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(plays, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('dialog fits 960 by 540 TV with long labels and tracks', (
    tester,
  ) async {
    tester.view.reset();
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      menu(
        available: Tracks(
          audio: [
            for (var i = 0; i < 14; i++)
              AudioTrack(
                '$i',
                'Long audio track title in a language with additional commentary $i',
                'lv',
              ),
          ],
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('captions remain above the transport while paused', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        TvPlayerControls(
          title: 'Movie',
          position: const Duration(seconds: 30),
          duration: const Duration(minutes: 2),
          playing: false,
          onPlayPause: () {},
          onSeek: (_) {},
          onExit: () {},
          onNext: () {},
          onTracks: () async {},
          captions: const Align(
            alignment: Alignment.bottomCenter,
            child: Text('Šis ir tikai subtitru tests.'),
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final caption = tester.getRect(find.text('Šis ir tikai subtitru tests.'));
    final transport = tester.getRect(
      find.byKey(const ValueKey('tv-transport')),
    );
    expect(caption.bottom, lessThanOrEqualTo(transport.top));
    expect(tester.takeException(), isNull);
  });

  test('caption parser keeps Latvian text and identifies file language', () {
    final c = CaptionFile.parse(
      'pilot.lv.vtt',
      Uint8List.fromList(
        utf8.encode('\uFEFFWEBVTT\n\n00:00.000 --> 00:02.000\nŠis ir tests.\n'),
      ),
    );
    expect(c.language, 'lv');
    expect(c.text, contains('Šis ir tests.'));
    expect(c.text.startsWith('WEBVTT'), isTrue);
  });
  test(
    'caption parser accepts SRT and refuses unsupported or untimed input',
    () {
      final cue = Uint8List.fromList(
        utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nTest\n'),
      );
      expect(CaptionFile.parse('clip.en.srt', cue).language, 'en');
      expect(() => CaptionFile.parse('clip.exe', cue), throwsFormatException);
      expect(() => CaptionFile.parse('clip.vtt', cue), throwsFormatException);
      expect(
        () => CaptionFile.parse(
          'clip.srt',
          Uint8List.fromList(utf8.encode('No timing')),
        ),
        throwsFormatException,
      );
    },
  );
  test('caption parser refuses oversized and invalid UTF-8 input', () {
    expect(
      () => CaptionFile.parse('clip.srt', Uint8List(CaptionFile.maxBytes + 1)),
      throwsFormatException,
    );
    expect(
      () => CaptionFile.parse('clip.srt', Uint8List.fromList([255, 255])),
      throwsFormatException,
    );
  });
}
