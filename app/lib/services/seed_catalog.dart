// GENERATED from the public-domain uploads in ~/Public domain (see
// docs/SEED-CATALOG.md) — addresses derived by POST /datamap from each
// upload's ant-cli .datamap file; regenerate rather than hand-edit.

import 'metadata.dart';

/// One entry of the built-in seed catalog: the media file name as stored
/// on the network (feeds the NAMING.md parser / TMDB matcher) and its
/// derived address, whose root map ships as a bundled asset
/// (assets/rootmaps/<address>.map), plus the upload's exact size and
/// probed video format (ffprobe of the source files — NOT the name's
/// quality tag, which is wrong on some archive.org sources: the NOTLD
/// and Lady Vanishes uploads say `[1080p]` but are really 480p).
class SeedEntry {
  const SeedEntry(
    this.name,
    this.address, {
    required this.sizeBytes,
    required this.videoInfo,
  });

  final String name;
  final String address;

  /// Exact size of the uploaded file in bytes.
  final int sizeBytes;

  /// `480p H.264` — resolution ladder label + codec of the upload.
  final String videoInfo;
}

/// A list the seed catalog creates (or merges into, matched by [id]) on
/// first run — see [LibraryStore.ensureDefaults].
class SeedList {
  const SeedList(
      {required this.id, required this.title, required this.entries});
  final String id;
  final String title;
  final List<SeedEntry> entries;
}

