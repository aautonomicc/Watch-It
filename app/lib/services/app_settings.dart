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

  static const _tmdbKeyKey = 'tmdb_api_key_v1';

  /// Build-time default TMDB credential
  /// (`flutter build --dart-define=TMDB_API_KEY=…`); empty in normal
  /// builds — users bring their own key via Settings. Accepts either a
  /// v3 API key or a v4 Read Access Token.
  static const bundledTmdbApiKey = String.fromEnvironment('TMDB_API_KEY');

  /// The user's TMDB credential, falling back to [bundledTmdbApiKey].
  /// Empty string = metadata matching disabled.
  static Future<String> tmdbApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_tmdbKeyKey)?.trim() ?? '';
    return key.isNotEmpty ? key : bundledTmdbApiKey;
  }

  static Future<void> setTmdbApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await prefs.remove(_tmdbKeyKey);
    } else {
      await prefs.setString(_tmdbKeyKey, trimmed);
    }
  }
}
