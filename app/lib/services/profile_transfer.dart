import 'dart:convert';

import 'package:drift/drift.dart' hide Column;

import '../db/app_database.dart';
import '../models/media_list.dart';
import 'library_store.dart';
import 'profiles.dart';
import 'watch_state.dart';

/// Family export/import: the whole set of viewing profiles rides a
/// library export as one optional `profiles.json` zip member (plus the
/// profiles' file avatars under `profiles/`), and imports back with a
/// merge-BY-NAME where the DEVICE always wins — an import can fill gaps
/// (a missing PIN, a missing avatar, a new profile) but never overrides
/// what the device already has. Agreed rules (2026-09-09):
///
/// - profiles match by (case-insensitive) name; the Admin profile always
///   matches the device's Admin (every install has exactly one);
/// - on a match the device keeps its name/kind/avatar/position; the
///   backup's PIN is used only when the device profile has none, and the
///   ADMIN PIN only together with its recovery-code hash (they are a
///   pair — adopting the PIN alone would break "Forgot PIN?");
/// - a kid's allowed lists are the UNION of both sides (titles resolve
///   against the just-imported library);
/// - auto-login transfers only when no device profile has it;
/// - per-profile watch history merges newest-updatedAt-wins, keyed by
///   `.datamap` member name exactly like history.json (no bare
///   addresses in the export);
/// - unmatched backup profiles become new profiles with fresh ids (file
///   avatars re-saved under the new id).
///
/// Importers older than this feature ignore the members entirely
/// (unknown zip members always have) — a family export stays a valid
/// plain library bundle everywhere.

/// One history row inside a profile's export — structurally identical
/// to bundle.dart's BundleHistoryRow (kept separate only to avoid a
/// circular import).
typedef ProfileHistoryRow = ({
  int positionMs,
  int durationMs,
  bool completed,
  int updatedAt,
});

/// The exact file-name shape ProfileStore writes avatars under; a
/// hostile member name must not escape anywhere, so nothing else is
/// accepted out of `profiles/`.
final _avatarMemberPattern =
    RegExp(r'^profile_avatar_[A-Za-z0-9]+_\d+\.img$');
bool isProfileAvatarMemberName(String name) =>
    _avatarMemberPattern.hasMatch(name);

/// One profile as it travels in profiles.json.
class BundleProfile {
  const BundleProfile({
    required this.name,
    required this.kind,
    this.avatar,
    this.pinHash,
    this.autoLogin = false,
    this.allowedLists = const [],
    this.historyByMember = const {},
  });

  final String name;

  /// 'admin' | 'adult' | 'kid'; anything else imports as adult.
  final String kind;

  /// `preset:<n>` or a `profiles/` avatar member base name.
  final String? avatar;

  /// `<salt-hex>:<sha256-hex>`; null = no PIN.
  final String? pinHash;
  final bool autoLogin;

  /// List TITLES (kid allow-list) — ids differ across devices, titles
  /// are how the import merges lists too.
  final List<String> allowedLists;

  /// This profile's watch states, keyed by `.datamap` member name.
  final Map<String, ProfileHistoryRow> historyByMember;

  bool get isAdmin => kind == ProfileKind.admin.name;
}

/// A parsed profiles.json member.
class ParsedProfiles {
  const ParsedProfiles({required this.profiles, this.adminRecovery});

  final List<BundleProfile> profiles;

  /// The hashed admin recovery code (`<salt>:<sha256>`), exported beside
  /// the admin PIN so "Forgot PIN?" survives the move.
  final String? adminRecovery;
}

/// What [buildProfilesExport] produced: the profiles.json text plus the
/// file-avatar bytes to write under `profiles/`.
class ProfilesExportData {
  const ProfilesExportData({required this.json, required this.avatarFiles});

  final String json;
  final Map<String, Uint8List> avatarFiles;
}

/// What [importProfilesData] did (for the import snackbar).
class ProfileImportSummary {
  int merged = 0;
  int added = 0;
  int historyMerged = 0;
  bool adminPinAdopted = false;
}

/// A stored PIN/recovery hash is `<salt-hex>:<sha256-hex>` — anything
/// else in an imported file is junk and is dropped.
String? _validHash(Object? value) {
  if (value is! String) return null;
  final i = value.indexOf(':');
  return i > 0 && i < value.length - 1 ? value : null;
}

