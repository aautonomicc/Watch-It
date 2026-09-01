/// Shared media file-name parsing, sanitization, and generation.
///
/// The app (`app/lib/services/metadata.dart`) re-exports [parseMediaName]
/// from here; the upload CLI generates names with [musicFileName] /
/// [videoFileName] built on [sanitizeNamePart]. Because both sides import
/// the same functions, a name the CLI writes always parses back to the
/// intended title/year/ids in the app.
library;

export 'src/parse.dart';
export 'src/sanitize.dart';
export 'src/generate.dart';
