import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_list.dart';
import 'bundle.dart';
import 'channel_manifest_delta.dart';
import 'channels_api.dart';
import 'library_store.dart';
import 'list_import.dart';
import 'publish_api.dart';

/// App-side Channels state: subscribed channels' display records + the
/// auto-update loop that follows their signed heads, and the local item
/// list of this device's own channel.
///
/// Split of responsibilities with the Rust core (channels.rs): the core
/// owns keys, topics, signatures, and verified heads; this service owns
/// what the user *sees* — channel names/descriptions (from fetched
/// manifests), the read-only channel lists in the library, and the
/// bookkeeping of which manifest seq each subscription has imported.
class ChannelService extends ChangeNotifier {
  ChannelService._();

  static ChannelService instance = ChannelService._();

  /// Fresh instance for tests (drops timers, API overrides, problems).
  @visibleForTesting
  static void resetForTesting() {
    instance.stop();
    instance = ChannelService._();
  }

  /// Bumps when a channel import changed the library, so the home
  /// screen reloads without polling (same pattern as MyWatchSync).
  static final ValueNotifier<int> revision = ValueNotifier(0);

  static const _subsKey = 'channel_subs_v1';
  static const _itemsKey = 'my_channel_items_v1';
  static const _stonesKey = 'channel_sub_stones_v1';
  static const _ownKey = 'channel_own_import_v1';

  /// How often the background loop checks subscribed channels' heads.
  /// Heads arrive by gossip into the local store, so this poll is a
  /// localhost call — cheap; the manifest fetch only runs on a new seq.
  static const checkInterval = Duration(minutes: 5);

  ChannelsApi api = ChannelsApi();
  PublishApi publishApi = PublishApi();

  /// Base URL for the bundle import/export helpers (null = the live
  /// embedded client). Tests point it at the HTTP fake.
  String? importBase;

  /// Posters directory override (null = the app support dir). Tests
  /// point it at a temp dir.
  Future<Directory> Function()? postersDirProvider;

  /// Own-channel profile directory override (holds the current avatar
  /// crop); null = `<support>/channel`. Tests point it at a temp dir.
  Future<Directory> Function()? profileDirProvider;

  Timer? _timer;

  /// The in-flight sync cycle, null while idle. Callers of [syncNow]
  /// during a run join it instead of silently doing nothing.
  Future<void>? _run;

  /// Last auto-update outcome per channel pubkey (problems surface on
  /// the Channels screen).
  final Map<String, String> lastProblem = {};

  void start() {
    _timer ??= Timer.periodic(checkInterval, (_) => syncNow());
    // First check shortly after launch, once the core has had a moment
    // to join topics and replicate heads.
    Timer(const Duration(seconds: 20), syncNow);
  }

  @visibleForTesting
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  // ---- subscription records ---------------------------------------------

