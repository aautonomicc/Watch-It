import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/app_database.dart';
import '../models/media_list.dart';
import 'library_store.dart';

/// Id of the profile every pre-profile install silently becomes: the
/// Admin. Watch states rows without a profile default to it (schema
/// v13), and per-profile preference keys keep their historic unsuffixed
/// names for it — so upgrading changes nothing until a second profile
/// exists.
const kAdminProfileId = 'admin';

/// What a profile is allowed to do. Exactly one admin exists (the
/// migrated original install); adults see the whole library but only
/// essential settings; kids additionally see only allow-listed lists
/// and no downloads.
enum ProfileKind { admin, adult, kid }

/// One viewing profile. Profiles are NOT accounts: the network
/// identity, wallet, channels, lists and downloaded files are
/// install-global — a profile only scopes viewing state (watch points,
/// favourites, theme, list access).
class Profile {
  const Profile({
    required this.id,
    required this.name,
    required this.kind,
    this.avatar,
    this.pinHash,
    this.autoLogin = false,
    this.position = 0,
  });

  final String id;
  final String name;
  final ProfileKind kind;

  /// `preset:<n>` or a posters-dir file name; null = initial letter.
  final String? avatar;

  /// `<salt-hex>:<sha256-hex>`; null = no PIN.
  final String? pinHash;
  final bool autoLogin;
  final int position;

  bool get isAdmin => kind == ProfileKind.admin;
  bool get isKid => kind == ProfileKind.kid;
  bool get hasPin => pinHash != null;

  Profile copyWith({
    String? name,
    ProfileKind? kind,
    Object? avatar = _sentinel,
    Object? pinHash = _sentinel,
    bool? autoLogin,
    int? position,
  }) => Profile(
    id: id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    avatar: avatar == _sentinel ? this.avatar : avatar as String?,
    pinHash: pinHash == _sentinel ? this.pinHash : pinHash as String?,
    autoLogin: autoLogin ?? this.autoLogin,
    position: position ?? this.position,
  );

  static const _sentinel = Object();
}

/// Outcome of a PIN check (rate-limited: too many wrong tries lock the
/// profile's PIN for a cool-down).
enum PinVerify { ok, wrong, locked }

/// Holds the profiles and which one is watching. The store is loaded
/// before the first frame (main()); while only the migrated Admin
/// profile exists every surface behaves exactly as before profiles
/// existed — the feature stays invisible until a second profile is
/// created in Settings → Profiles.
class ProfileStore extends ChangeNotifier {
  /// Replaceable for tests (fresh instance per test).
  static ProfileStore instance = ProfileStore();

  static const _activeKey = 'active_profile_v1';
  static const _recoveryKey = 'admin_pin_recovery_v1';
  static const _pinFailPrefix = 'pin_fails_';
  static const _pinLockPrefix = 'pin_lock_until_';

  /// Wrong tries before the PIN locks, and for how long.
  static const maxPinAttempts = 5;
  static const pinLockSeconds = 60;

  List<Profile> _profiles = const [];
  String? _activeId;
  bool _loaded = false;

  /// The active KID profile's allowed list ids; null = no restriction
  /// (adult/admin active, or not loaded).
  Set<String>? _activeAllowed;

  /// Fired (value bumped) whenever the ACTIVE profile changes — the app
  /// shell rekeys its whole widget tree off it so every screen rebuilds
  /// against the new profile's state.
  final ValueNotifier<int> generation = ValueNotifier(0);

  bool get loaded => _loaded;
  List<Profile> get profiles => _profiles;

  /// More than one profile exists — the point where the profile UI
  /// (picker, switch button, per-profile scoping) becomes visible.
  bool get multiProfile => _profiles.length > 1;

