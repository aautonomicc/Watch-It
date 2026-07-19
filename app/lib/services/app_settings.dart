import 'package:shared_preferences/shared_preferences.dart';

/// App-wide user preferences (playback tuning etc.), separate from the
/// media library which lives in [LibraryStore].
class AppSettings {
  static const _bufferSizeKey = 'buffer_size_mb_v1';

  /// mpv demuxer cache cap in MB. media_kit applies this to both the
  /// forward and back buffers (demuxer-max-bytes / demuxer-max-back-bytes),
  /// so worst-case playback memory is roughly double this value.
  static const defaultBufferSizeMb = 32;
  static const bufferSizeOptionsMb = [16, 32, 64, 128, 256];

  static Future<int> bufferSizeMb() async {
    final prefs = await SharedPreferences.getInstance();
    final mb = prefs.getInt(_bufferSizeKey) ?? defaultBufferSizeMb;
    return bufferSizeOptionsMb.contains(mb) ? mb : defaultBufferSizeMb;
  }

  static Future<void> setBufferSizeMb(int mb) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_bufferSizeKey, mb);
  }
}
