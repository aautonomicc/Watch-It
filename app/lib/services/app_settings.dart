import 'package:shared_preferences/shared_preferences.dart';

import 'home_sections.dart';
import 'library_arrangement.dart';

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

  static const _libraryArrangementKey = 'library_arrangement_v1';

  /// How the browsing surfaces arrange the library (Media Lists page).
  /// Most callers go through [ArrangementStore.instance], which mirrors
  /// this preference and notifies mounted surfaces on change.
  static Future<LibraryArrangement> libraryArrangement() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_libraryArrangementKey);
    return LibraryArrangement.values.asNameMap()[name] ??
        LibraryArrangement.userLists;
  }

  static Future<void> setLibraryArrangement(LibraryArrangement value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_libraryArrangementKey, value.name);
  }

  static const _autoHiddenListsKey = 'auto_hidden_lists_v1';

  /// Ids of the virtual auto-mode lists hidden from home and the drawer
  /// (Media page checkboxes in Auto by type). Independent of the user
  /// lists' `enabled` flag. Most callers go through
  /// [ArrangementStore.instance.hiddenAutoIds].
  static Future<Set<String>> autoHiddenLists() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_autoHiddenListsKey) ?? const []).toSet();
  }

  static Future<void> setAutoHiddenLists(Set<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_autoHiddenListsKey, ids.toList()..sort());
  }

  static const _downloadNetworkKey = 'download_network_v1';

  /// Which networks downloads may use (Settings → Network). Wi-Fi-only
  /// is the default: a queued 5GB movie must never silently eat a
  /// mobile-data allowance. Only enforced where the OS reports a
  /// cellular transport — desktop never gates.
  static Future<DownloadNetworkPolicy> downloadNetworkPolicy() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_downloadNetworkKey);
    return DownloadNetworkPolicy.values.asNameMap()[name] ??
        DownloadNetworkPolicy.wifiOnly;
  }

  static Future<void> setDownloadNetworkPolicy(
      DownloadNetworkPolicy value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_downloadNetworkKey, value.name);
  }

  static const _streamingNetworkKey = 'streaming_network_v1';

  /// What streamed playback does on mobile data (Settings → Network).
  /// Default asks once per session; a downloaded title always plays.
  static Future<StreamingNetworkPolicy> streamingNetworkPolicy() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_streamingNetworkKey);
    return StreamingNetworkPolicy.values.asNameMap()[name] ??
        StreamingNetworkPolicy.ask;
  }

  static Future<void> setStreamingNetworkPolicy(
      StreamingNetworkPolicy value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_streamingNetworkKey, value.name);
  }

  static const _samsungTipDismissedKey = 'samsung_tip_dismissed_v1';

  /// One-time Samsung battery-management tip on Settings → Downloads.
  static Future<bool> samsungTipDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_samsungTipDismissedKey) ?? false;
  }

  static Future<void> setSamsungTipDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_samsungTipDismissedKey, true);
  }

  static const _termsAcceptedKey = 'terms_accepted_version_v1';

  /// The terms version the user accepted on the first-launch gate
  /// (0 = never accepted). The gate shows whenever this is below the
  /// current [kTermsVersion] in services/terms.dart, so bumping that
  /// constant re-prompts everyone after a material change.
  static Future<int> termsAcceptedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_termsAcceptedKey) ?? 0;
  }

  static Future<void> setTermsAccepted(int version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_termsAcceptedKey, version);
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

/// Which networks downloads may use.
enum DownloadNetworkPolicy { wifiOnly, any }

/// What streamed playback does on mobile data.
enum StreamingNetworkPolicy { ask, allow, wifiOnly }

/// Whether starting streamed playback pauses active downloads.
enum PauseDownloadsOnPlay { ask, always, never }