  /// The watching profile; null = nobody picked yet (the gate shows the
  /// picker). Defaults to Admin while the store never loaded (unit
  /// tests, early callers) so pre-profile behaviour is preserved.
  Profile? get active {
    // Loaded with nobody signed in = the picker is asking.
    if (_loaded && _activeId == null) return null;
    final id = activeId;
    for (final p in _profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  String get activeId => _activeId ?? kAdminProfileId;

  /// Whether somebody is signed in (vs the picker showing).
  bool get hasActive => !_loaded || _activeId != null;

  bool get isKid => active?.isKid ?? false;
  bool get isAdmin => active?.isAdmin ?? !_loaded;

  Profile? get adminProfile {
    for (final p in _profiles) {
      if (p.isAdmin) return p;
    }
    return null;
  }

  bool get adminHasPin => adminProfile?.hasPin ?? false;

  /// Load profiles, silently migrating a pre-profile install to a lone
  /// Admin profile, and pick the launch profile: the only profile when
  /// there is just one, else the designated auto-login profile, else
  /// nobody (the picker asks).
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final db = await LibraryStore.database();
    var rows = await (db.select(
      db.profiles,
    )..orderBy([(t) => OrderingTerm.asc(t.position)])).get();
    if (rows.isEmpty) {
      await db
          .into(db.profiles)
          .insert(
            ProfilesCompanion.insert(
              id: kAdminProfileId,
              name: 'Admin',
              kind: ProfileKind.admin.name,
            ),
          );
      rows = await db.select(db.profiles).get();
    }
    _profiles = [for (final r in rows) _fromRow(r)];
    _loaded = true;
    if (_profiles.length == 1) {
      _activeId = _profiles.first.id;
    } else {
      final auto = _profiles.where((p) => p.autoLogin).firstOrNull;
      _activeId = auto?.id;
    }
    await _loadActiveAccess();
    final prefs = await SharedPreferences.getInstance();
    if (_activeId != null) {
      await prefs.setString(_activeKey, _activeId!);
    }
    notifyListeners();
  }

  Future<void> _reload() async {
    final db = await LibraryStore.database();
    final rows = await (db.select(
      db.profiles,
    )..orderBy([(t) => OrderingTerm.asc(t.position)])).get();
    _profiles = [for (final r in rows) _fromRow(r)];
    if (_activeId != null && !_profiles.any((p) => p.id == _activeId)) {
      _activeId = _profiles.isEmpty ? null : _profiles.first.id;
    }
    await _loadActiveAccess();
    notifyListeners();
  }

  Future<void> _loadActiveAccess() async {
    final act = active;
    if (act == null || !act.isKid) {
      _activeAllowed = null;
      return;
    }
    _activeAllowed = await allowedListIds(act.id);
  }

  /// Called after the active profile changes so per-profile singletons
  /// outside the widget tree (favourites, watch-state cache, theme)
  /// reload against the new profile; wired up in main().
  static Future<void> Function()? onSwitch;

  /// Make [id] the watching profile. PIN checks happen in the UI before
  /// this is called. Bumps [generation] so the app shell rebuilds.
  Future<void> selectProfile(String id) async {
    _activeId = id;
    await _loadActiveAccess();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeKey, id);
    await onSwitch?.call();
    generation.value++;
    notifyListeners();
  }

  /// Back to the picker (switch profile).
  void signOut() {
    _activeId = null;
    _activeAllowed = null;
    notifyListeners();
  }

  /// The lists the ACTIVE profile may see: kids get their allow-list,
  /// everyone else the lot. Pure and sync — callers filter what they
  /// loaded.
  List<MediaList> visibleLists(List<MediaList> lists) {
    final allowed = _activeAllowed;
    if (allowed == null) return lists;
    return [
      for (final l in lists)
        if (allowed.contains(l.id)) l,
    ];
  }

  /// Per-profile preference key: the Admin profile keeps the historic
  /// unsuffixed [base] (upgrades change nothing), other profiles get
  /// their own suffixed slot.
  String prefKey(String base) =>
      activeId == kAdminProfileId ? base : '${base}_p_$activeId';

  // ---- CRUD -----------------------------------------------------------

  Future<Profile> create({
    required String name,
    required ProfileKind kind,
    String? avatar,
    Set<String> allowedLists = const {},
  }) async {
    assert(kind != ProfileKind.admin, 'only the migrated admin is admin');
    final db = await LibraryStore.database();
    final id = 'p${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final position = _profiles.isEmpty
        ? 0
        : _profiles.map((p) => p.position).reduce(max) + 1;
    await db
        .into(db.profiles)
        .insert(
          ProfilesCompanion.insert(
            id: id,
            name: name,
            kind: kind.name,
            avatar: Value(avatar),
            position: Value(position),
          ),
        );
    if (kind == ProfileKind.kid) {
      await setAllowedListIds(id, allowedLists, reload: false);
    }
    await _reload();
    return _profiles.firstWhere((p) => p.id == id);
  }