/// The built-in public-domain catalog seeded on first run: 10 movies and
/// 38 TV episodes, all verified public-domain (uploaded 2026-08-07 from
/// archive.org sources; PD basis documented per title in the uploader's
/// README). The Movies list reuses the pre-v4 default list id so
/// upgraded installs merge into their existing list.
const kSeedLists = <SeedList>[
  SeedList(id: 'default-test-movies', title: 'Movies', entries: [
    SeedEntry(
      kDefaultMovieName,
      kDefaultMovieAddress,
      sizeBytes: 597585042,
      videoInfo: '480p H.264',
    ),
    SeedEntry(
      'Battleship Potemkin (1925) {imdb-tt0015648}.mp4',
      '012dec733a59182ecce81639c9bd88ca50b23c6cad32273816a99fc37c4e3471',
      sizeBytes: 1406275936,
      videoInfo: '720p H.264',
    ),
    SeedEntry(
      'Charade (1963) {imdb-tt0056923}.mp4',
      'e71a892edf8675edb8f5944b2750fa5a82a5e408cf8057a0581510dca4c09fe7',
      sizeBytes: 658694689,
      videoInfo: '480p H.264',
    ),
    SeedEntry(
      'His Girl Friday (1940) {imdb-tt0032599}.mp4',
      '03e9078eed778acbde55ec0760665cf3c14bc4899edbe2d4f98d0a32df9a9fc0',
      sizeBytes: 575274912,
      videoInfo: '480p H.264',
    ),
    SeedEntry(
      'Nanook of the North (1922) {imdb-tt0013427}.mp4',
      '1dc414a2e1205caee69224408637a98ad83e909a86e5019ef3ce9f9b6e6ea0fb',
      sizeBytes: 486316987,
      videoInfo: '480p H.264',
    ),
    SeedEntry(
      'Nosferatu (1922) {imdb-tt0013442}.mp4',
      '9be87d1a3c66186a2962c312c0b7adc75d55848c0b7ddd2f4b1ca39197c46d10',
      sizeBytes: 574390206,
      videoInfo: '480p H.264',
    ),
    SeedEntry(
      'The Cabinet of Dr. Caligari (1920) {imdb-tt0010323}.mp4',
      '89030ede762647ce2845aa7117dcabc976faa5171a2bbfcd667c7c972507d9b4',
      sizeBytes: 338924934,
      videoInfo: '480p H.264',
    ),
    SeedEntry(
      'The General (1926) {imdb-tt0017925}.mp4',
      '3c4a2ba12d4ffb93f6c936d4667d3d1ab6d58da22132de902f93ede6a652c792',
      sizeBytes: 412400222,
      videoInfo: '480p H.264',
    ),
    SeedEntry(
      'The Hunchback of Notre Dame (1939) {imdb-tt0031455} - [1080p].mp4',
      '84f8814db278d9ca81393efcfa018bd132092dd490cce105bd223de8b4fe46a6',
      sizeBytes: 2088102883,
      videoInfo: '1080p H.264',
    ),
    SeedEntry(
      'The Lady Vanishes (1938) {imdb-tt0030341} - [1080p].mp4',
      'dda9e302e5dccf1f703c68dff8ddf2c6f285c5950032bfed2f18d7a269013d7a',
      sizeBytes: 562400778,
      videoInfo: '480p H.264',
    ),
  ]),
  SeedList(id: 'default-petticoat-junction', title: 'Petticoat Junction', entries: [
    SeedEntry(
      'Petticoat Junction S01E01.mp4',
      '35569dde9277e05b43df3d9027624832d5f353df7a3fbb99f99044136bc8d4b9',
      sizeBytes: 121335419,
      videoInfo: '360p H.264',
    ),
    SeedEntry(
      'Petticoat Junction S01E02.mp4',
      'c412eda26c6c7cf408692e41f0202e54db5fb170053529e83f94bf93103b62ac',
      sizeBytes: 127692790,
      videoInfo: '360p H.264',
    ),
    SeedEntry(
      'Petticoat Junction S01E03.mp4',
      'a6dabbf8a16bf314488903a98f9b0b2ae2b321177b029856191d41f02cc36cae',
      sizeBytes: 125458916,
      videoInfo: '360p H.264',
    ),
    SeedEntry(
      'Petticoat Junction S01E04.mp4',
      '298db9989a05d4cf60b578a2373b62055a3e36812a27878bbdab7259d327cf2b',
      sizeBytes: 127422136,
      videoInfo: '360p H.264',
    ),
    SeedEntry(
      'Petticoat Junction S01E05.mp4',
      '6b381985dd71d1bd3273963a45d27cb6dc4bb7a5912f269ba609e0e91c6ae89c',
      sizeBytes: 125772000,
      videoInfo: '360p H.264',
    ),
    SeedEntry(
      'Petticoat Junction S01E06.mp4',
      '44142e2c67e52eac87f1d462080c78df8709abe0b9c7b011c9db48078778d501',
      sizeBytes: 132682316,
      videoInfo: '360p H.264',
    ),
    SeedEntry(
      'Petticoat Junction S01E07.mp4',
      '6be84c562f53ec3dbe92d91249b1f239afda7a2357121f2acba8b144e81c61d3',
      sizeBytes: 129995418,
      videoInfo: '360p H.264',
    ),
    SeedEntry(
      'Petticoat Junction S01E08.mp4',
      'd678c4c8d3b841730b47ea6a2035a8dec24c2ef75c727974e60cef47baf031e7',
      sizeBytes: 119050025,
      videoInfo: '360p H.264',
    ),
    SeedEntry(
      'Petticoat Junction S01E09.mp4',
      '36bb31fa003b58866c3d59315054ada62b2c2691cc3f4ce45bc05e5c146d6797',
      sizeBytes: 131912782,
      videoInfo: '360p H.264',
    ),
    SeedEntry(
      'Petticoat Junction S01E10.mp4',
      '8470e45a1cda9ac87e96af871393fa4088177dbebb3ef90cce29b87fe7de6bd8',
      sizeBytes: 124646569,
      videoInfo: '360p H.264',
    ),
    SeedEntry(
      'Petticoat Junction S01E11.mp4',
      'db1228f8121dcfb7560b32e577f54a39e470a76866f2607811da87b8fcb0d751',
      sizeBytes: 122464632,
      videoInfo: '360p H.264',
    ),
    SeedEntry(
      'Petticoat Junction S01E12.mp4',
      'c6a8a84f4f6f3ba41ba684f5743c18837365c1b413ad4f372f2c30ce317893a2',
      sizeBytes: 123796934,
      videoInfo: '360p H.264',
    ),
    SeedEntry(
      'Petticoat Junction S01E13.mp4',
      '2653b0e9ce173ed5b32bf5486a83299a30ad2088eb1c271c02b6162d81a4adfb',
      sizeBytes: 120606089,
      videoInfo: '360p H.264',
    ),
    SeedEntry(
      'Petticoat Junction S01E14.mp4',
      '19c793bd5f51b692c58290f5158d0c0a247e763ac62fa14b224831e5e59823ba',
      sizeBytes: 117805133,
      videoInfo: '360p H.264',
    ),
    SeedEntry(
      'Petticoat Junction S01E15.mp4',
      '73eff6b5d20294837b2a7fc51789bfd04ff889eeb750989768c52b2f63c6cb1f',
      sizeBytes: 108565648,
      videoInfo: '360p H.264',
    ),
    SeedEntry(
      'Petticoat Junction S01E16.mp4',
      'cd432e6fdb7b2bef04b82f2e7492e98be758c6f1a953ae960d75b6974e8c3bd7',
      sizeBytes: 105261462,
      videoInfo: '360p H.264',
    ),
    SeedEntry(
      'Petticoat Junction S01E17.mp4',
      '5483fda9b7c346d0c60b40ec4b46c5a53569756b9fac26c5b18a2362cc1555d2',
      sizeBytes: 116478737,
      videoInfo: '360p H.264',
    ),
    SeedEntry(
      'Petticoat Junction S01E18.mp4',
      'de1c0f38b30234a34fba17989540e426bde77d6272f97cc343832079f9bdbfa3',
      sizeBytes: 117694299,
      videoInfo: '360p H.264',
    ),
    SeedEntry(
      'Petticoat Junction S01E19.mp4',
      '823df698eb8b809e5f13527697f2488d5a72ec4f2ae28afda072437b0194a9b8',
      sizeBytes: 101162218,
      videoInfo: '360p H.264',
    ),
    SeedEntry(
      'Petticoat Junction S01E20.mp4',
      'a6d8bfaf9cbb9be5e0efb25b7b61cc47d07e185a37b57f5e436317cfb99b12de',
      sizeBytes: 122580646,
      videoInfo: '360p H.264',
    ),
    SeedEntry(
      'Petticoat Junction S01E21.mp4',
      '99bf4f8c51efd751f062573a59a54d36d42ef67e96bca9a2a159a7641cd8ab62',
      sizeBytes: 114506460,
      videoInfo: '360p H.264',
    ),
  ]),
  SeedList(id: 'default-one-step-beyond', title: 'One Step Beyond', entries: [
    SeedEntry(
      'One Step Beyond S01E01.mp4',
      '7e9615e25b1366cef8e35260b612c71599836265dbce88371cbbd7bd54063142',
      sizeBytes: 79190883,
      videoInfo: '360p H.264',
    ),
    SeedEntry(
      'One Step Beyond S01E02.mp4',
      'e8692338f406117205f00cb0d3de82c43fa2eccff409a360890894219195b5dc',
      sizeBytes: 522088714,
      videoInfo: '720p H.264',
    ),
    SeedEntry(
      'One Step Beyond S01E06.mp4',
      '0966c3584f20ab862b3e83977853a3f593ecb3da4a481ac6f4752b5df7b0354a',
      sizeBytes: 501400964,
      videoInfo: '720p H.264',
    ),
    SeedEntry(
      'One Step Beyond S01E07.mp4',
      '3a95151801af032e4efdfbe0586d575d04877ff42c41f0e5839707dc46bb9a6d',
      sizeBytes: 507453679,
      videoInfo: '720p H.264',
    ),
    SeedEntry(
      'One Step Beyond S01E09.mp4',
      '492e7c2e03dacfee1a7419516b2367e1b724b68c6ee93d5a143ce29758548876',
      sizeBytes: 505708093,
      videoInfo: '720p H.264',
    ),
    SeedEntry(
      'One Step Beyond S01E10.mp4',
      '3c311ffcd3c585c766b16e71a21566df58f8a7c57ee89350bb74b131d19882f3',
      sizeBytes: 498610476,
      videoInfo: '720p H.264',
    ),
    SeedEntry(
      'One Step Beyond S01E11.mp4',
      '7f7180d8f51d936e173ba67370630623e97ecd41e20341d94ac6a846696e366a',
      sizeBytes: 472062924,
      videoInfo: '720p H.264',
    ),
    SeedEntry(
      'One Step Beyond S01E12.mp4',
      '5b505e372357a33a6848783ab245ef84b7e73220d1a047386edf3996c4a51ee8',
      sizeBytes: 503351536,
      videoInfo: '720p H.264',
    ),
    SeedEntry(
      'One Step Beyond S01E14.mp4',
      '6dc1e8cf0923d404ff5451e7854ee52123744ad06ca59134167632ac3d04b9e6',
      sizeBytes: 495778782,
      videoInfo: '720p H.264',
    ),
    SeedEntry(
      'One Step Beyond S01E15.mp4',
      '54a43a4aa8b979470a8af510688c890a39d261025efd124232673edd64c1d647',
      sizeBytes: 488620674,
      videoInfo: '720p H.264',
    ),
    SeedEntry(
      'One Step Beyond S01E16.mp4',
      '3411f332419d023a306c484333e6971b1ce1d9778183c9267c351be2af3dd49d',
      sizeBytes: 497129343,
      videoInfo: '720p H.264',
    ),
    SeedEntry(
      'One Step Beyond S02E15.mp4',
      '162f0cff5b420ea7e35fe79c1c8a922063689a843f6fb539d020d85cac86152c',
      sizeBytes: 487638062,
      videoInfo: '720p H.264',
    ),
    SeedEntry(
      'One Step Beyond S02E23.mp4',
      '9b39546b0098c0ed7385b135e73a086867d347e7974873a0c1b12bd0474c379b',
      sizeBytes: 495500008,
      videoInfo: '720p H.264',
    ),
    SeedEntry(
      'One Step Beyond S02E24.mp4',
      '7e3ec0f19233cac8b8f27a4915d228ccf5d42879ac32e42329ab4538136d0d2b',
      sizeBytes: 500481213,
      videoInfo: '720p H.264',
    ),
    SeedEntry(
      'One Step Beyond S02E35.mp4',
      'e858f145b71a7845c303f44deb71380260a2af180757eddd74cc4d5a204d608d',
      sizeBytes: 450396564,
      videoInfo: '720p H.264',
    ),
    SeedEntry(
      'One Step Beyond S02E37.mp4',
      '0e9a02d219599f97d4edb0c9a7148a56c87d9ab3d2e3bc42a669f6fc2280c06d',
      sizeBytes: 503688246,
      videoInfo: '720p H.264',
    ),
    SeedEntry(
      'One Step Beyond S02E38.mp4',
      'd2f46208c7de0554fa0637952486af005f06e867f164c4e58a301a82090c5d6a',
      sizeBytes: 497608870,
      videoInfo: '720p H.264',
    ),
  ]),
];
