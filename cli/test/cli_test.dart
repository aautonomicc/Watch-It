import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:watchit_naming/watchit_naming.dart';
import 'package:watchit_upload/src/ant.dart';
import 'package:watchit_upload/src/bundle_out.dart';
import 'package:watchit_upload/src/config.dart';
import 'package:watchit_upload/src/ledger.dart';
import 'package:watchit_upload/src/manifest.dart';
import 'package:watchit_upload/src/match.dart';
import 'package:watchit_upload/src/probe.dart';
import 'package:watchit_upload/src/sidecar.dart';
import 'package:watchit_upload/src/tmdb.dart';
import 'package:watchit_upload/src/yaml_write.dart';
import 'package:yaml/yaml.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('wicli'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('yamlDocument', () {
    test('round-trips through a YAML parser', () {
      final value = {
        'version': 1,
        'list_name': "Ella's: weird / list",
        'entries': [
          {
            'source': '/a/b/Movie (2024) {imdb-tt1}.mp4',
            'status': 'ready',
            'size_bytes': 12345,
            'custom': true,
            'description': 'line one\nline two',
            'ids': {'imdb': 'tt1'},
            'year': null,
          },
        ],
        'empty_list': <Object?>[],
        'empty_map': <String, Object?>{},
      };
      final text = yamlDocument(value);
      final back = loadYaml(text);
      expect(back['version'], 1);
      expect(back['list_name'], "Ella's: weird / list");
      expect(back['entries'][0]['source'],
          '/a/b/Movie (2024) {imdb-tt1}.mp4');
      expect(back['entries'][0]['custom'], true);
      expect(back['entries'][0]['description'], 'line one\nline two');
      expect(back['entries'][0]['ids']['imdb'], 'tt1');
      expect(back['entries'][0]['year'], null);
      expect(back['empty_list'], isEmpty);
      expect(back['empty_map'], isEmpty);
    });

    test('typed-looking strings stay strings', () {
      final back = loadYaml(yamlDocument({
        'a': 'true',
        'b': '123',
        'c': '2024-01-01',
        'd': 'null',
      }));
      expect(back['a'], 'true');
      expect(back['b'], '123');
      expect(back['c'], '2024-01-01');
      expect(back['d'], 'null');
    });
  });

  group('manifest', () {
    test('save/load round-trip preserves entries', () {
      final file = File(p.join(tmp.path, 'm.yaml'));
      final m = Manifest(
          file: file,
          listName: 'My Uploads',
          created: '2026-09-01T00:00:00',
          entries: [
            ManifestEntry(source: '/x/a.flac', status: 'ready')
              ..sha256 = 'ab' * 32
              ..sizeBytes = 99
              ..type = 'music'
              ..name = 'A - B (2000) - 01 T {mbid-x}.flac'
              ..ids = {'release_mbid': 'x'}
              ..confidence = 'high',
            ManifestEntry(source: '/x/b.mp4', status: 'needs-attention')
              ..error = 'no match',
          ]);
      m.cost = {'estimated_total_ant': '0.5', 'total_chunks': 6};
      m.save();
      final back = Manifest.load(file);
      expect(back.listName, 'My Uploads');
      expect(back.entries, hasLength(2));
      expect(back.entries[0].name, 'A - B (2000) - 01 T {mbid-x}.flac');
      expect(back.entries[0].ids['release_mbid'], 'x');
      expect(back.entries[0].status, 'ready');
      expect(back.entries[1].status, 'needs-attention');
      expect(back.cost['total_chunks'], 6);
    });
  });

  group('ledger', () {
    test('append + lookup + corrupt-line tolerance', () {
      final file = File(p.join(tmp.path, 'ledger.jsonl'));
      final ledger = Ledger.load(file);
      expect(ledger.length, 0);
      ledger.append(LedgerEntry(
          sha256: 'aa',
          name: 'N.mp4',
          sizeBytes: 5,
          date: '2026-09-01T10:00:00',
          address: 'ff' * 32,
          datamapPath: '/d/N.mp4.datamap'));
      file.writeAsStringSync('not json\n', mode: FileMode.append);
      ledger.append(LedgerEntry(
          sha256: 'bb', name: 'M.flac', sizeBytes: 6, date: 'd'));
      final back = Ledger.load(file);
      expect(back.length, 2);
      expect(back.lookup('aa')!.name, 'N.mp4');
      expect(back.lookup('aa')!.address, 'ff' * 32);
      expect(back.lookup('bb')!.name, 'M.flac');
      expect(back.lookup('cc'), isNull);
    });
  });

  group('ffprobe parsing', () {
    test('music: audio + attached_pic only', () {
      final probe = parseFfprobeJson(jsonEncode({
        'streams': [
          {
            'codec_type': 'audio',
            'tags': {'ARTIST': 'A', 'MusicBrainz Album Id': 'mb-1'},
          },
          {
            'codec_type': 'video',
            'codec_name': 'mjpeg',
            'disposition': {'attached_pic': 1},
          },
        ],
        'format': {
          'duration': '182.5',
          'tags': {'album': 'Z', 'track': '3/10', 'disc': '1/2',
              'date': '1994-05-01'},
        },
      }));
      expect(probe.isMusic, isTrue);
      expect(probe.tag('artist'), 'A');
      expect(probe.releaseMbid, 'mb-1');
      expect(probe.trackNumber, 3);
      expect(probe.trackTotal, 10);
      expect(probe.discTotal, 2);
      expect(probe.year, 1994);
      expect(probe.durationSeconds, closeTo(182.5, 0.01));
    });

    test('video: real video stream', () {
      final probe = parseFfprobeJson(jsonEncode({
        'streams': [
          {'codec_type': 'video', 'codec_name': 'h264',
              'width': 1920, 'height': 1080,
              'disposition': {'attached_pic': 0}},
          {'codec_type': 'audio'},
        ],
        'format': {},
      }));
      expect(probe.isMusic, isFalse);
      expect(probe.height, 1080);
    });
  });

  group('ant JSON parsing', () {
    test('cost shape (observed, ant 0.3.2)', () {
      final cost = parseAntCostJson(
          '{"file_size":100000,"chunk_count":3,'
          '"storage_cost_atto":"134204141601562500",'
          '"estimated_gas_cost_wei":"150000000000000",'
          '"payment_mode":"single","confidence":"priced_sample"}');
      expect(cost, isNotNull);
      expect(cost!.chunkCount, 3);
      expect(cost.storageCostAnt, closeTo(0.1342, 0.001));
    });

    test('chunk maths: 4MiB chunks, 3-chunk floor', () {
      expect(Ant.chunksFor(1), 3);
      expect(Ant.chunksFor(12 << 20), 3);
      expect(Ant.chunksFor((12 << 20) + 1), 4);
      expect(Ant.chunksFor(100 << 20), 25);
    });
  });

  group('sidecar', () {
    test('skeleton is valid YAML and reads back', () {
      final media = p.join(tmp.path, 'Some Song.mp3');
      File(media).writeAsStringSync('x');
      Sidecar.writeSkeleton(media,
          type: 'music',
          artist: "L'Artiste",
          album: 'Al',
          title: 'T',
          track: 2,
          year: 1990,
          note: 'no match');
      final s = Sidecar.read(media);
      expect(s, isNotNull);
      expect(s!.type, 'music');
      expect(s.artist, "L'Artiste");
      expect(s.track, 2);
      expect(s.hasId, isFalse);
      // Empty strings in the skeleton read as null (not manual entry —
      // title is prefilled though, so it counts once user keeps it).
      expect(s.releaseMbid, isNull);
    });

    test('id extraction from URLs and prefixed forms', () {
      final media = p.join(tmp.path, 'm.mp4');
      File(media).writeAsStringSync('x');
      File(Sidecar.pathFor(media)).writeAsStringSync('''
type: video
imdb: https://www.imdb.com/title/tt0063350/
tmdb: tv:1234
''');
      final s = Sidecar.read(media)!;
      expect(s.imdb, 'tt0063350');
      expect(s.tmdb, 1234);
      expect(s.tmdbTv, isTrue);
      expect(s.hasId, isTrue);
    });

    test('mbid extraction from release URL', () {
      final media = p.join(tmp.path, 'm.flac');
      File(media).writeAsStringSync('x');
      File(Sidecar.pathFor(media)).writeAsStringSync('''
type: music
release_mbid: https://musicbrainz.org/release/C07F0676-9D95-4443-A841-B1CBCFA48F4E
track: 5
''');
      final s = Sidecar.read(media)!;
      expect(s.releaseMbid, 'c07f0676-9d95-4443-a841-b1cbcfa48f4e');
      expect(s.track, 5);
    });

    test('skip flag', () {
      final media = p.join(tmp.path, 's.mp4');
      File(media).writeAsStringSync('x');
      File(Sidecar.pathFor(media)).writeAsStringSync('skip: true\n');
      expect(Sidecar.read(media)!.skip, isTrue);
    });
  });

  group('bundle output (spec v2 shape the app imports)', () {
    test('datamaps + list.txt + custom metadata row + poster', () {
      final bytes = buildWatchListBundle(listName: 'Test List', entries: [
        BundleOutEntry(
          name: 'Movie (2024) {imdb-tt1} - [1080p].mp4',
          datamapBytes: Uint8List.fromList([1, 2, 3]),
        ),
        BundleOutEntry(
          name: 'Home Artist - Demos (2025) - 01 First Song.mp3',
          datamapBytes: Uint8List.fromList([4, 5, 6]),
          custom: true,
          description: 'A home demo.',
          artBytes: [9, 9, 9],
          customTitle: 'Home Artist - Demos',
          customYear: 2025,
          mediaType: 'music',
        ),
      ]);
      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      final names = archive.files.map((f) => f.name).toSet();
      expect(
          names,
          containsAll([
            'datamaps/Movie (2024) {imdb-tt1} - [1080p].mp4.datamap',
            'datamaps/Home Artist - Demos (2025) - 01 First Song.mp3'
                '.datamap',
            'list.txt',
            'metadata.json',
          ]));

      final listText = utf8.decode(
          archive.files.firstWhere((f) => f.name == 'list.txt').readBytes()!);
      expect(listText, startsWith('ListName="Test List"\n'));
      expect(listText,
          contains('Movie (2024) {imdb-tt1} - [1080p].mp4.datamap\n'));

      final meta = jsonDecode(utf8.decode(archive.files
          .firstWhere((f) => f.name == 'metadata.json')
          .readBytes()!)) as Map<String, dynamic>;
      expect(meta['version'], 1);
      final rows = (meta['entries'] as List).cast<Map<String, dynamic>>();
      expect(rows, hasLength(1)); // only the custom item
      final row = rows.first;
      // Key must equal what the app's parser derives from the member name.
      expect(
          row['lookupKey'],
          parseMediaName('Home Artist - Demos (2025) - 01 First Song.mp3')
              .lookupKey);
      expect(row['userEdited'], true);
      expect(row['overview'], 'A home demo.');
      expect(row['title'], 'Home Artist - Demos');
      expect(row['year'], 2025);
      expect(row['mediaType'], 'music');
      final posterFile = row['posterFile'] as String;
      expect(names, contains('posters/$posterFile'));
    });

    test('duplicate names get hash suffix (app collision rule)', () {
      final bytes = buildWatchListBundle(listName: 'L', entries: [
        BundleOutEntry(
            name: 'Same.mp4', datamapBytes: Uint8List.fromList([1])),
        BundleOutEntry(
            name: 'Same.mp4', datamapBytes: Uint8List.fromList([2])),
      ]);
      final archive = ZipDecoder().decodeBytes(bytes);
      final maps = archive.files
          .where((f) => f.name.startsWith('datamaps/'))
          .map((f) => f.name)
          .toList();
      expect(maps, hasLength(2));
      expect(maps.toSet(), hasLength(2));
      expect(maps, contains('datamaps/Same.mp4.datamap'));
    });
  });

  group('matching helpers', () {
    test('titleSimilarity', () {
      expect(titleSimilarity('Night of the Living Dead',
              'Night of the Living Dead'), 1);
      expect(titleSimilarity('The Movie', 'the.movie'), 1);
      expect(titleSimilarity('abc', 'xyz'), lessThan(0.5));
      expect(titleSimilarity('Nosferatu', 'Nosferatu the Vampyre'),
          greaterThan(0.3));
    });

    test('guessMusicName filename heuristics', () {
      final g =
          guessMusicName('Pink Floyd - The Wall (1979) - 05 Mother.flac');
      expect(g.artist, 'Pink Floyd');
      expect(g.album, 'The Wall');
      expect(g.track, 5);
      expect(g.title, 'Mother');
      final g2 = guessMusicName('03 - Some Track.mp3');
      expect(g2.track, isNull); // two-part split → artist/title guess
      final g3 = guessMusicName('plain.mp3');
      expect(g3.title, 'plain');
    });

    test('albumGroupKey: mbid beats tags beats filename beats dir', () {
      MediaProbe probe(Map<String, String> tags) =>
          MediaProbe(hasAudio: true, hasRealVideo: false, tags: tags);
      // Embedded release id groups regardless of messy tags.
      expect(albumGroupKey('/x/a.mp3', probe({'musicbrainz_albumid': 'R1'})),
          albumGroupKey('/y/b.flac',
              probe({'musicbrainz_albumid': 'R1', 'album': 'Other'})));
      // Artist/album tags, case-insensitive.
      expect(
          albumGroupKey('/x/a.mp3', probe({'artist': 'Band', 'album': 'Alb'})),
          albumGroupKey('/x/b.mp3', probe({'artist': 'band', 'album': 'ALB'})));
      // album_artist wins over per-track artist (feat. credits).
      expect(
          albumGroupKey(
              '/x/a.mp3',
              probe({
                'album_artist': 'Band',
                'artist': 'Band feat. X',
                'album': 'Alb'
              })),
          albumGroupKey(
              '/x/b.mp3',
              probe({
                'album_artist': 'Band',
                'artist': 'Band',
                'album': 'Alb'
              })));
      // Untagged: the `Artist - Album - NN Title` filename guess.
      expect(albumGroupKey('/x/Band - Alb - 01 One.mp3', null),
          albumGroupKey('/y/Band - Alb - 02 Two.mp3', null));
      // Unparseable + untagged: one folder = one album.
      expect(albumGroupKey('/x/one.mp3', null),
          albumGroupKey('/x/two.mp3', null));
      expect(albumGroupKey('/x/one.mp3', null),
          isNot(albumGroupKey('/z/one.mp3', null)));
      // Different albums never merge.
      expect(
          albumGroupKey('/x/a.mp3', probe({'artist': 'Band', 'album': 'A1'})),
          isNot(albumGroupKey(
              '/x/b.mp3', probe({'artist': 'Band', 'album': 'A2'}))));
    });
  });

  group('config', () {
    test('env beats file, blank means unset', () {
      final home = Directory(p.join(tmp.path, 'cfg'))
        ..createSync(recursive: true);
      File(p.join(home.path, 'config.yaml')).writeAsStringSync('''
tmdb_key: filekey
acoustid_key: ''
''');
      final config = CliConfig.load(
          home: home, env: {'TMDB_API_KEY': 'envkey', 'HOME': tmp.path});
      expect(config.tmdbKey, 'envkey');
      expect(config.acoustidKey, isNull);
      expect(config.serverBase, isNull);
    });
  });
}