  Future<void> updateProfile(Profile profile) async {
    final db = await LibraryStore.database();
    await (db.update(db.profiles)..where((t) => t.id.equals(profile.id))).write(
      ProfilesCompanion(
        name: Value(profile.name),
        kind: Value(profile.kind.name),
        avatar: Value(profile.avatar),
        pinHash: Value(profile.pinHash),
        autoLogin: Value(profile.autoLogin),
        position: Value(profile.position),
      ),
    );
    await _reload();
  }

  /// Delete a (never the admin) profile and everything only it owned:
  /// its watch states, list access, favourites and prefs slots, and a
  /// file avatar.
  Future<void> deleteProfile(String id) async {
    if (id == kAdminProfileId) return;
    final db = await LibraryStore.database();
    final row = _profiles.where((p) => p.id == id).firstOrNull;
    await (db.delete(db.profiles)..where((t) => t.id.equals(id))).go();
    await (db.delete(
      db.profileListAccess,
    )..where((t) => t.profileId.equals(id))).go();
    await (db.delete(
      db.watchStates,
    )..where((t) => t.profileId.equals(id))).go();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('favourites_v1_p_$id');
    await prefs.remove('theme_mode_v1_p_$id');
    await prefs.remove('$_pinFailPrefix$id');
    await prefs.remove('$_pinLockPrefix$id');
    final avatar = row?.avatar;
    if (avatar != null && !avatar.startsWith('preset:')) {
      await deleteAvatarFile(avatar);
    }
    if (_activeId == id) _activeId = null;
    await _reload();
  }

  /// Designate [id] (or nobody, with null) as the launch auto-login
  /// profile; any previous designation is cleared.
  Future<void> setAutoLogin(String? id) async {
    final db = await LibraryStore.database();
    await db
        .update(db.profiles)
        .write(const ProfilesCompanion(autoLogin: Value(false)));
    if (id != null) {
      await (db.update(db.profiles)..where((t) => t.id.equals(id))).write(
        const ProfilesCompanion(autoLogin: Value(true)),
      );
    }
    await _reload();
  }

  // ---- Kid list access ------------------------------------------------

  Future<Set<String>> allowedListIds(String profileId) async {
    final db = await LibraryStore.database();
    final rows = await (db.select(
      db.profileListAccess,
    )..where((t) => t.profileId.equals(profileId))).get();
    return {for (final r in rows) r.listId};
  }

  Future<void> setAllowedListIds(
    String profileId,
    Set<String> listIds, {
    bool reload = true,
  }) async {
    final db = await LibraryStore.database();
    await db.transaction(() async {
      await (db.delete(
        db.profileListAccess,
      )..where((t) => t.profileId.equals(profileId))).go();
      for (final id in listIds) {
        await db
            .into(db.profileListAccess)
            .insert(
              ProfileListAccessCompanion.insert(
                profileId: profileId,
                listId: id,
              ),
            );
      }
    });
    if (reload) await _reload();
  }

  // ---- PINs -----------------------------------------------------------

  static String _hashPin(String pin, String saltHex) =>
      sha256.convert([...saltHex.codeUnits, ...pin.codeUnits]).toString();

