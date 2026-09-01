import 'dart:io';

import 'package:watchit_upload/src/ledger_cmd.dart';
import 'package:watchit_upload/src/prepare.dart';
import 'package:watchit_upload/src/upload.dart';

const _usage = '''
watchit-upload — bulk-upload media to Autonomi with canonical W@tch names

Usage:
  watchit-upload prepare [--manifest PATH] [--list-name NAME] [--yes]
                         [--music|--video] <files/folders…>
      Interactive phase: scan, dedupe against the upload ledger, match
      against MusicBrainz/TMDB, regenerate canonical names, fetch art,
      write sidecar skeletons for failures, estimate cost. Pays nothing.

  watchit-upload upload  [--manifest PATH] [--no-verify] [--no-telegram]
                         [--no-bundle]
      Unattended phase: upload every `ready` entry (needs SECRET_KEY for
      ant's wallet), resumable after crash, ledger appended per file,
      .watch-list bundle emitted, Telegram ping on completion.

  watchit-upload ledger list
  watchit-upload ledger export [--out PATH] [--list-name NAME]
                               [--match SUBSTRING]
      Inspect the content-hash ledger / rebuild a bundle offline from it.

Config: ~/.watchit-upload/config.yaml
  tmdb_key: …       # TMDB v3 key or v4 read token (video matching)
  acoustid_key: …   # free key from acoustid.org (audio fingerprinting;
                    # also needs `fpcalc` from chromaprint on PATH)
  server_base: http://127.0.0.1:PORT   # running watchit_core devserver,
                    # enables the post-upload get_range retrievability check
Sidecars: <media file>.watchit.yaml override/curate any match; `prepare`
writes pre-filled skeletons for files it cannot match. Docs:
docs/UPLOAD-CLI.md in the Watch-It repo.
''';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args[0] == '--help' || args[0] == '-h') {
    stdout.write(_usage);
    exit(args.isEmpty ? 2 : 0);
  }
  final rest = args.sublist(1);
  final code = switch (args[0]) {
    'prepare' => await runPrepare(rest),
    'upload' => await runUpload(rest),
    'ledger' => await runLedger(rest),
    _ => () {
        stderr.writeln('unknown command: ${args[0]}\n');
        stderr.write(_usage);
        return 2;
      }(),
  };
  exit(code);
}