  Future<Map<String, dynamic>> _loadSubs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_subsKey);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      return {};
    }
  }

  Future<void> _saveSubs(Map<String, dynamic> subs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_subsKey, jsonEncode(subs));
  }

  /// Display record for a subscribed channel (name/description are
  /// whatever the last imported manifest said; empty until one landed).
  Future<ChannelRecord?> record(String pubkey) async {
    final subs = await _loadSubs();
    final raw = subs[pubkey.toLowerCase()];
    if (raw is! Map<String, dynamic>) return null;
    return ChannelRecord.fromJson(pubkey.toLowerCase(), raw);
  }

  Future<List<ChannelRecord>> records() async {
    final subs = await _loadSubs();
    return [
      for (final e in subs.entries)
        if (e.value is Map<String, dynamic>)
          ChannelRecord.fromJson(e.key, e.value as Map<String, dynamic>),
    ];
  }

  // ---- subscribe / unsubscribe ------------------------------------------

  /// Subscribe to [code]: the core joins the gossip topic, a display
  /// record is created, and the first import runs as soon as a verified
  /// head is visible (usually seconds on a live channel). [addedMs] lets
  /// My W@tch sync preserve the original subscribe time (so its LWW
  /// against unsubscribe tombstones converges); user actions omit it.
  Future<void> subscribe(String code, {int? addedMs}) async {
    final pubkey = await api.subscribe(code.trim());
    final subs = await _loadSubs();
    subs[pubkey.toLowerCase()] = {
      'name': '',
      'description': '',
      'addedMs': addedMs ?? DateTime.now().millisecondsSinceEpoch,
      'importedSeq': 0,
    };
    await _saveSubs(subs);
    notifyListeners();
    // Opportunistic first import; the periodic loop covers the rest.
    unawaited(syncNow());
  }

  /// Unsubscribe: drop the topic in the core, the display record, and
  /// the read-only channel list (the content itself was never "owned" —
  /// downloaded files remain like any downloads). Leaves a tombstone so
  /// My W@tch sync propagates the unsubscribe instead of resurrecting
  /// the channel from another device.
  Future<void> unsubscribe(String pubkey, {int? removedMs}) async {
    final key = pubkey.toLowerCase();
    try {
      await api.unsubscribe(key);
    } on PublishApiException {
      // Core may already have dropped it (fresh install, wiped dir) —
      // still remove the app-side state.
    }
    final subs = await _loadSubs();
    subs.remove(key);
    await _saveSubs(subs);
    final stones = await subStones();
    final stone = removedMs ?? DateTime.now().millisecondsSinceEpoch;
    if (stone > (stones[key] ?? 0)) {
      stones[key] = stone;
      await _saveStones(stones);
    }
    final lists = await LibraryStore.load();
    final remaining =
        [for (final l in lists) if (l.channelPubkey != key) l];
    if (remaining.length != lists.length) {
      await LibraryStore.save(remaining);
      revision.value++;
    }
    lastProblem.remove(key);
    notifyListeners();
  }

  /// Unsubscribe tombstones (`pubkey → removed_ms`), published through
  /// My W@tch sync so an unsubscribe reaches the user's other devices.
  Future<Map<String, int>> subStones() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_stonesKey);
    if (raw == null) return {};
    try {
      return {
        for (final e in (jsonDecode(raw) as Map<String, dynamic>).entries)
          if (e.value is int) e.key: e.value as int,
      };
    } on FormatException {
      return {};
    }
  }

  Future<void> _saveStones(Map<String, int> stones) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_stonesKey, jsonEncode(stones));
  }

  /// Adopt newer remote unsubscribe tombstones so they keep propagating
  /// through this device's own sync doc.
  Future<void> adoptSubStones(Map<String, int> remote) async {
    final stones = await subStones();
    var changed = false;
    for (final e in remote.entries) {
      final key = e.key.toLowerCase();
      if (e.value > (stones[key] ?? 0)) {
        stones[key] = e.value;
        changed = true;
      }
    }
    if (changed) await _saveStones(stones);
  }

  /// Everything My W@tch sync carries about channels: subscriptions with
  /// the `wchn1-` code another device needs to subscribe itself, the
  /// unsubscribe tombstones, and this device's own channel (announced so
  /// linked devices auto-subscribe and see it amber-badged, not as a
  /// copy of a personal list). Null while channels are unsupported or
  /// the core is not up.
  Future<ChannelSyncView?> syncView() async {
    final ChannelsStatus status;
    try {
      status = await api.status();
    } on PublishApiException {
      return null;
    }
    if (!status.supported) return null;
    final records = await _loadSubs();
    final subs = <String, ChannelSyncSub>{};
    for (final sub in status.subs) {
      final key = sub.pubkey.toLowerCase();
      if (key.isEmpty || sub.code.isEmpty) continue;
      final raw = records[key];
      final addedMs =
          raw is Map<String, dynamic> ? raw['addedMs'] as int? ?? 1 : 1;
      subs[key] = ChannelSyncSub(
          code: sub.code, addedMs: addedMs < 1 ? 1 : addedMs);
    }
    final own = status.own;
    final hasOwn = own != null && own.pubkey.isNotEmpty && own.code.isNotEmpty;
    return ChannelSyncView(
      subs: subs,
      stones: await subStones(),
      ownPubkey: hasOwn ? own.pubkey.toLowerCase() : null,
      ownCode: hasOwn ? own.code : null,
      // A restore re-stamps this, so a re-created channel beats old
      // unsubscribe tombstones on the other devices.
      ownAddedMs: hasOwn && own.createdAtMs > 0 ? own.createdAtMs : 1,
    );
  }

  // ---- auto-update loop --------------------------------------------------

  /// Check every subscription's verified head and import any manifest
  /// newer than what the library holds. Safe to call at will; runs are
  /// serialized — a call during an in-flight cycle joins that cycle.
  Future<void> syncNow() {
    final running = _run;
    if (running != null) return running;
    final run = _syncOnce();
    _run = run.whenComplete(() => _run = null);
    return _run!;
  }

  /// A manual "check now": guarantees one full pass that STARTS no
  /// earlier than the call. A background cycle may be mid-flight when
  /// the user presses Sync now (say, right after their connection came
  /// back) — joining it would report "checked" for work done before
  /// the press, so wait it out and run fresh. Failed imports carry no
  /// backoff (every cycle retries them), so the fresh pass genuinely
  /// re-attempts everything still pending.
  Future<void> checkNow() async {
    final running = _run;
    if (running != null) await running;
    // A tick can slip in between; joining it is fine — that run also
    // started after the press.
    await syncNow();
  }

  Future<void> _syncOnce() async {
    final ChannelsStatus status;
    try {
      status = await api.status();
    } on PublishApiException {
      return; // core not up yet; the next tick retries
    }
    if (!status.supported) return;
    final subs = await _loadSubs();
    var changed = false;
    for (final sub in status.subs) {
      final key = sub.pubkey.toLowerCase();
      final raw = subs[key];
      if (raw is! Map<String, dynamic>) continue;
      final head = sub.head;
      if (head == null) continue;
      final imported = raw['importedSeq'] as int? ?? 0;
      if (head.seq <= imported) continue;
      try {
        final info = await _importManifest(key, head);
        raw['importedSeq'] = head.seq;
        raw['name'] = info.name;
        raw['description'] = info.description;
        raw['author'] = info.author;
        raw['avatar'] = info.avatar;
        lastProblem.remove(key);
        changed = true;
      } catch (e) {
        lastProblem[key] = '$e';
      }
    }
    if (changed) {
      await _saveSubs(subs);
    }
    var ownChanged = false;
    try {
      ownChanged = await _syncOwnChannel(status.own);
    } catch (e) {
      final key = status.own?.pubkey.toLowerCase();
      if (key != null && key.isNotEmpty) lastProblem[key] = '$e';
    }
    if (changed || ownChanged) {
      revision.value++;
    }
    notifyListeners();
  }

  /// Keep the library's view of this device's OWN channel current: the
  /// creator sees the same amber read-only list subscribers get — empty
  /// the moment the channel is created, mirroring the manifest after
  /// each published update — and it leaves the library when the channel
  /// is removed. Returns whether the library changed.
  Future<bool> _syncOwnChannel(OwnChannel? own) async {
    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic> record;
    try {
      final raw = prefs.getString(_ownKey);
      record = raw == null ? {} : jsonDecode(raw) as Map<String, dynamic>;
    } on FormatException {
      record = {};
    }
    final recorded = (record['pubkey'] as String? ?? '').toLowerCase();
    if (own == null || own.pubkey.isEmpty) {
      // Channel removed from this device — its list goes too. A device
      // that never had a channel has no record and nothing to do.
      if (recorded.isEmpty) return false;
      await prefs.remove(_ownKey);
      lastProblem.remove(recorded);
      return _removeChannelList(recorded);
    }
    final pubkey = own.pubkey.toLowerCase();
    var changed = false;
    if (recorded.isNotEmpty && recorded != pubkey) {
      // A different channel replaced the old one (remove + restore).
      changed = await _removeChannelList(recorded);
    }
    var importedSeq =
        recorded == pubkey ? record['importedSeq'] as int? ?? 0 : 0;

    // The list itself exists from creation, so the channel shows up —
    // with its badge — before anything is published.
    final lists = await LibraryStore.load();
    final title = own.name.trim().isEmpty
        ? 'Channel ${pubkey.substring(0, 8)}'
        : own.name.trim();
    final author = own.author.trim().isEmpty ? null : own.author.trim();
    final avatarFile = await myAvatarFile();
    final avatar = avatarFile?.uri.pathSegments.last;
    final i = lists.indexWhere((l) => l.channelPubkey == pubkey);
    if (i < 0) {
      lists.add(MediaList(
        id: 'channel-${pubkey.substring(0, 16)}',
        title: title,
        entries: const [],
        channelPubkey: pubkey,
        channelAuthor: author,
        channelAvatar: avatar,
      ));
      await LibraryStore.save(lists);
      changed = true;
    } else if (importedSeq == 0 &&
        (lists[i].title != title ||
            lists[i].channelAuthor != author ||
            lists[i].channelAvatar != avatar)) {
      // Profile edited before the first publish — follow the config
      // (after a publish the imported manifest is the authority).
      lists[i] = MediaList(
        id: lists[i].id,
        title: title,
        entries: lists[i].entries,
        enabled: lists[i].enabled,
        channelPubkey: pubkey,
        channelAuthor: author,
        channelAvatar: avatar,
      );
      await LibraryStore.save(lists);
      changed = true;
    }

    final head = own.head;
    if (head != null && head.seq > importedSeq) {
      try {
        await _importManifest(pubkey, head);
        importedSeq = head.seq;
        lastProblem.remove(pubkey);
        changed = true;
      } catch (e) {
        lastProblem[pubkey] = '$e';
      }
    }
    await prefs.setString(
        _ownKey, jsonEncode({'pubkey': pubkey, 'importedSeq': importedSeq}));
    return changed;
  }

  Future<bool> _removeChannelList(String pubkey) async {
    final lists = await LibraryStore.load();
    final remaining =
        [for (final l in lists) if (l.channelPubkey != pubkey) l];
    if (remaining.length == lists.length) return false;
    await LibraryStore.save(remaining);
    return true;
  }

  /// Fetch + parse a manifest, delta-first: posters already in the
  /// posters directory are skipped from the download entirely (their
  /// bytes would lose the gap-fill anyway), so a channel update
  /// re-ships only what changed instead of every poster. Any planning
  /// or range hiccup falls back to the plain whole-manifest fetch.
  Future<ParsedChannelManifest> _fetchManifest(String address) async {
    try {
      final postersDir =
          await (postersDirProvider ?? defaultBundlePostersDir)();
      final delta = await fetchManifestMembersDelta(
        fetch: (range) => api.fetchManifestRange(address, range),
        havePoster: (base) =>
            File('${postersDir.path}/$base').existsSync(),
      );
      if (delta != null) {
        if (delta.postersSkipped > 0) {
          debugPrint('channel manifest $address: delta import fetched '
              '${delta.bytesFetched} of ${delta.totalSize} bytes '
              '(${delta.postersSkipped} posters already on disk)');
        }
        return delta.fullBytes != null
            ? parseChannelManifest(delta.fullBytes!)
            : parseChannelManifestMembers(delta.members!);
      }
    } on ListImportException {
      // The manifest itself is unusable (over the size cap) — a full
      // fetch would refuse it too.
      rethrow;
    } catch (_) {
      // Delta unavailable (old core, test fake, transport hiccup) —
      // the whole-manifest path below is the source of truth.
    }
    return parseChannelManifest(
        Uint8List.fromList(await api.fetchManifest(address)));
  }

  /// Fetch + verify + import one channel manifest as the channel's
  /// read-only library list (full replace — the list mirrors the
  /// manifest, it is not a merge target). Returns the manifest's own
  /// channel.json info for the caller's bookkeeping.
  Future<ChannelManifestInfo> _importManifest(
      String pubkey, ChannelHead head) async {
    final manifest = await _fetchManifest(head.manifest);
    if (manifest.channel.pubkey.toLowerCase() != pubkey) {
      throw PublishApiException(
          'the fetched manifest belongs to a different channel — refused');
    }
    final result = await importBundleEntries(
      manifest.bundle,
      base: importBase,
      defaultListTitle: manifest.channel.name.isEmpty
          ? 'Channel'
          : manifest.channel.name,
    );
    // Manifest order, flattened — a channel is one list on this side.
    final entries = [
      for (final list in result.lists) ...list.entries,
    ];
    await seedBundle(
      manifest.bundle,
      importHistory: false,
      addressByMember: result.addressByMember,
      postersDirProvider: postersDirProvider,
    );
    final lists = await LibraryStore.load();
    final title = manifest.channel.name.isEmpty
        ? 'Channel ${pubkey.substring(0, 8)}'
        : manifest.channel.name;
    final author =
        manifest.channel.author.isEmpty ? null : manifest.channel.author;
    final i = lists.indexWhere((l) => l.channelPubkey == pubkey);
    if (i >= 0) {
      lists[i] = MediaList(
        id: lists[i].id,
        title: title,
        entries: entries,
        enabled: lists[i].enabled,
        channelPubkey: pubkey,
        channelAuthor: author,
        channelAvatar: manifest.channel.avatar,
      );
    } else {
      lists.add(MediaList(
        id: 'channel-${pubkey.substring(0, 16)}',
        title: title,
        entries: entries,
        channelPubkey: pubkey,
        channelAuthor: author,
        channelAvatar: manifest.channel.avatar,
      ));
    }
    await LibraryStore.save(lists);
    return manifest.channel;
  }

  // ---- own channel: items + manifest ------------------------------------

  Future<List<MyChannelItem>> myItems() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_itemsKey);
    if (raw == null) return [];
    try {
      return [
        for (final e in jsonDecode(raw) as List<dynamic>)
          MyChannelItem.fromJson(e as Map<String, dynamic>),
      ];
    } on FormatException {
      return [];
    }
  }

  Future<void> _saveMyItems(List<MyChannelItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _itemsKey, jsonEncode([for (final i in items) i.toJson()]));
    notifyListeners();
  }

  /// Stage one item for the channel (items enter one explicit pick at a
  /// time — there is deliberately no bulk add).
  Future<void> addMyItem(MediaEntry entry) async {
    final items = await myItems();
    final addr = entry.address.toLowerCase();
    if (items.any((i) => i.address == addr)) return;
    items.add(MyChannelItem(
      address: addr,
      name: entry.name,
      addedMs: DateTime.now().millisecondsSinceEpoch,
    ));
    await _saveMyItems(items);
  }

  Future<void> removeMyItem(String address) async {
    final items = await myItems();
    items.removeWhere((i) => i.address == address.toLowerCase());
    await _saveMyItems(items);
  }

  // ---- own channel: avatar ------------------------------------------------

  Future<Directory> _profileDir() async {
    if (profileDirProvider != null) return profileDirProvider!();
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/channel');
  }

  /// The owner's current avatar crop, named by content hash exactly like
  /// its manifest member (`channel_avatar_<sha8>.img`); null when the
  /// channel has no avatar.
  Future<File?> myAvatarFile() async {
    final Directory dir;
    try {
      dir = await _profileDir();
    } catch (_) {
      // No support dir on this platform (headless tests) — no avatar.
      return null;
    }
    if (!dir.existsSync()) return null;
    for (final f in dir.listSync()) {
      if (f is File && isChannelAvatarMemberName(f.uri.pathSegments.last)) {
        return f;
      }
    }
    return null;
  }

  /// Set the owner's avatar (the 1:1 crop output, ≤2 MB). The file also
  /// lands in the posters dir under the same content-hash name, so the
  /// owner's own channel list renders it immediately — and after a
  /// publish the imported manifest maps to the identical file (the delta
  /// fetch then skips it as already held).
  Future<void> setMyAvatar(Uint8List bytes) async {
    if (bytes.length > kMaxChannelAvatarBytes) {
      throw PublishApiException(
          'the avatar image is larger than the 2 MB limit');
    }
    final name = channelAvatarMemberName(bytes);
    final dir = await _profileDir();
    // Sync IO throughout — async dart:io hangs widget tests' fake-async
    // zone (the standing user_metadata.dart rule).
    dir.createSync(recursive: true);
    // One avatar at a time: older crops (different hash names) go.
    for (final f in dir.listSync()) {
      if (f is File &&
          isChannelAvatarMemberName(f.uri.pathSegments.last) &&
          f.uri.pathSegments.last != name) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
    File('${dir.path}/$name').writeAsBytesSync(bytes, flush: true);
    final postersDir = await (postersDirProvider ?? defaultBundlePostersDir)();
    postersDir.createSync(recursive: true);
    final posterCopy = File('${postersDir.path}/$name');
    if (!posterCopy.existsSync()) {
      posterCopy.writeAsBytesSync(bytes, flush: true);
    }
    notifyListeners();
  }

  /// Resolve a channel avatar member name to its posters-dir file (may
  /// not exist yet — the icon fallback renders then). Null for unset or
  /// invalid names, or when no posters dir is available.
  Future<File?> avatarFileFor(String? memberName) async {
    if (memberName == null || !isChannelAvatarMemberName(memberName)) {
      return null;
    }
    try {
      final dir = await (postersDirProvider ?? defaultBundlePostersDir)();
      return File('${dir.path}/$memberName');
    } catch (_) {
      return null;
    }
  }

  /// Remove the owner's avatar (the next publish ships none).
  Future<void> clearMyAvatar() async {
    final file = await myAvatarFile();
    if (file != null) {
      try {
        file.deleteSync();
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Build the channel manifest zip for the staged items and write it to
  /// a temp file (for estimate + publish). Reuses the bundle exporter,
  /// so the manifest carries the items' `.datamap` members, their
  /// metadata rows (the required Describe-this-item edits travel as
  /// `userEdited` rows) and poster files, plus `channel.json` — and the
  /// channel profile: the optional author key and the avatar as one
  /// more content-hash-named poster member.
  Future<ChannelManifestBuild> buildMyManifest({
    required OwnChannel own,
  }) async {
    final items = await myItems();
    if (items.isEmpty) {
      throw PublishApiException('the channel has no items yet');
    }
    final list = MediaList(
      id: 'channel',
      title: own.name,
      entries: [
        for (final i in items) MediaEntry(name: i.name, address: i.address),
      ],
    );
    final avatarFile = await myAvatarFile();
    final avatarBytes = avatarFile == null
        ? null
        : Uint8List.fromList(await avatarFile.readAsBytes());
    final avatarMember =
        avatarBytes == null ? null : channelAvatarMemberName(avatarBytes);
    final author = own.author.trim();
    final channelJson = jsonEncode({
      'version': 1,
      'name': own.name,
      'description': own.description,
      // Optional profile keys — absent when unset, so old manifests and
      // authorless channels render identically.
      if (author.isNotEmpty) 'author': author,
      'avatar': ?avatarMember,
      'pubkey': own.pubkey,
      // Advisory history chain — the authoritative seq is the signed
      // head's; `previous` lets anyone walk back through old manifests
      // (permanence means they all stay fetchable).
      'seq': own.seq + 1,
      'previous': own.manifest.isEmpty ? null : own.manifest,
      'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
    });
    final extraPosters = <String, Uint8List>{};
    if (avatarMember != null && avatarBytes != null) {
      extraPosters[avatarMember] = avatarBytes;
    }
    final built = await buildBundle(
      [list],
      // omitCategories: channels publish no category tags.
      const BundleExportOptions(includeHistory: false, omitCategories: true),
      base: importBase,
      postersDirProvider: postersDirProvider,
      extraTextMembers: {'channel.json': channelJson},
      extraPosterMembers: extraPosters,
    );
    final dir = await Directory.systemTemp.createTemp('wi-channel-');
    final file = File('${dir.path}/manifest.watch-list');
    await file.writeAsBytes(built.bytes, flush: true);
    return ChannelManifestBuild(
      path: file.path,
      bytes: built.bytes.length,
      entriesIncluded: built.entriesIncluded,
      entriesMissingMap: built.entriesMissingMap,
    );
  }

  /// Restore helper: pull this channel's newest manifest back from the
  /// network and repopulate the local item list + display meta (used
  /// after "Restore channel" on a fresh machine).
  Future<int> restoreMyItemsFromManifest(ChannelHead head) async {
    final manifest = await _fetchManifest(head.manifest);
    final result = await importBundleEntries(
      manifest.bundle,
      base: importBase,
      defaultListTitle:
          manifest.channel.name.isEmpty ? 'Channel' : manifest.channel.name,
    );
    await seedBundle(
      manifest.bundle,
      importHistory: false,
      addressByMember: result.addressByMember,
      postersDirProvider: postersDirProvider,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    final items = [
      for (final list in result.lists)
        for (final e in list.entries)
          MyChannelItem(
            address: e.address.toLowerCase(),
            name: e.name,
            addedMs: now,
          ),
    ];
    await _saveMyItems(items);
    if (manifest.channel.name.isNotEmpty) {
      await api.setMeta(
        name: manifest.channel.name,
        description: manifest.channel.description,
        author: manifest.channel.author,
      );
    }
    // Bring the avatar back into place so the restored channel
    // republishes with its face intact: from the fetched manifest, or —
    // when the delta fetch skipped it — from the posters dir copy.
    final avatarName = manifest.channel.avatar;
    if (avatarName != null) {
      var bytes = manifest.bundle.posters[avatarName];
      if (bytes == null) {
        final postersDir =
            await (postersDirProvider ?? defaultBundlePostersDir)();
        final onDisk = File('${postersDir.path}/$avatarName');
        if (onDisk.existsSync()) {
          bytes = Uint8List.fromList(await onDisk.readAsBytes());
        }
      }
      if (bytes != null && bytes.length <= kMaxChannelAvatarBytes) {
        await setMyAvatar(bytes);
      }
    }
    return items.length;
  }

  /// Wipe the own-channel item staging + avatar (after Remove channel).
  Future<void> clearMyItems() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_itemsKey);
    try {
      final dir = await _profileDir();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
    notifyListeners();
  }
}

/// One staged item of this device's own channel.
class MyChannelItem {
  const MyChannelItem({
    required this.address,
    required this.name,
    required this.addedMs,
  });

  final String address;
  final String name;
  final int addedMs;

  Map<String, dynamic> toJson() =>
      {'address': address, 'name': name, 'addedMs': addedMs};

  factory MyChannelItem.fromJson(Map<String, dynamic> json) => MyChannelItem(
        address: (json['address'] as String? ?? '').toLowerCase(),
        name: json['name'] as String? ?? '',
        addedMs: json['addedMs'] as int? ?? 0,
      );
}

/// One subscription as My W@tch sync sees it: the code another device
/// needs to subscribe, and when this device subscribed (for the LWW
/// against unsubscribe tombstones).
class ChannelSyncSub {
  const ChannelSyncSub({required this.code, required this.addedMs});
  final String code;
  final int addedMs;
}

/// Snapshot of the channel state My W@tch sync publishes and merges —
/// see [ChannelService.syncView].
class ChannelSyncView {
  const ChannelSyncView({
    required this.subs,
    required this.stones,
    this.ownPubkey,
    this.ownCode,
    this.ownAddedMs = 1,
  });

  /// `pubkey → (code, addedMs)` for every subscription.
  final Map<String, ChannelSyncSub> subs;

  /// `pubkey → removed_ms` unsubscribe tombstones.
  final Map<String, int> stones;

  final String? ownPubkey;
  final String? ownCode;
  final int ownAddedMs;
}

/// Display record of a subscription (app-side bookkeeping).
class ChannelRecord {
  const ChannelRecord({
    required this.pubkey,
    required this.name,
    required this.description,
    this.author = '',
    this.avatar,
    required this.addedMs,
    required this.importedSeq,
  });

  final String pubkey;
  final String name;
  final String description;

  /// "by `<author>`" line from the last imported manifest; empty = unset.
  final String author;

  /// Avatar file name in the posters dir; null = none.
  final String? avatar;
  final int addedMs;
  final int importedSeq;

  factory ChannelRecord.fromJson(String pubkey, Map<String, dynamic> json) =>
      ChannelRecord(
        pubkey: pubkey,
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        author: json['author'] as String? ?? '',
        avatar: json['avatar'] as String?,
        addedMs: json['addedMs'] as int? ?? 0,
        importedSeq: json['importedSeq'] as int? ?? 0,
      );
}

class ChannelManifestBuild {
  const ChannelManifestBuild({
    required this.path,
    required this.bytes,
    required this.entriesIncluded,
    required this.entriesMissingMap,
  });

  final String path;
  final int bytes;
  final int entriesIncluded;
  final int entriesMissingMap;
}

/// Hard cap on the avatar crop output — it travels in every
/// subscriber's manifest fetch and the owner pays to upload it.
const int kMaxChannelAvatarBytes = 2 * 1024 * 1024;

String _capLength(String s, int max) =>
    s.length <= max ? s : s.substring(0, max);

/// The avatar's manifest member / posters-dir file name: content-hash
/// named so a changed avatar is a new member (fetched) and an unchanged
/// one keeps its name (skipped by the delta import for free).
String channelAvatarMemberName(List<int> bytes) =>
    'channel_avatar_${sha256.convert(bytes).toString().substring(0, 8)}.img';

/// Does [name] look like an avatar member base name? Also the safety
/// gate for the manifest's `avatar` key — the pattern has no room for
/// path separators or `..`, so a hostile name cannot escape anywhere.
bool isChannelAvatarMemberName(String name) =>
    RegExp(r'^channel_avatar_[0-9a-f]{8}\.img$').hasMatch(name);

/// `wchn1-<base32(pubkey)>` — the Dart twin of channel.rs's
/// `code_from_pubkey_hex` (lowercase unpadded RFC 4648 base32, 52
/// chars), for surfaces that only hold the pubkey — the channel info
/// card's anti-impersonation code line. Empty string on a bad key.
String channelCodeFromPubkeyHex(String pubkeyHex) {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
  final hex = pubkeyHex.trim().toLowerCase();
  if (hex.length != 64 || !RegExp(r'^[0-9a-f]+$').hasMatch(hex)) return '';
  var bits = 0, value = 0;
  final out = StringBuffer('wchn1-');
  for (var i = 0; i < hex.length; i += 2) {
    value = (value << 8) | int.parse(hex.substring(i, i + 2), radix: 16);
    bits += 8;
    while (bits >= 5) {
      out.write(alphabet[(value >> (bits - 5)) & 31]);
      bits -= 5;
    }
  }
  if (bits > 0) out.write(alphabet[(value << (5 - bits)) & 31]);
  return out.toString();
}

/// `channel.json` inside a manifest.
class ChannelManifestInfo {
  const ChannelManifestInfo({
    required this.name,
    required this.description,
    required this.pubkey,
    this.author = '',
    this.avatar,
    this.seq,
    this.previous,
  });

  final String name;
  final String description;
  final String pubkey;

  /// Optional "by `<author>`" name/handle; empty = unset (older manifests
  /// simply lack the key).
  final String author;

  /// Avatar member base name (`channel_avatar_<sha8>.img`), null when
  /// the channel has none.
  final String? avatar;
  final int? seq;
  final String? previous;
}

class ParsedChannelManifest {
  const ParsedChannelManifest({required this.channel, required this.bundle});
  final ChannelManifestInfo channel;
  final ParsedBundle bundle;
}

/// Parse a channel manifest: `channel.json` (required — its absence
/// means the zip is a plain bundle, not a channel manifest) plus the
/// normal bundle members.
ParsedChannelManifest parseChannelManifest(Uint8List bytes) {
  if (bytes.length > kMaxBundleBytes) {
    throw const ListImportException(
        'That bundle is larger than the 200 MB limit.');
  }
  return parseChannelManifestMembers(zipBundleMembers(
      bytes, 'The fetched manifest could not be read as a channel manifest.'));
}

/// [parseChannelManifest] after zip decoding — also fed directly by the
/// delta import's ranged-read members.
ParsedChannelManifest parseChannelManifestMembers(
    List<BundleZipMember> members) {
  ChannelManifestInfo? info;
  for (final member in members) {
    if (member.name != 'channel.json') continue;
    try {
      final decoded = jsonDecode(utf8.decode(member.read(kMaxLibraryJsonBytes)!))
          as Map<String, dynamic>;
      final pubkey = decoded['pubkey'] as String? ?? '';
      if (pubkey.isEmpty) break;
      final avatar = decoded['avatar'] as String? ?? '';
      info = ChannelManifestInfo(
        name: (decoded['name'] as String? ?? '').trim(),
        description: (decoded['description'] as String? ?? '').trim(),
        author: _capLength((decoded['author'] as String? ?? '').trim(), 80),
        // Only the exact content-hash pattern is accepted — anything
        // else (incl. path-y names) is treated as no avatar.
        avatar: isChannelAvatarMemberName(avatar) ? avatar : null,
        pubkey: pubkey.toLowerCase(),
        seq: decoded['seq'] as int?,
        previous: decoded['previous'] as String?,
      );
    } catch (_) {
      // Fall through to the error below.
    }
    break;
  }
  if (info == null) {
    throw const ListImportException(
        'That is not a channel manifest (no channel.json inside).');
  }
  return ParsedChannelManifest(
      channel: info, bundle: parseBundleMembers(members));
}