  static String _newSalt() {
    final rng = Random.secure();
    return List.generate(
      16,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static String encodePin(String pin) {
    final salt = _newSalt();
    return '$salt:${_hashPin(pin, salt)}';
  }

  static bool _matches(String pin, String stored) {
    final i = stored.indexOf(':');
    if (i <= 0) return false;
    final salt = stored.substring(0, i);
    return _hashPin(pin, salt) == stored.substring(i + 1);
  }

  Future<void> setPin(String profileId, String pin) async {
    final p = _profiles.firstWhere((p) => p.id == profileId);
    await updateProfile(p.copyWith(pinHash: encodePin(pin)));
    await _clearFailures(profileId);
  }

  Future<void> clearPin(String profileId) async {
    final p = _profiles.firstWhere((p) => p.id == profileId);
    await updateProfile(p.copyWith(pinHash: null));
    await _clearFailures(profileId);
  }

  /// Check [pin] against [profileId]'s stored PIN, rate-limited: after
  /// [maxPinAttempts] wrong tries the check refuses for
  /// [pinLockSeconds] regardless of the entered value.
  Future<PinVerify> verifyPin(String profileId, String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final lockUntil = prefs.getInt('$_pinLockPrefix$profileId') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now < lockUntil) return PinVerify.locked;
    final p = _profiles.where((p) => p.id == profileId).firstOrNull;
    final stored = p?.pinHash;
    if (stored == null) return PinVerify.ok;
    if (_matches(pin, stored)) {
      await _clearFailures(profileId);
      return PinVerify.ok;
    }
    final fails = (prefs.getInt('$_pinFailPrefix$profileId') ?? 0) + 1;
    if (fails >= maxPinAttempts) {
      await prefs.setInt(
        '$_pinLockPrefix$profileId',
        now + pinLockSeconds * 1000,
      );
      await prefs.setInt('$_pinFailPrefix$profileId', 0);
      return PinVerify.locked;
    }
    await prefs.setInt('$_pinFailPrefix$profileId', fails);
    return PinVerify.wrong;
  }

  Future<void> _clearFailures(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_pinFailPrefix$profileId');
    await prefs.remove('$_pinLockPrefix$profileId');
  }

  // ---- Admin PIN recovery code ---------------------------------------

  /// Set (or change) the admin PIN and mint the one-time recovery code
  /// shown to the user exactly once — stored salted-hashed like the PIN,
  /// regenerated on every PIN change. Admin only: child PINs are reset
  /// by the admin instead.
  Future<String> setAdminPin(String pin) async {
    await setPin(kAdminProfileId, pin);
    final code = _newRecoveryCode();
    final prefs = await SharedPreferences.getInstance();
    // Hash the dash-less form — entry is normalized the same way, so
    // typing it with or without dashes (or lowercase) both work.
    await prefs.setString(
        _recoveryKey, encodePin(code.replaceAll('-', '')));
    return code;
  }

  Future<void> clearAdminPin() async {
    await clearPin(kAdminProfileId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_recoveryKey);
  }

  /// "Forgot PIN?": a matching recovery code removes the admin PIN (and
  /// itself) so the user can get in and set a fresh one.
  Future<bool> recoverAdminPin(String code) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_recoveryKey);
    if (stored == null) return false;
    final normalized = code.trim().toUpperCase().replaceAll('-', '');
    if (!_matches(normalized, stored)) return false;
    await clearAdminPin();
    return true;
  }

  static String _newRecoveryCode() {
    // No 0/O/1/I — the code gets read off a screen and typed back.
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random.secure();
    final raw = List.generate(
      12,
      (_) => alphabet[rng.nextInt(alphabet.length)],
    ).join();
    return '${raw.substring(0, 4)}-${raw.substring(4, 8)}-${raw.substring(8)}';
  }

  // ---- Avatars --------------------------------------------------------

  /// Injectable posters-dir override for tests (real path_provider
  /// hangs the fake-async test zone).
  static Future<Directory> Function()? postersDirProvider;

  static Future<Directory> _postersDir() async {
    if (postersDirProvider != null) return postersDirProvider!();
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/posters');
  }

  /// Persist cropped avatar [bytes] for [profileId]; returns the stored
  /// file name (fresh per save — Flutter's image cache keys by path).
  /// Sync IO on purpose: async dart:io hangs fake-async test zones.
  static Future<String> saveAvatarImage(
    String profileId,
    Uint8List bytes,
  ) async {
    final dir = await _postersDir();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    for (final f in dir.listSync()) {
      final name = f.uri.pathSegments.last;
      if (f is File && name.startsWith('profile_avatar_${profileId}_')) {
        try {
          f.deleteSync();
        } on FileSystemException {
          // Locked/missing — the fresh name below still wins.
        }
      }
    }
    final name =
        'profile_avatar_${profileId}_${DateTime.now().millisecondsSinceEpoch}.img';
    File('${dir.path}/$name').writeAsBytesSync(bytes);
    return name;
  }

  static Future<File?> avatarFile(String? name) async {
    if (name == null || name.startsWith('preset:')) return null;
    // Strict shape — never treat a path-y value as a file to open.
    if (!RegExp(r'^profile_avatar_[A-Za-z0-9]+_\d+\.img$').hasMatch(name)) {
      return null;
    }
    final dir = await _postersDir();
    final file = File('${dir.path}/$name');
    return file.existsSync() ? file : null;
  }

  static Future<void> deleteAvatarFile(String name) async {
    final file = await avatarFile(name);
    try {
      file?.deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  }

  static Profile _fromRow(ProfileRow r) => Profile(
    id: r.id,
    name: r.name,
    kind: ProfileKind.values.asNameMap()[r.kind] ?? ProfileKind.adult,
    avatar: r.avatar,
    pinHash: r.pinHash,
    autoLogin: r.autoLogin,
    position: r.position,
  );
}
