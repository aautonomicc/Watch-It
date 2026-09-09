import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/library_store.dart';
import '../services/profiles.dart';
import '../theme/tokens.dart';
import '../widgets/pin_dialog.dart';
import '../widgets/profile_avatar.dart';
import 'channels_screen.dart' show pickChannelAvatar;

/// Settings → Profiles (admin only): the family's profiles, the door to
/// creating/editing them, and the admin PIN with its one-time recovery
/// code. Profiles share the install's network identity, wallet, lists
/// and downloads — only viewing state is per-profile.
class ProfilesScreen extends StatefulWidget {
  const ProfilesScreen({super.key});

  @override
  State<ProfilesScreen> createState() => _ProfilesScreenState();
}

class _ProfilesScreenState extends State<ProfilesScreen> {
  Future<void> _openProfile(Profile? profile) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ProfileEditScreen(profile: profile)),
    );
    if (mounted) setState(() {});
  }

  Future<void> _setAdminPin() async {
    final pin = await promptNewPin(
      context,
      title: ProfileStore.instance.adminHasPin
          ? 'Change admin PIN'
          : 'Set admin PIN',
    );
    if (pin == null || !mounted) return;
    final code = await ProfileStore.instance.setAdminPin(pin);
    if (!mounted) return;
    await showRecoveryCode(context, code);
    if (mounted) setState(() {});
  }

  Future<void> _changeAdminPin() async {
    // Changing or removing the PIN proves knowledge of it first.
    final ok = await verifyAdminPin(context, title: 'Current admin PIN');
    if (!ok || !mounted) return;
    final t = WiTokens.of(context);
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: t.ink2,
        title: Text('Admin PIN', style: TextStyle(color: t.bone, fontSize: 16)),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('change'),
            child: Text(
              'Change PIN',
              style: TextStyle(color: t.bone, fontSize: 14),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('remove'),
            child: Text(
              'Remove PIN',
              style: TextStyle(color: t.rust, fontSize: 14),
            ),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'change') {
      await _setAdminPin();
    } else if (action == 'remove') {
      await ProfileStore.instance.clearAdminPin();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text('Profiles', style: TextStyle(color: t.bone, fontSize: 18)),
      ),
      body: ListenableBuilder(
        listenable: ProfileStore.instance,
        builder: (context, _) {
          final store = ProfileStore.instance;
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Everyone shares this device\'s library, downloads and '
                  'network connection — each profile keeps its own viewing '
                  'positions, favourites and look. Kid profiles see only '
                  'the lists you choose, and no downloads.',
                  style: TextStyle(fontSize: 12, color: t.ash),
                ),
              ),
              for (final p in store.profiles)
                ListTile(
                  leading: ProfileAvatar(
                    name: p.name,
                    avatar: p.avatar,
                    size: 40,
                  ),
                  title: Text(
                    p.name,
                    style: TextStyle(color: t.bone, fontSize: 15),
                  ),
                  subtitle: Text(
                    [
                      switch (p.kind) {
                        ProfileKind.admin => 'Admin',
                        ProfileKind.adult => 'Adult',
                        ProfileKind.kid => 'Kid',
                      },
                      if (p.hasPin) 'PIN set',
                      if (p.autoLogin) 'auto-selected at launch',
                    ].join(' · '),
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.chevron_right, color: t.ash),
                  onTap: () => _openProfile(p),
                ),
              ListTile(
                leading: Icon(Icons.person_add_alt, color: t.accent),
                title: Text(
                  'Add profile',
                  style: TextStyle(color: t.accent, fontSize: 15),
                ),
                onTap: () => _openProfile(null),
              ),
              const Divider(height: 32),
              ListTile(
                leading: Icon(Icons.password, color: t.accent),
                title: Text(
                  'Admin PIN',
                  style: TextStyle(color: t.bone, fontSize: 15),
                ),
                subtitle: Text(
                  store.adminHasPin
                      ? 'Set — required to enter the admin profile and to '
                            'switch away from a kid profile'
                      : 'Not set — anyone can switch to the admin profile',
                  style: TextStyle(color: t.ash, fontSize: 12),
                ),
                trailing: Icon(Icons.chevron_right, color: t.ash),
                onTap: store.adminHasPin ? _changeAdminPin : _setAdminPin,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Create or edit one profile: name, type (Kid | Adult), avatar
/// (presets or a cropped image), a kid's allowed lists, auto-login and
/// the profile's own PIN. The admin profile edits here too (rename +
/// avatar) with its type locked.
class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen({super.key, this.profile});

  /// Null = create a new profile.
  final Profile? profile;

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  late final TextEditingController _name = TextEditingController(
    text: widget.profile?.name ?? '',
  );
  late ProfileKind _kind = widget.profile?.kind ?? ProfileKind.kid;
  late String? _avatar = widget.profile?.avatar;

  /// Freshly cropped avatar image, staged until Save.
  Uint8List? _stagedAvatarBytes;
  late bool _autoLogin = widget.profile?.autoLogin ?? false;
  Set<String> _allowed = {};
  List<MediaList> _lists = const [];
  bool _saving = false;

  bool get _isNew => widget.profile == null;
  bool get _isAdmin => widget.profile?.kind == ProfileKind.admin;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final lists = await LibraryStore.load();
    final allowed = widget.profile == null
        ? <String>{}
        : await ProfileStore.instance.allowedListIds(widget.profile!.id);
    if (!mounted) return;
    setState(() {
      _lists = lists;
      _allowed = allowed;
    });
  }

  Future<void> _pickImageAvatar() async {
    final bytes = await pickChannelAvatar(context);
    if (bytes == null) return;
    setState(() {
      _stagedAvatarBytes = bytes;
      _avatar = null; // replaced on save with the stored file name
    });
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Give the profile a name')));
      return;
    }
    setState(() => _saving = true);
    final store = ProfileStore.instance;
    final wasFirstExtra = !store.multiProfile;
    final firstKid =
        _kind == ProfileKind.kid &&
        !store.profiles.any((p) => p.isKid) &&
        !_isAdmin;
    Profile profile;
    if (_isNew) {
      profile = await store.create(
        name: name,
        kind: _kind,
        avatar: _avatar,
        allowedLists: _allowed,
      );
    } else {
      profile = widget.profile!.copyWith(
        name: name,
        kind: _isAdmin ? ProfileKind.admin : _kind,
        avatar: _avatar,
      );
      await store.updateProfile(profile);
      if (profile.isKid) {
        await store.setAllowedListIds(profile.id, _allowed);
      }
    }
    if (_stagedAvatarBytes != null) {
      final member = await ProfileStore.saveAvatarImage(
        profile.id,
        _stagedAvatarBytes!,
      );
      profile = store.profiles
          .firstWhere((p) => p.id == profile.id)
          .copyWith(avatar: member);
      await store.updateProfile(profile);
    }
    if (_autoLogin != (widget.profile?.autoLogin ?? false)) {
      await store.setAutoLogin(_autoLogin ? profile.id : null);
    }
    if (!mounted) return;
    // The agreed nudge: creating the first extra profile (and again the
    // first KID profile) offers to set an admin PIN, skippable with an
    // explicit warning.
    if (_isNew && !store.adminHasPin && (wasFirstExtra || firstKid)) {
      await _offerAdminPin();
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _offerAdminPin() async {
    final t = WiTokens.of(context);
    final set = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text(
          'Set an admin PIN?',
          style: TextStyle(color: t.bone, fontSize: 16),
        ),
        content: Text(
          'Without a PIN anyone can switch to the Admin profile and '
          'change anything — including kid restrictions. You can set '
          'one later in Settings → Profiles.',
          style: TextStyle(color: t.boneDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Not now', style: TextStyle(color: t.ash)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Set PIN', style: TextStyle(color: t.accent)),
          ),
        ],
      ),
    );
    if (set != true || !mounted) return;
    final pin = await promptNewPin(context, title: 'Set admin PIN');
    if (pin == null || !mounted) return;
    final code = await ProfileStore.instance.setAdminPin(pin);
    if (mounted) await showRecoveryCode(context, code);
  }

  Future<void> _managePin() async {
    final profile = widget.profile!;
    final store = ProfileStore.instance;
    if (profile.isAdmin) return; // managed on the Profiles page
    if (profile.hasPin) {
      final t = WiTokens.of(context);
      final action = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          backgroundColor: t.ink2,
          title: Text(
            'PIN for ${profile.name}',
            style: TextStyle(color: t.bone, fontSize: 16),
          ),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('change'),
              child: Text(
                'Reset PIN',
                style: TextStyle(color: t.bone, fontSize: 14),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('remove'),
              child: Text(
                'Remove PIN',
                style: TextStyle(color: t.rust, fontSize: 14),
              ),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (action == 'change') {
        final pin = await promptNewPin(
          context,
          title: 'New PIN for ${profile.name}',
        );
        if (pin != null) await store.setPin(profile.id, pin);
      } else if (action == 'remove') {
        await store.clearPin(profile.id);
      }
    } else {
      final pin = await promptNewPin(context, title: 'PIN for ${profile.name}');
      if (pin != null) await store.setPin(profile.id, pin);
    }
    if (mounted) setState(() {});
  }

  Future<void> _delete() async {
    final t = WiTokens.of(context);
    final profile = widget.profile!;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text(
          'Delete ${profile.name}?',
          style: TextStyle(color: t.bone, fontSize: 16),
        ),
        content: Text(
          'Removes this profile with its viewing positions and '
          'favourites. The library, downloads and other profiles are '
          'not affected.',
          style: TextStyle(color: t.boneDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: t.ash)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Delete', style: TextStyle(color: t.rust)),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    await ProfileStore.instance.deleteProfile(profile.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final storedProfile = widget.profile;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text(
          _isNew ? 'New profile' : 'Edit profile',
          style: TextStyle(color: t.bone, fontSize: 18),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(
              _isNew ? 'Create' : 'Save',
              style: TextStyle(color: t.accent, fontSize: 15),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            autofocus: _isNew,
            maxLength: 24,
            style: TextStyle(color: t.bone),
            decoration: InputDecoration(
              labelText: 'Name',
              counterText: '',
              labelStyle: TextStyle(color: t.ash),
            ),
          ),
          const SizedBox(height: 16),
          if (!_isAdmin) ...[
            Text(
              'TYPE',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w700,
                color: t.ash,
              ),
            ),
            const SizedBox(height: 8),
            SegmentedButton<ProfileKind>(
              segments: const [
                ButtonSegment(
                  value: ProfileKind.kid,
                  label: Text('Kid'),
                  icon: Icon(Icons.child_care_outlined),
                ),
                ButtonSegment(
                  value: ProfileKind.adult,
                  label: Text('Adult'),
                  icon: Icon(Icons.person_outline),
                ),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() => _kind = s.first),
            ),
            const SizedBox(height: 6),
            Text(
              _kind == ProfileKind.kid
                  ? 'Sees only the lists ticked below. Downloads and '
                        'most settings are hidden.'
                  : 'Sees the whole library and downloads; settings stay '
                        'limited to appearance and playback.',
              style: TextStyle(fontSize: 12, color: t.ash),
            ),
            const SizedBox(height: 20),
          ],
          Text(
            'AVATAR',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w700,
              color: t.ash,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (var i = 0; i < kProfileAvatarPresets.length; i++)
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => setState(() {
                    _avatar = 'preset:$i';
                    _stagedAvatarBytes = null;
                  }),
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _avatar == 'preset:$i'
                            ? t.accent
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: ProfileAvatar(
                      name: _name.text,
                      avatar: 'preset:$i',
                      size: 44,
                    ),
                  ),
                ),
              // From an image file → forced-square crop.
              InkWell(
                customBorder: const CircleBorder(),
                onTap: _pickImageAvatar,
                child: Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color:
                          _stagedAvatarBytes != null ||
                              (_avatar != null &&
                                  !_avatar!.startsWith('preset:'))
                          ? t.accent
                          : t.ash,
                      width: _stagedAvatarBytes != null ? 2 : 1,
                    ),
                  ),
                  child: _stagedAvatarBytes != null
                      ? ClipOval(
                          child: Image.memory(
                            _stagedAvatarBytes!,
                            fit: BoxFit.cover,
                          ),
                        )
                      : (_avatar != null && !_avatar!.startsWith('preset:'))
                      ? ProfileAvatar(
                          name: _name.text,
                          avatar: _avatar,
                          size: 46,
                        )
                      : Icon(
                          Icons.add_photo_alternate_outlined,
                          color: t.boneDim,
                          size: 22,
                        ),
                ),
              ),
            ],
          ),
          if (_kind == ProfileKind.kid && !_isAdmin) ...[
            const SizedBox(height: 24),
            Text(
              'ALLOWED LISTS',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w700,
                color: t.ash,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Only ticked lists appear in this profile — everything '
              'else (including search) stays hidden.',
              style: TextStyle(fontSize: 12, color: t.ash),
            ),
            if (_lists.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'No lists in the library yet.',
                  style: TextStyle(fontSize: 12.5, color: t.boneDim),
                ),
              ),
            for (final list in _lists)
              CheckboxListTile(
                value: _allowed.contains(list.id),
                dense: true,
                activeColor: t.accent,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(
                  list.title,
                  style: TextStyle(color: t.bone, fontSize: 14),
                ),
                subtitle: list.isChannel
                    ? Text(
                        'Channel — updates by itself',
                        style: TextStyle(color: t.ash, fontSize: 11),
                      )
                    : null,
                onChanged: (v) => setState(() {
                  if (v ?? false) {
                    _allowed.add(list.id);
                  } else {
                    _allowed.remove(list.id);
                  }
                }),
              ),
          ],
          const SizedBox(height: 16),
          SwitchListTile(
            secondary: Icon(Icons.login, color: t.accent),
            title: Text(
              'Auto-select at launch',
              style: TextStyle(color: t.bone, fontSize: 15),
            ),
            subtitle: Text(
              'Skip "Who\'s w@tching?" and open straight into this '
              'profile — the kids\' TV case. Only one profile can have '
              'this.',
              style: TextStyle(color: t.ash, fontSize: 12),
            ),
            value: _autoLogin,
            onChanged: (v) => setState(() => _autoLogin = v),
          ),
          if (!_isNew && !_isAdmin)
            ListTile(
              leading: Icon(Icons.password, color: t.accent),
              title: Text(
                storedProfile!.hasPin ? 'Reset or remove PIN' : 'Set PIN',
                style: TextStyle(color: t.bone, fontSize: 15),
              ),
              subtitle: Text(
                storedProfile.hasPin
                    ? 'This profile asks for its PIN when selected'
                    : 'Optional — asks for it when the profile is selected',
                style: TextStyle(color: t.ash, fontSize: 12),
              ),
              onTap: _managePin,
            ),
          if (!_isNew && !_isAdmin) ...[
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: _delete,
              style: OutlinedButton.styleFrom(
                foregroundColor: t.rust,
                side: BorderSide(color: t.rust),
              ),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Delete profile'),
            ),
          ],
          const SizedBox(height: 60),
        ],
      ),
    );
  }
}