/// Gather everything profiles.json carries: the profile rows, kid
/// allow-lists as titles, per-profile watch states for the exported
/// entries (keyed by `.datamap` member via [memberByAddr], same privacy
/// rule as history.json), the admin recovery-code hash, and the bytes
/// of any file avatars.
Future<ProfilesExportData> buildProfilesExport({
  required Map<String, String> memberByAddr,
}) async {
  final db = await LibraryStore.database();
  final rows = await (db.select(db.profiles)
        ..orderBy([(t) => OrderingTerm.asc(t.position)]))
      .get();
  final access = await db.select(db.profileListAccess).get();
  final listTitleById = {
    for (final l in await db.select(db.mediaLists).get()) l.id: l.title,
  };
  final states = memberByAddr.isEmpty
      ? <WatchStateRow>[]
      : await (db.select(db.watchStates)
            ..where((t) => t.address.isIn(memberByAddr.keys)))
          .get();
  final statesByProfile = <String, List<WatchStateRow>>{};
  for (final s in states) {
    (statesByProfile[s.profileId] ??= []).add(s);
  }

  final avatarFiles = <String, Uint8List>{};
  final profiles = <Map<String, dynamic>>[];
  for (final row in rows) {
    var avatar = row.avatar;
    if (avatar != null && !avatar.startsWith('preset:')) {
      final file = await ProfileStore.avatarFile(avatar);
      if (file == null) {
        avatar = null; // file gone — export as initial-letter
      } else {
        avatarFiles[avatar] = await file.readAsBytes();
      }
    }
    profiles.add({
      'name': row.name,
      'kind': row.kind,
      'avatar': avatar,
      'pinHash': row.pinHash,
      'autoLogin': row.autoLogin,
      'allowedLists': [
        for (final a in access)
          if (a.profileId == row.id && listTitleById[a.listId] != null)
            listTitleById[a.listId],
      ],
      'history': [
        for (final s in statesByProfile[row.id] ?? const <WatchStateRow>[])
          {
            'member': memberByAddr[s.address],
            'positionMs': s.positionMs,
            'durationMs': s.durationMs,
            'completed': s.completed,
            'updatedAt': s.updatedAt,
          },
      ],
    });
  }
  return ProfilesExportData(
    json: jsonEncode({
      'version': 1,
      'profiles': profiles,
      'adminRecovery': await ProfileStore.instance.adminRecoveryHash(),
    }),
    avatarFiles: avatarFiles,
  );
}

/// Parse a profiles.json member. Malformed rows are dropped; a file
/// with no usable profile parses to null so the import treats the
/// bundle as profile-less. Throws only on non-JSON (callers catch).
ParsedProfiles? parseProfilesJson(String jsonText) {
  final decoded = jsonDecode(jsonText);
  if (decoded is! Map<String, dynamic>) return null;
  final profiles = <BundleProfile>[];
  final raw = decoded['profiles'];
  if (raw is! List) return null;
  for (final entry in raw) {
    if (entry is! Map<String, dynamic>) continue;
    final name = entry['name'];
    if (name is! String || name.trim().isEmpty) continue;
    final avatar = entry['avatar'];
    final history = <String, ProfileHistoryRow>{};
    final rawHistory = entry['history'];
    if (rawHistory is List) {
      for (final h in rawHistory) {
        if (h is! Map<String, dynamic>) continue;
        final member = h['member'];
        if (member is String && member.isNotEmpty) {
          history[member] = (
            positionMs: h['positionMs'] as int? ?? 0,
            durationMs: h['durationMs'] as int? ?? 0,
            completed: h['completed'] as bool? ?? false,
            updatedAt: h['updatedAt'] as int? ?? 0,
          );
        }
      }
    }
    profiles.add(BundleProfile(
      name: name.trim(),
      kind: entry['kind'] is String ? entry['kind'] as String : 'adult',
      avatar: avatar is String && avatar.isNotEmpty ? avatar : null,
      pinHash: _validHash(entry['pinHash']),
      autoLogin: entry['autoLogin'] as bool? ?? false,
      allowedLists: [
        if (entry['allowedLists'] is List)
          for (final t in entry['allowedLists'] as List)
            if (t is String && t.isNotEmpty) t,
      ],
      historyByMember: history,
    ));
  }
  if (profiles.isEmpty) return null;
  return ParsedProfiles(
    profiles: profiles,
    adminRecovery: _validHash(decoded['adminRecovery']),
  );
}

