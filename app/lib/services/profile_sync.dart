import '../models/media_list.dart';
import 'my_watch_api.dart';
import 'profiles.dart';
import 'watch_state.dart';

/// My W@tch profile sync: the whole family's viewing profiles ride the
/// sync document, so a profile created on the phone appears on the TV
/// (and every other linked device) without any file export.
///
/// The doc carries a `profiles` section (old builds ignore it):
///
/// ```json
/// "profiles": {
///   "v": 1,
///   "items": {
///     "<key>": {"name", "kind", "updated_ms", "avatar"|"art",
///                "pin", "rec", "allow": [list titles]},
///   },
///   "removed": {"<key>": removed_ms},
///   "watch": {"<key>": [watch-state rows]}
/// }
/// ```
///
/// - The key is the profile's stable cross-device sync id
///   ([Profile.syncId]); the admin profile uses the fixed key `admin`
///   and matches by KIND (every install has exactly one, whatever it
///   is named) — the family-import rule.
/// - Merging is last-writer-wins per profile on `updated_ms` (stamped
///   by every edit): the newest row's name/kind/avatar/PIN/allow-list
///   is the truth everywhere. Same-name profiles created independently
///   on two devices converge onto one sync id (newest row's id wins).
/// - Deletions travel as tombstones: the admin deleting a profile on
///   ANY device removes it — with its watch points and favourites —
///   from every linked device; a strictly newer edit still beats a
///   stale stone, so nothing is resurrected or lost to clock races.
/// - PINs travel as the stored salted hashes; the ADMIN PIN only ever
///   moves together with its recovery-code hash (they are a pair —
///   adopting the PIN alone would strand "Forgot PIN?").
/// - Kid allow-lists travel as list TITLES (ids differ per device),
///   resolved against the just-merged library.
/// - Avatars travel as sha256 manifests; the bytes ride the existing
///   x0x artwork transfer in full quality.
/// - Every profile's watch points sync (`watch`, keyed like `items`) —
///   a kid's Continue Watching follows them from the phone to the TV.
///   The admin profile's states keep riding the doc's top-level
///   `watch` section (what old builds read), never this one.
///
/// What deliberately does NOT sync: auto-select-at-launch and the
/// "shown on this device" visibility — both are per-DEVICE choices
/// (the kid's TV auto-opens the kid; the office desktop hides the
/// kids), and syncing them would make every device behave like the
/// last one configured.

/// The admin profile's fixed sync key.
const kProfileAdminKey = 'admin';

/// One profile row from a remote device's `profiles.items`.
class RemoteProfileItem {
  const RemoteProfileItem({
    required this.agentId,
    required this.key,
    required this.name,
    required this.kind,
    required this.updatedMs,
    this.presetAvatar,
    this.art,
    this.pin,
    this.rec,
    this.allow = const [],
  });

  final String agentId;
  final String key;
  final String name;

  /// 'admin' | 'adult' | 'kid'; anything else applies as adult.
  final String kind;
  final int updatedMs;

  /// `preset:<n>` when the remote avatar is a built-in drawing.
  final String? presetAvatar;

  /// Manifest of a file avatar — the bytes ride the artwork transfer.
  final ({String sha256, int size})? art;

  /// Salted PIN hash, and (admin only) its recovery-code hash pair.
  final String? pin;
  final String? rec;

  /// Kid allow-list as list titles.
  final List<String> allow;
}

/// Everything the remote docs say about profiles: the newest item and
/// the newest tombstone per key across every device.
class RemoteProfileActions {
  const RemoteProfileActions({required this.items, required this.stones});

  final Map<String, RemoteProfileItem> items;
  final Map<String, int> stones;

  bool get isEmpty => items.isEmpty && stones.isEmpty;
}

/// A file avatar the local profile [profileId] still needs the bytes
/// for — fetched over the artwork transfer from a device whose doc
/// names the same hash under [key].
typedef WantedAvatar = ({
  String profileId,
  String key,
  String sha256,
  int size,
});

/// What [applyProfileActions] did.
class ProfileSyncApply {
  int created = 0;
  int updated = 0;
  int deleted = 0;
  int get changed => created + updated + deleted;

  /// File avatars wanted but not yet held locally.
  final List<WantedAvatar> wantedAvatars = [];

  /// Remote sync key → the local profile id it resolved to (matched,
  /// created, or already held) — how per-profile watch states find
  /// their local profile.
  final Map<String, String> localIdByKey = {};
}

