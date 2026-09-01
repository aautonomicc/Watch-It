import 'dart:convert';

import 'package:test/test.dart';
import 'package:watchit_naming/watchit_naming.dart';

void main() {
  group('parseMediaName (moved from app, behaviour pinned)', () {
    test('Plex convention', () {
      final p = parseMediaName(
          'Night of the Living Dead (1968) {imdb-tt0063350} - [1080p].mp4');
      expect(p.title, 'Night of the Living Dead');
      expect(p.year, 1968);
      expect(p.imdbId, 'tt0063350');
      expect(p.lookupKey, 'imdb:tt0063350');
    });

    test('Jellyfin variant', () {
      final p = parseMediaName('The Movie (2024) [imdbid-tt1234567].mkv');
      expect(p.imdbId, 'tt1234567');
      expect(p.year, 2024);
    });

    test('release style', () {
      final p = parseMediaName('The.Movie.2024.1080p.mkv');
      expect(p.title, 'The Movie');
      expect(p.year, 2024);
    });

    test('episode marker', () {
      final p = parseMediaName('Show S01E02.mkv');
      expect(p.isEpisode, isTrue);
      expect(p.season, 1);
      expect(p.episode, 2);
      expect(p.title, 'Show');
    });

    test('1x02 marker', () {
      final p = parseMediaName('Show 1x02.mkv');
      expect(p.season, 1);
      expect(p.episode, 2);
    });

    test('plain name passes through', () {
      expect(parseMediaName('plainname.mp4').title, 'plainname');
    });

    test('audio extensions stripped (music discriminator)', () {
      expect(parseMediaName('BegBlag.mp3').title, 'BegBlag');
      expect(parseMediaName('song.flac').title, 'song');
      expect(parseMediaName('song.opus').title, 'song');
      expect(parseMediaName('BegBlag.mp3').isAudio, isTrue);
      expect(parseMediaName('BegBlag.mp3').isTrack, isFalse);
      expect(parseMediaName('Movie (2024).mp4').isAudio, isFalse);
    });

    test('music track convention', () {
      final p = parseMediaName(
          'The Rolling Stones - Let It Bleed (1969) - 05 Gimme Shelter '
          '{mbid-c07f0676-9d95-4443-a841-b1cbcfa48f4e}.flac');
      expect(p.isAudio, isTrue);
      expect(p.isTrack, isTrue);
      expect(p.artist, 'The Rolling Stones');
      expect(p.title, 'Let It Bleed');
      expect(p.album, 'Let It Bleed');
      expect(p.year, 1969);
      expect(p.track, 5);
      expect(p.disc, isNull);
      expect(p.trackTitle, 'Gimme Shelter');
      expect(p.releaseMbid, 'c07f0676-9d95-4443-a841-b1cbcfa48f4e');
      expect(p.lookupKey, 'mbid:c07f0676-9d95-4443-a841-b1cbcfa48f4e');
      expect(p.trackMarker, '05');
    });

    test('multi-disc D-NN marker', () {
      final p = parseMediaName('A - B (2000) - 2-03 T {mbid-abc}.flac');
      expect(p.disc, 2);
      expect(p.track, 3);
      expect(p.trackTitle, 'T');
      expect(p.trackMarker, '2-03');
    });

    test('case-B track without mbid keys on artist/album/year', () {
      final p =
          parseMediaName('Home Artist - Demos (2025) - 01 First Song.mp3');
      expect(p.isTrack, isTrue);
      expect(p.releaseMbid, isNull);
      expect(p.lookupKey, 'music:home artist:demos:2025');
    });

    test('track without year', () {
      final p = parseMediaName('Artist - Album - 07 Song.ogg');
      expect(p.isTrack, isTrue);
      expect(p.year, isNull);
      expect(p.track, 7);
      expect(p.lookupKey, 'music:artist:album:');
    });

    test('video names never parse as tracks', () {
      final p = parseMediaName('Artist - Album (2000) - 05 Title.mp4');
      expect(p.isTrack, isFalse);
      expect(p.isAudio, isFalse);
    });
  });

  group('sanitizeNamePart', () {
    test('substitution table', () {
      expect(sanitizeNamePart('AC/DC'), 'AC-DC');
      expect(sanitizeNamePart('Album: Live'), 'Album - Live');
      expect(sanitizeNamePart('What?'), 'What');
      expect(sanitizeNamePart('a  <b> "c" |d| *e*'), 'a b c d e');
      expect(sanitizeNamePart('Trailing dots...'), 'Trailing dots');
      expect(sanitizeNamePart('back\\slash'), 'back-slash');
    });

    test('NFC normalization', () {
      // e + combining acute (NFD) normalizes to the single é code point.
      expect(sanitizeNamePart('Amélie'), 'Amélie');
    });

    test('control characters stripped', () {
      expect(sanitizeNamePart('a\x00b\x1fc'), 'abc');
    });
  });

  group('fitFileName', () {
    test('under budget passes through', () {
      expect(fitFileName('abc', '.mp4'), 'abc.mp4');
    });

    test('truncates stem, preserves suffix', () {
      final name = fitFileName('x' * 300, ' {mbid-abc}.flac');
      expect(utf8.encode(name).length, lessThanOrEqualTo(255));
      expect(name, endsWith(' {mbid-abc}.flac'));
    });

    test('multibyte never split', () {
      final name = fitFileName('é' * 200, '.mp3', maxBytes: 100);
      expect(utf8.encode(name).length, lessThanOrEqualTo(100));
      // Round-trips through utf8 cleanly (no split code point).
      expect(utf8.decode(utf8.encode(name)), name);
    });
  });

  group('musicFileName', () {
    test('canonical shape', () {
      expect(
        musicFileName(
          artist: 'The Rolling Stones',
          album: 'Let It Bleed',
          year: 1969,
          track: 5,
          title: 'Gimme Shelter',
          releaseMbid: 'c07f0676-9d95-4443-a841-b1cbcfa48f4e',
          ext: 'flac',
        ),
        'The Rolling Stones - Let It Bleed (1969) - 05 Gimme Shelter '
        '{mbid-c07f0676-9d95-4443-a841-b1cbcfa48f4e}.flac',
      );
    });

    test('multi-disc D-NN prefix only when discs > 1', () {
      final multi = musicFileName(
          artist: 'A',
          album: 'B',
          year: 2000,
          track: 3,
          disc: 2,
          discTotal: 2,
          title: 'T',
          releaseMbid: 'm',
          ext: 'flac');
      expect(multi, contains(' - 2-03 T '));
      final single = musicFileName(
          artist: 'A',
          album: 'B',
          year: 2000,
          track: 3,
          disc: 1,
          discTotal: 1,
          title: 'T',
          releaseMbid: 'm',
          ext: 'flac');
      expect(single, contains(' - 03 T '));
    });

    test('case-B: no mbid → no tag', () {
      expect(
        musicFileName(
            artist: 'Home Artist',
            album: 'Demos',
            year: 2025,
            track: 1,
            title: 'First Song',
            ext: 'mp3'),
        'Home Artist - Demos (2025) - 01 First Song.mp3',
      );
    });

    test('album tracks share one lookupKey through the app parser', () {
      String name(int n, String t) => musicFileName(
          artist: 'Artist',
          album: 'Album',
          year: 1990,
          track: n,
          title: t,
          releaseMbid: 'abc',
          ext: 'flac');
      final k1 = parseMediaName(name(1, 'One')).lookupKey;
      final k2 = parseMediaName(name(2, 'Two')).lookupKey;
      expect(k1, k2);
      expect(k1, 'mbid:abc');
    });

    test('generated names round-trip every music field', () {
      final n = musicFileName(
          artist: 'The Rolling Stones',
          album: 'Let It Bleed',
          year: 1969,
          track: 5,
          title: 'Gimme Shelter',
          releaseMbid: 'c07f0676-9d95-4443-a841-b1cbcfa48f4e',
          ext: 'flac');
      final p = parseMediaName(n);
      expect(p.artist, 'The Rolling Stones');
      expect(p.album, 'Let It Bleed');
      expect(p.year, 1969);
      expect(p.track, 5);
      expect(p.trackTitle, 'Gimme Shelter');
      expect(p.releaseMbid, 'c07f0676-9d95-4443-a841-b1cbcfa48f4e');
    });

    test('multi-disc generated names round-trip disc and track', () {
      final n = musicFileName(
          artist: 'A',
          album: 'B',
          year: 2000,
          track: 3,
          disc: 2,
          discTotal: 2,
          title: 'T',
          releaseMbid: 'm0',
          ext: 'flac');
      final p = parseMediaName(n);
      expect(p.disc, 2);
      expect(p.track, 3);
      expect(p.trackTitle, 'T');
    });

    test('long unicode title stays within 255 bytes, tag intact', () {
      final n = musicFileName(
          artist: 'Артист',
          album: 'Альбом',
          year: 2001,
          track: 12,
          title: 'Ноль' * 60,
          releaseMbid: '0f0f0f0f-0000-4000-8000-000000000000',
          ext: 'flac');
      expect(utf8.encode(n).length, lessThanOrEqualTo(255));
      expect(n, endsWith(' {mbid-0f0f0f0f-0000-4000-8000-000000000000}.flac'));
    });
  });

  group('videoFileName round-trips through the app parser', () {
    test('movie with imdb id + resolution', () {
      final n = videoFileName(
          title: 'Night of the Living Dead',
          year: 1968,
          imdbId: 'tt0063350',
          height: 1080,
          ext: 'mp4');
      expect(n,
          'Night of the Living Dead (1968) {imdb-tt0063350} - [1080p].mp4');
      final p = parseMediaName(n);
      expect(p.title, 'Night of the Living Dead');
      expect(p.year, 1968);
      expect(p.imdbId, 'tt0063350');
    });

    test('episode', () {
      final n = videoFileName(
          title: 'One Step Beyond',
          year: 1959,
          imdbId: 'tt0051297',
          season: 1,
          episode: 2,
          ext: 'mkv');
      expect(n, 'One Step Beyond (1959) S01E02 {imdb-tt0051297}.mkv');
      final p = parseMediaName(n);
      expect(p.isEpisode, isTrue);
      expect(p.season, 1);
      expect(p.episode, 2);
      expect(p.imdbId, 'tt0051297');
      expect(p.title, 'One Step Beyond');
      expect(p.year, 1959);
    });

    test('case-B: no id tag', () {
      final n = videoFileName(title: 'Holiday 2024 Video', ext: 'mp4');
      expect(n, 'Holiday 2024 Video.mp4');
    });

    test('sanitized title round-trips', () {
      final n = videoFileName(
          title: 'Movie: The Sequel?', year: 2020, imdbId: 'tt1', ext: 'mp4');
      expect(n, 'Movie - The Sequel (2020) {imdb-tt1}.mp4');
      expect(parseMediaName(n).title, 'Movie - The Sequel');
    });
  });
}
