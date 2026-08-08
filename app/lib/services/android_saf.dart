import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Android save-file support. `file_selector_android` implements no save
/// dialog at all (`getSavePath` throws "has not been implemented"), so
/// exports go through the system's own Create-Document (SAF) dialog via
/// a small MethodChannel in MainActivity. The bytes travel by temp file
/// — a ~200MB bundle should not be copied through the channel codec —
/// and the native side streams that file into the content URI the user
/// picked.
class AndroidSaf {
  static const MethodChannel _channel = MethodChannel('watchit/export');

  /// Show the system "create document" dialog and write [bytes] to the
  /// location the user picks. Returns the saved file's display name, or
  /// null when the user cancels the dialog. Throws [PlatformException]
  /// when the write itself fails.
  static Future<String?> saveFile(
    Uint8List bytes, {
    required String fileName,
    required String mimeType,
  }) async {
    final dir = await getTemporaryDirectory();
    final tmp = File('${dir.path}${Platform.pathSeparator}'
        'export-${DateTime.now().microsecondsSinceEpoch}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    try {
      // Completes only after the native side finished (or the user
      // cancelled), so the temp file outlives the copy.
      return await _channel.invokeMethod<String>('saveFile', {
        'path': tmp.path,
        'fileName': fileName,
        'mimeType': mimeType,
      });
    } finally {
      unawaited(
          tmp.delete().then<void>((_) {}, onError: (Object _) {}));
    }
  }
}