/// A stored PIN/recovery hash is `<salt-hex>:<sha256-hex>` — anything
/// else in a remote doc is junk and is dropped.
String? _validHash(Object? value) {
  if (value is! String) return null;
  final i = value.indexOf(':');
  return i > 0 && i < value.length - 1 ? value : null;
}

/// The newest profile item and tombstone per key across every remote
/// device's `profiles` section. Tolerant of malformed input (it is
/// remote data).
RemoteProfileActions profileActionsFrom(List<RemoteSyncDoc> remote) {
  final items = <String, RemoteProfileItem>{};
  final stones = <String, int>{};
  for (final d in remote) {
    final sec = d.doc['profiles'];
    if (sec is! Map<String, dynamic>) continue;
    final rawItems = sec['items'];
    if (rawItems is Map<String, dynamic>) {
      for (final e in rawItems.entries) {
        final v = e.value;
        final key = e.key.trim();
        if (v is! Map<String, dynamic> || key.isEmpty) continue;
        final name = (v['name'] as String? ?? '').trim();
        if (name.isEmpty) continue;
        final avatar = v['avatar'];
        final artMap = v['art'] as Map<String, dynamic>?;
        final artSha = (artMap?['sha256'] as String? ?? '').toLowerCase();
        final item = RemoteProfileItem(
          agentId: d.agentId,
          key: key,
          name: name,
          kind: v['kind'] is String ? v['kind'] as String : 'adult',
          updatedMs: v['updated_ms'] as int? ?? 0,
          presetAvatar:
              avatar is String && avatar.startsWith('preset:') ? avatar : null,
          art: artMap == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(artSha)
              ? null
              : (sha256: artSha, size: artMap['size'] as int? ?? 0),
          pin: _validHash(v['pin']),
          rec: _validHash(v['rec']),
          allow: [
            if (v['allow'] is List)
              for (final t in v['allow'] as List)
                if (t is String && t.trim().isNotEmpty) t,
          ],
        );
        final cur = items[key];
        if (cur == null || item.updatedMs > cur.updatedMs) items[key] = item;
      }
    }
    final rawStones = sec['removed'];
    if (rawStones is Map<String, dynamic>) {
      for (final e in rawStones.entries) {
        final ms = e.value;
        if (ms is! int || ms <= 0 || e.key == kProfileAdminKey) continue;
        if (ms > (stones[e.key] ?? 0)) stones[e.key] = ms;
      }
    }
  }
  return RemoteProfileActions(items: items, stones: stones);
}

/// Every remote device's per-profile watch states, keyed by profile
/// sync key (concatenated across devices — [WatchStateStore.mergeAll]
/// keeps the newest per address anyway).
Map<String, List<WatchState>> remoteProfileWatch(List<RemoteSyncDoc> remote) {
  final out = <String, List<WatchState>>{};
  for (final d in remote) {
    final sec = d.doc['profiles'];
    if (sec is! Map<String, dynamic>) continue;
    final watch = sec['watch'];
    if (watch is! Map<String, dynamic>) continue;
    for (final e in watch.entries) {
      final rows = e.value;
      if (rows is! List) continue;
      final states = out.putIfAbsent(e.key, () => []);
      for (final w in rows) {
        if (w is Map<String, dynamic> && w['address'] is String) {
          states.add(WatchState(
            address: (w['address'] as String).toLowerCase(),
            positionMs: w['pos_ms'] as int? ?? 0,
            durationMs: w['dur_ms'] as int? ?? 0,
            completed: w['completed'] as bool? ?? false,
            updatedAt: w['updated_ms'] as int? ?? 0,
          ));
        }
      }
    }
  }
  return out;
}

