/// Public surface of the upload pipeline — everything below the three
/// CLI orchestrators (`prepare`/`upload`/`ledger`) is UI-agnostic pure
/// Dart, shared since 2026-09-01 with the desktop app's in-app batch
/// uploader (app/lib/services/batch_upload.dart). The CLI keeps the
/// terminal front-end; the app swaps the `ant` CLI + SECRET_KEY layer
/// for its embedded core's authed `/upload` + keychain wallet.
library;

export 'src/ant.dart' show Ant;
export 'src/bundle_out.dart';
export 'src/config.dart';
export 'src/ledger.dart';
export 'src/manifest.dart';
export 'src/match.dart';
export 'src/musicbrainz.dart';
export 'src/prepare.dart'
    show collectMediaFiles, cueSiblingProblem, sha256OfFile;
export 'src/probe.dart';
export 'src/sidecar.dart';
export 'src/tmdb.dart';
