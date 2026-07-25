import 'package:shared_preferences/shared_preferences.dart';

import 'home_sections.dart';

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

  /// The user's TMDB credential, entered in Settings → Metadata (either a
  /// v3 API key or a v4 Read Access Token). Empty string = metadata
  /// matching disabled. Releases ship no key by design — imported bundles
  /// carry metadata and posters, so casual users never need one.
  static Future<String> tmdbApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tmdbKeyKey)?.trim() ?? '';
  }

  /// Where the credential returned by [tmdbApiKey] comes from. The
  /// settings UI shows this instead of the key itself, so the key is
  /// never displayed once entered.
  static Future<TmdbKeySource> tmdbKeySource() async {
    final key = await tmdbApiKey();
    return key.isNotEmpty ? TmdbKeySource.user : TmdbKeySource.none;
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

  static const _tmdbNudgeDismissedKey = 'tmdb_nudge_dismissed_v1';

  /// Whether the one-time keyless-metadata nudge on the home screen has
  /// been dismissed. Never reset — the Settings tile remains the way in.
  static Future<bool> tmdbNudgeDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_tmdbNudgeDismissedKey) ?? false;
  }

  static Future<void> setTmdbNudgeDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_tmdbNudgeDismissedKey, true);
  }

  static const _downloadDirKey = 'download_dir_v1';

  /// User-chosen downloads folder (desktop only). Null = the app-private
  /// default (`<support>/downloads/`). Applies to new downloads; files
  /// already on disk stay where they are.
  static Future<String?> downloadDirPath() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_downloadDirKey)?.trim() ?? '';
    return path.isEmpty ? null : path;
  }

  static Future<void> setDownloadDirPath(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = path?.trim() ?? '';
    if (trimmed.isEmpty) {
      await prefs.remove(_downloadDirKey);
    } else {
      await prefs.setString(_downloadDirKey, trimmed);
    }
  }

  static const _homeSectionsKey = 'home_sections_v1';

  /// The stored home-row order and special-row visibility, raw. Callers
  /// must pass this through [reconcileHomeSections] against the current
  /// lists before use; an unset or corrupt value decodes to [] (defaults).
  static Future<List<HomeSection>> homeSections() async {
    final prefs = await SharedPreferences.getInstance();
    return decodeHomeSections(prefs.getString(_homeSectionsKey) ?? '');
  }

  static Future<void> setHomeSections(List<HomeSection> sections) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_homeSectionsKey, encodeHomeSections(sections));
  }

  static const _pauseDownloadsOnPlayKey = 'pause_downloads_on_play_v1';

  /// What to do with active downloads when streaming playback starts
  /// (a downloaded file plays locally and never asks). Set directly in
  /// Settings → Downloads, or via "remember my choice" on the playback
  /// prompt.
  static Future<PauseDownloadsOnPlay> pauseDownloadsOnPlay() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_pauseDownloadsOnPlayKey);
    return PauseDownloadsOnPlay.values.asNameMap()[name] ??
        PauseDownloadsOnPlay.ask;
  }

  static Future<void> setPauseDownloadsOnPlay(
      PauseDownloadsOnPlay value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pauseDownloadsOnPlayKey, value.name);
  }
}

/// Origin of the effective TMDB credential.
enum TmdbKeySource { user, none }

/// Whether starting streamed playback pauses active downloads.
enum PauseDownloadsOnPlay { ask, always, never }