/// This device's `profiles` doc section (see the library docs above).
/// Always published — its presence tells linked devices this build
/// syncs profiles at all — with the tombstones GC'd by [tombstoneTtlMs]
/// and each profile's watch states capped at [maxWatchStatesPerProfile]
/// (the doc byte budget trims further when needed).
Future<Map<String, dynamic>> buildLocalProfilesSection({
  required List<MediaList> lists,
  required int nowMs,
  required Future<({String sha256, int size})?> Function(String fileName)
      avatarInfo,
  required int tombstoneTtlMs,
  int maxWatchStatesPerProfile = 300,
}) async {
  final store = ProfileStore.instance;
  await store.ensureLoaded();
  await store.ensureSyncIds();
  var stones = await ProfileStore.profileStones();
  final kept = {
    for (final e in stones.entries)
      if (nowMs - e.value <= tombstoneTtlMs) e.key: e.value,
  };
  if (kept.length != stones.length) {
    await ProfileStore.saveProfileStones(kept);
  }
  stones = kept;

  final titleById = {for (final l in lists) l.id: l.title};
  final items = <String, dynamic>{};
  final watch = <String, dynamic>{};
  for (final p in store.profiles) {
    final key = p.isAdmin ? kProfileAdminKey : p.syncId;
    if (key == null) continue;
    String? preset;
    Map<String, dynamic>? art;
    final avatar = p.avatar;
    if (avatar != null) {
      if (avatar.startsWith('preset:')) {
        preset = avatar;
      } else {
        final info = await avatarInfo(avatar);
        if (info != null) art = {'sha256': info.sha256, 'size': info.size};
      }
    }
    items[key] = {
      'name': p.name,
      'kind': p.kind.name,
      'updated_ms': p.updatedMs,
      'avatar': ?preset,
      'art': ?art,
      if (p.pinHash != null) 'pin': p.pinHash,
      // The admin PIN's recovery code travels beside it, as a pair.
      if (p.isAdmin && p.pinHash != null)
        'rec': ?await store.adminRecoveryHash(),
      if (p.isKid)
        'allow': [
          for (final id in await store.allowedListIds(p.id))
            if (titleById[id] != null) titleById[id]!,
        ],
    };
    if (!p.isAdmin) {
      // Newest-first from the store, so caps trim the stalest.
      final states =
          await WatchStateStore.instance.all(profileId: p.id);
      if (states.isNotEmpty) {
        watch[key] = [
          for (final s in states.take(maxWatchStatesPerProfile))
            {
              'address': s.address,
              'pos_ms': s.positionMs,
              'dur_ms': s.durationMs,
              'completed': s.completed,
              'updated_ms': s.updatedAt,
            },
        ];
      }
    }
  }
  return {
    'v': 1,
    'items': items,
    if (stones.isNotEmpty) 'removed': stones,
    if (watch.isNotEmpty) 'watch': watch,
  };
}

