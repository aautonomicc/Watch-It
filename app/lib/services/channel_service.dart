import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_list.dart';
import 'bundle.dart';
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

  Timer? _timer;
  bool _syncing = false;

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
  /// head is visible (usually seconds on a live channel).
  Future<void> subscribe(String code) async {
    final pubkey = await api.subscribe(code.trim());
    final subs = await _loadSubs();
    subs[pubkey.toLowerCase()] = {
      'name': '',
      'description': '',
      'addedMs': DateTime.now().millisecondsSinceEpoch,
      'importedSeq': 0,
    };
    await _saveSubs(subs);
    notifyListeners();
    // Opportunistic first import; the periodic loop covers the rest.
    unawaited(syncNow());
  }

  /// Unsubscribe: drop the topic in the core, the display record, and
  /// the read-only channel list (the content itself was never "owned" —
  /// downloaded files remain like any downloads).
  Future<void> unsubscribe(String pubkey) async {
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

  // ---- auto-update loop --------------------------------------------------

  /// Check every subscription's verified head and import any manifest
  /// newer than what the library holds. Safe to call at will; runs are
  /// serialized.
  Future<void> syncNow() async {
    if (_syncing) return;
    _syncing = true;
    try {
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
          lastProblem.remove(key);
          changed = true;
        } catch (e) {
          lastProblem[key] = '$e';
        }
      }
      if (changed) {
        await _saveSubs(subs);
        revision.value++;
      }
      notifyListeners();
    } finally {
      _syncing = false;
    }
  }

  /// Fetch + verify + import one channel manifest as the channel's
  /// read-only library list (full replace — the list mirrors the
  /// manifest, it is not a merge target). Returns the manifest's own
  /// channel.json info for the caller's bookkeeping.
  Future<ChannelManifestInfo> _importManifest(
      String pubkey, ChannelHead head) async {
    final bytes =
        Uint8List.fromList(await api.fetchManifest(head.manifest));
    final manifest = parseChannelManifest(bytes);
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
    final i = lists.indexWhere((l) => l.channelPubkey == pubkey);
    if (i >= 0) {
      lists[i] = MediaList(
        id: lists[i].id,
        title: title,
        entries: entries,
        enabled: lists[i].enabled,
        channelPubkey: pubkey,
      );
    } else {
      lists.add(MediaList(
        id: 'channel-${pubkey.substring(0, 16)}',
        title: title,
        entries: entries,
        channelPubkey: pubkey,
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

  /// Build the channel manifest zip for the staged items and write it to
  /// a temp file (for estimate + publish). Reuses the bundle exporter,
  /// so the manifest carries the items' `.datamap` members, their
  /// metadata rows (the required Describe-this-item edits travel as
  /// `userEdited` rows) and poster files, plus `channel.json`.
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
    final channelJson = jsonEncode({
      'version': 1,
      'name': own.name,
      'description': own.description,
      'pubkey': own.pubkey,
      // Advisory history chain — the authoritative seq is the signed
      // head's; `previous` lets anyone walk back through old manifests
      // (permanence means they all stay fetchable).
      'seq': own.seq + 1,
      'previous': own.manifest.isEmpty ? null : own.manifest,
      'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
    });
    final built = await buildBundle(
      [list],
      const BundleExportOptions(includeHistory: false),
      base: importBase,
      postersDirProvider: postersDirProvider,
      extraTextMembers: {'channel.json': channelJson},
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
    final bytes =
        Uint8List.fromList(await api.fetchManifest(head.manifest));
    final manifest = parseChannelManifest(bytes);
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
      );
    }
    return items.length;
  }

  /// Wipe the own-channel item staging (after Remove channel).
  Future<void> clearMyItems() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_itemsKey);
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

/// Display record of a subscription (app-side bookkeeping).
class ChannelRecord {
  const ChannelRecord({
    required this.pubkey,
    required this.name,
    required this.description,
    required this.addedMs,
    required this.importedSeq,
  });

  final String pubkey;
  final String name;
  final String description;
  final int addedMs;
  final int importedSeq;

  factory ChannelRecord.fromJson(String pubkey, Map<String, dynamic> json) =>
      ChannelRecord(
        pubkey: pubkey,
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
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

/// `channel.json` inside a manifest.
class ChannelManifestInfo {
  const ChannelManifestInfo({
    required this.name,
    required this.description,
    required this.pubkey,
    this.seq,
    this.previous,
  });

  final String name;
  final String description;
  final String pubkey;
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
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes, verify: true);
  } catch (_) {
    throw const ListImportException(
        'The fetched manifest could not be read as a channel manifest.');
  }
  ChannelManifestInfo? info;
  for (final file in archive.files) {
    if (!file.isFile || file.name != 'channel.json') continue;
    try {
      final decoded =
          jsonDecode(utf8.decode(file.readBytes()!)) as Map<String, dynamic>;
      final pubkey = decoded['pubkey'] as String? ?? '';
      if (pubkey.isEmpty) break;
      info = ChannelManifestInfo(
        name: (decoded['name'] as String? ?? '').trim(),
        description: (decoded['description'] as String? ?? '').trim(),
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
  return ParsedChannelManifest(channel: info, bundle: parseBundle(bytes));
}