/// Merge imported profiles into the device per the header rules.
/// [addressByMember] resolves history members to addresses (from
/// [BundleImportResult]); [lists] is the library AFTER the list import,
/// so kid allow-list titles resolve to the merged lists' real ids.
Future<ProfileImportSummary> importProfilesData(
  ParsedProfiles data,
  Map<String, Uint8List> avatars, {
  required Map<String, String> addressByMember,
  required List<MediaList> lists,
}) async {
  final summary = ProfileImportSummary();
  final store = ProfileStore.instance;
  await store.ensureLoaded();
  final listIdByTitle = {
    for (final l in lists) l.title.toLowerCase(): l.id,
  };
  Set<String> resolveLists(List<String> titles) => {
        for (final t in titles)
          if (listIdByTitle[t.toLowerCase()] != null)
            listIdByTitle[t.toLowerCase()]!,
      };
  // At most one profile auto-selects at launch — a device designation
  // always beats the backup's.
  var hasAutoLogin = store.profiles.any((p) => p.autoLogin);

  Future<void> mergeHistory(BundleProfile source, String targetId) async {
    final states = <WatchState>[
      for (final e in source.historyByMember.entries)
        if (addressByMember[e.key] != null)
          WatchState(
            address: addressByMember[e.key]!,
            positionMs: e.value.positionMs,
            durationMs: e.value.durationMs,
            completed: e.value.completed,
            updatedAt: e.value.updatedAt,
          ),
    ];
    if (states.isNotEmpty) {
      summary.historyMerged +=
          await WatchStateStore.instance.mergeAll(states, profileId: targetId);
    }
  }

  Future<String?> savedAvatar(String? member, String profileId) async {
    if (member == null) return null;
    if (member.startsWith('preset:')) return member;
    final bytes = avatars[member];
    if (bytes == null) return null;
    return ProfileStore.saveAvatarImage(profileId, bytes);
  }

  for (final backup in data.profiles) {
    // The Admin always collides (every install has one, whatever it is
    // named); everyone else matches by name.
    final target = backup.isAdmin
        ? store.adminProfile
        : store.profiles
            .where((p) =>
                !p.isAdmin &&
                p.name.toLowerCase() == backup.name.toLowerCase())
            .firstOrNull;

    if (target != null) {
      // Collision: device wins name/kind/avatar/position; the backup
      // only fills gaps.
      var updated = target;
      if (target.pinHash == null && backup.pinHash != null) {
        if (backup.isAdmin) {
          // The admin PIN and its recovery code are a pair — adopting
          // the PIN without the code would strand "Forgot PIN?".
          if (data.adminRecovery != null) {
            await store.adoptAdminPinPair(
                backup.pinHash!, data.adminRecovery!);
            summary.adminPinAdopted = true;
            updated = store.profiles.firstWhere((p) => p.id == target.id);
          }
        } else {
          updated = updated.copyWith(pinHash: backup.pinHash);
          await store.updateProfile(updated);
        }
      }
      if (target.avatar == null && backup.avatar != null) {
        final avatar = await savedAvatar(backup.avatar, target.id);
        if (avatar != null) {
          updated = updated.copyWith(avatar: avatar);
          await store.updateProfile(updated);
        }
      }
      if (!hasAutoLogin && backup.autoLogin) {
        await store.setAutoLogin(target.id);
        hasAutoLogin = true;
      }
      if (updated.isKid && backup.allowedLists.isNotEmpty) {
        final existing = await store.allowedListIds(target.id);
        final union = {...existing, ...resolveLists(backup.allowedLists)};
        if (union.length > existing.length) {
          await store.setAllowedListIds(target.id, union);
        }
      }
      await mergeHistory(backup, target.id);
      summary.merged++;
      continue;
    }

    // New profile: fresh id, backup fields carried over. Kind can never
    // be admin here (the admin branch above always matches).
    final kind =
        ProfileKind.values.asNameMap()[backup.kind] ?? ProfileKind.adult;
    final profile = await store.create(
      name: backup.name,
      kind: kind == ProfileKind.admin ? ProfileKind.adult : kind,
      avatar: backup.avatar?.startsWith('preset:') ?? false
          ? backup.avatar
          : null,
      allowedLists:
          kind == ProfileKind.kid ? resolveLists(backup.allowedLists) : {},
    );
    var created = profile;
    if (backup.pinHash != null) {
      created = created.copyWith(pinHash: backup.pinHash);
      await store.updateProfile(created);
    }
    if (backup.avatar != null && !backup.avatar!.startsWith('preset:')) {
      final avatar = await savedAvatar(backup.avatar, profile.id);
      if (avatar != null) {
        created = created.copyWith(avatar: avatar);
        await store.updateProfile(created);
      }
    }
    if (!hasAutoLogin && backup.autoLogin) {
      await store.setAutoLogin(profile.id);
      hasAutoLogin = true;
    }
    await mergeHistory(backup, profile.id);
    summary.added++;
  }
  return summary;
}