/// Merge the remote profile items and tombstones into the local
/// profiles, last-writer-wins per key (see the library docs above).
/// [lists] is the library AFTER the list merge, so kid allow-list
/// titles resolve against the just-synced lists. [avatarInfo] hashes a
/// local avatar file so an already-held avatar is never re-fetched.
Future<ProfileSyncApply> applyProfileActions({
  required Map<String, RemoteProfileItem> items,
  required Map<String, int> remoteStones,
  required List<MediaList> lists,
  Future<({String sha256, int size})?> Function(String fileName)? avatarInfo,
}) async {
  final store = ProfileStore.instance;
  await store.ensureLoaded();
  final out = ProfileSyncApply();

  // Adopt remote tombstones (newest wins) so they keep propagating.
  final stones = await ProfileStore.profileStones();
  var stonesChanged = false;
  for (final e in remoteStones.entries) {
    if (e.key == kProfileAdminKey) continue;
    if (e.value > (stones[e.key] ?? 0)) {
      stones[e.key] = e.value;
      stonesChanged = true;
    }
  }
  if (stonesChanged) await ProfileStore.saveProfileStones(stones);

  final listIdByTitle = {
    for (final l in lists) l.title.toLowerCase(): l.id,
  };
  Set<String> resolveLists(List<String> titles) => {
        for (final t in titles)
          if (listIdByTitle[t.toLowerCase()] != null)
            listIdByTitle[t.toLowerCase()]!,
      };

  Profile? current(String id) =>
      store.profiles.where((p) => p.id == id).firstOrNull;

  Future<void> wantAvatar(String profileId, RemoteProfileItem item) async {
    final art = item.art;
    if (art == null) return;
    final p = current(profileId);
    if (p == null || item.updatedMs < p.updatedMs) return;
    final avatar = p.avatar;
    if (avatar != null && !avatar.startsWith('preset:') &&
        avatarInfo != null) {
      final info = await avatarInfo(avatar);
      if (info != null && info.sha256 == art.sha256) return; // already held
    }
    out.wantedAvatars.add((
      profileId: profileId,
      key: item.key,
      sha256: art.sha256,
      size: art.size,
    ));
  }

  // ---- the admin profile: fixed key, matched by kind ------------------
  final adminItem = items[kProfileAdminKey];
  final admin = store.adminProfile;
  if (admin != null) {
    out.localIdByKey[kProfileAdminKey] = admin.id;
    if (adminItem != null && adminItem.updatedMs > admin.updatedMs) {
      var updated = admin.copyWith(
        name: adminItem.name,
        avatar: adminItem.presetAvatar ??
            (adminItem.art != null ? admin.avatar : null),
      );
      if (adminItem.pin != null && adminItem.rec != null) {
        await store.updateProfile(updated, updatedMs: adminItem.updatedMs);
        await store.adoptAdminPinPair(adminItem.pin!, adminItem.rec!,
            updatedMs: adminItem.updatedMs);
      } else if (adminItem.pin == null) {
        updated = updated.copyWith(pinHash: null);
        await store.updateProfile(updated, updatedMs: adminItem.updatedMs);
        await store.clearAdminRecovery();
      } else {
        // A PIN without its recovery pair never replaces ours — that
        // would strand "Forgot PIN?".
        await store.updateProfile(updated, updatedMs: adminItem.updatedMs);
      }
      out.updated++;
    }
    if (adminItem != null) await wantAvatar(admin.id, adminItem);
  }

  // ---- everyone else: sync id first, then name ------------------------
  final keys = {...items.keys, ...stones.keys}..remove(kProfileAdminKey);
  for (final key in keys) {
    final item = items[key];
    final stoneMs = stones[key] ?? 0;

    Profile? target =
        store.profiles.where((p) => p.syncId == key).firstOrNull;

    if (item == null || stoneMs >= item.updatedMs) {
      // The deletion wins (ties go to the stone, like channel subs
      // did) — unless a LOCAL edit is strictly newer than the stone.
      if (target != null && stoneMs > target.updatedMs) {
        await store.deleteProfile(target.id, recordStone: false);
        out.deleted++;
      }
      continue;
    }

    if (target == null) {
      // Same-name profiles created independently on two devices must
      // converge on ONE sync id, or every device ends up with
      // duplicates: the newest row's id wins (ties break on the id
      // bytes, so both sides pick the same winner); a local profile
      // that never minted an id adopts the remote one outright.
      final named = store.profiles
          .where((p) =>
              !p.isAdmin &&
              p.name.trim().toLowerCase() == item.name.trim().toLowerCase())
          .firstOrNull;
      if (named != null) {
        final localSid = named.syncId;
        final adoptSid = localSid == null ||
            item.updatedMs > named.updatedMs ||
            (item.updatedMs == named.updatedMs &&
                key.compareTo(localSid) > 0);
        if (adoptSid) {
          await store.updateProfile(named.copyWith(syncId: key),
              updatedMs: named.updatedMs);
          target = current(named.id);
        } else {
          // Ours keeps its id; the other device adopts it next cycle.
          // Its watch states still land on the shared profile.
          out.localIdByKey[key] = named.id;
          continue;
        }
      }
    }

    if (target == null) {
      // New profile from a linked device.
      final kind =
          ProfileKind.values.asNameMap()[item.kind] ?? ProfileKind.adult;
      final safeKind = kind == ProfileKind.admin ? ProfileKind.adult : kind;
      var created = await store.create(
        name: item.name,
        kind: safeKind,
        avatar: item.presetAvatar,
        allowedLists:
            safeKind == ProfileKind.kid ? resolveLists(item.allow) : {},
        syncId: key,
        updatedMs: item.updatedMs,
      );
      if (item.pin != null) {
        created = created.copyWith(pinHash: item.pin);
        await store.updateProfile(created, updatedMs: item.updatedMs);
      }
      out.localIdByKey[key] = created.id;
      out.created++;
      await wantAvatar(created.id, item);
      continue;
    }

    out.localIdByKey[key] = target.id;
    if (item.updatedMs > target.updatedMs) {
      final kind =
          ProfileKind.values.asNameMap()[item.kind] ?? ProfileKind.adult;
      final safeKind = kind == ProfileKind.admin ? ProfileKind.adult : kind;
      final updated = target.copyWith(
        name: item.name,
        kind: safeKind,
        avatar: item.presetAvatar ??
            (item.art != null ? target.avatar : null),
        pinHash: item.pin,
      );
      await store.updateProfile(updated, updatedMs: item.updatedMs);
      await store.setAllowedListIds(target.id,
          safeKind == ProfileKind.kid ? resolveLists(item.allow) : {});
      out.updated++;
    } else if (item.updatedMs == target.updatedMs && target.isKid) {
      // Equal stamps (the usual state after an adoption): top up the
      // allow-list with titles that resolve NOW but did not when the
      // row was adopted (their lists had not synced yet). Add-only —
      // removals happened at the strict adoption above.
      final resolved = resolveLists(item.allow);
      final currentIds = await store.allowedListIds(target.id);
      if (resolved.difference(currentIds).isNotEmpty) {
        await store.setAllowedListIds(
            target.id, {...currentIds, ...resolved});
        out.updated++;
      }
    }
    await wantAvatar(target.id, item);
  }
  return out;
}
