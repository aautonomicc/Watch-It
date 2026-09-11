import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../l10n/eco_corpus.dart';

/// Three registers for any UI that surfaces a choice. Same doors, three
/// densities. New bee is the default and NEVER uses numbered steps —
/// flow is view / emotion / choose-click.
enum ExperienceView {
  newBee,
  raver,
  cypherpunk;

  String get label => switch (this) {
        ExperienceView.newBee => 'New bee',
        ExperienceView.raver => 'Raver',
        ExperienceView.cypherpunk => 'Cypherpunk',
      };

  String get hint => switch (this) {
        ExperienceView.newBee => 'Calm and readable',
        ExperienceView.raver => 'Tighter, same doors',
        ExperienceView.cypherpunk => 'Full technical density',
      };
}

/// Active register. Loaded from [AppSettings] before the first frame
/// and flipped live from the chrome switch / Settings → Appearance.
/// Per-profile, like the colour scheme.
final ValueNotifier<ExperienceView> wiExperienceView =
    ValueNotifier(ExperienceView.newBee);

/// Suggested list title when a received public piece is kept.
const kSharedPiecesListTitle = 'Shared pieces';

/// Adoption promise — felt in the UI, not buried in docs.
const kAdoptionPromise =
    'Make something beautiful. Give someone a piece of it. Stay connected to its maker.';

/// Copy that changes with the register. Widgets read this instead of
/// branching on raw developer strings. New bee / Raver resolve through
/// the 26-language eco corpus; Cypherpunk stays English (protocol).
class ExperienceCopy {
  const ExperienceCopy(this.view, {this.locale});

  factory ExperienceCopy.of(BuildContext context, [ExperienceView? view]) {
    return ExperienceCopy(
      view ?? wiExperienceView.value,
      locale: Localizations.maybeLocaleOf(context),
    );
  }

  final ExperienceView view;
  final Locale? locale;

  bool get isNewBee => view == ExperienceView.newBee;
  bool get isRaver => view == ExperienceView.raver;
  bool get isCypherpunk => view == ExperienceView.cypherpunk;

  String _l(String key, String english) {
    if (isCypherpunk) return english;
    final code = locale?.languageCode;
    if (code == null || code == 'en') return english;
    return EcoCorpus.string(code, key) ?? english;
  }

  String get receiveTitle => _l(
        'receiveTitle.${view.name}',
        switch (view) {
          ExperienceView.newBee => 'A piece of someone’s work',
          ExperienceView.raver => 'Catch a shared piece',
          ExperienceView.cypherpunk => 'Public XOR import',
        },
      );

  String get receiveEmotion => _l(
        'receiveEmotion.${view.name}',
        switch (view) {
          ExperienceView.newBee =>
            'They made something. They gave you a way to keep it.',
          ExperienceView.raver =>
            'Verify it, Keep it. The maker still holds the original.',
          ExperienceView.cypherpunk =>
            'HEAD /public/{address} — read-only probe. Saving writes a '
                'private library bookmark. Nothing is re-uploaded or published.',
        },
      );

  String get addressLabel => _l(
        'addressLabel.${view.name}',
        switch (view) {
          ExperienceView.newBee => 'The address they sent you',
          ExperienceView.raver => 'Public address',
          ExperienceView.cypherpunk => 'Public XOR (64 hex, optional 0x)',
        },
      );

  String get addressHint => switch (view) {
        ExperienceView.newBee => 'It looks like a long code',
        ExperienceView.raver => '0x… or 64 hex characters',
        ExperienceView.cypherpunk => '64 hexadecimal characters',
      };

  String get lookUpVerb => _l(
        'lookUpVerb.${view.name}',
        switch (view) {
          ExperienceView.newBee => 'Look it up',
          ExperienceView.raver => 'Verify',
          ExperienceView.cypherpunk => 'HEAD /public',
        },
      );

  String get lookingUp => _l(
        'lookingUp.${view.name}',
        switch (view) {
          ExperienceView.newBee => 'Looking for that piece…',
          ExperienceView.raver => 'Verifying…',
          ExperienceView.cypherpunk => 'Probing /public…',
        },
      );

  String get nameLabel => _l(
        'nameLabel.${view.name}',
        switch (view) {
          ExperienceView.newBee => 'Name this piece',
          ExperienceView.raver => 'Title / credit',
          ExperienceView.cypherpunk => 'Title / creator credit',
        },
      );

  String get nameHint => switch (view) {
        ExperienceView.newBee => 'What do you want to call it?',
        ExperienceView.raver => 'Song and Dance — maker',
        ExperienceView.cypherpunk => 'e.g. Song and Dance Festival — LNKC',
      };

  String get defaultName => switch (view) {
        ExperienceView.newBee => 'A shared piece',
        ExperienceView.raver => 'Shared piece',
        ExperienceView.cypherpunk => 'Autonomi public file',
      };

  String verifiedLine(String? size) {
    final bare = _l(
      'verified.${view.name}',
      switch (view) {
        ExperienceView.newBee => 'This piece is real.',
        ExperienceView.raver => 'Verified. Keep it if it feels right.',
        ExperienceView.cypherpunk => 'Verified public address',
      },
    );
    return size == null ? bare : '$bare · $size';
  }

  String get keepVerb => _l(
        'keepVerb.${view.name}',
        switch (view) {
          ExperienceView.newBee => 'Keep it',
          ExperienceView.raver => 'Keep',
          ExperienceView.cypherpunk => 'Save public reference',
        },
      );

  String get notThisVerb => _l(
        'notThisVerb.${view.name}',
        switch (view) {
          ExperienceView.newBee => 'Not this one',
          ExperienceView.raver => 'Dismiss',
          ExperienceView.cypherpunk => 'Cancel',
        },
      );

  String get tryAgainVerb => _l('tryAgain', 'Try again');
  String get pasteDifferentVerb =>
      _l('pasteDifferent', 'Paste a different address');

  String get keptSnack => _l(
        'keptSnack.${view.name}',
        switch (view) {
          ExperienceView.newBee =>
            'Kept. It’s in your library — the maker still holds the original.',
          ExperienceView.raver =>
            'Kept on this device. Still lives on Autonomi.',
          ExperienceView.cypherpunk =>
            'Public reference added — content stays on Autonomi.',
        },
      );

  String get estateTitle => switch (view) {
        ExperienceView.newBee => 'Stay connected',
        ExperienceView.raver => 'The estate is still open',
        ExperienceView.cypherpunk => 'skaists.dev/surfaces',
      };

  String get estateEmotion => switch (view) {
        ExperienceView.newBee =>
          'The garden they come from is still open — walk any door.',
        ExperienceView.raver =>
          'Full atlas. Families, then every live card.',
        ExperienceView.cypherpunk =>
          'estate.json v1 · 8 families · LIVE cards only · '
              'https://skaists.dev/{path}',
      };

  String get estateAtlasVerb => switch (view) {
        ExperienceView.newBee => 'Open the atlas',
        ExperienceView.raver => 'skaists.dev/surfaces',
        ExperienceView.cypherpunk => 'GET /surfaces/',
      };

  String get estateSnackAction => switch (view) {
        ExperienceView.newBee => 'Estate',
        ExperienceView.raver => 'Estate',
        ExperienceView.cypherpunk => 'atlas',
      };

  String get receiveDoorTitle => _l(
        'receiveDoorTitle.${view.name}',
        switch (view) {
          ExperienceView.newBee => 'Receive a piece',
          ExperienceView.raver => 'Receive',
          ExperienceView.cypherpunk => 'Import public address',
        },
      );

  String get receiveDoorBody => _l(
        'receiveDoorBody.${view.name}',
        switch (view) {
          ExperienceView.newBee =>
            'Someone sent you their work. Keep it here.',
          ExperienceView.raver => 'Verify a public piece, then Keep.',
          ExperienceView.cypherpunk =>
            'Read-only /public probe, then save a publicReference bookmark.',
        },
      );

  String get fileDoorTitle => _l(
        'fileDoorTitle.${view.name}',
        switch (view) {
          ExperienceView.newBee => 'Add from a file',
          ExperienceView.raver => 'Add a file',
          ExperienceView.cypherpunk => 'Import .datamap / .watch-list',
        },
      );

  String get fileDoorBody => _l(
        'fileDoorBody.${view.name}',
        switch (view) {
          ExperienceView.newBee =>
            'A private copy you already have — W@tch works out the rest.',
          ExperienceView.raver =>
            '.datamap or a W@tch bundle. Private, yours.',
          ExperienceView.cypherpunk =>
            '.datamap (ant upload), .watch-list bundle, or a bundle’s '
                'own .watch-list.datamap on Autonomi.',
        },
      );

  String get rightsLine => _l(
        'rights.${view.name}',
        switch (view) {
          ExperienceView.newBee =>
            'Keeping it here doesn’t let you give it away.',
          ExperienceView.raver =>
            'A public address is not permission to redistribute.',
          ExperienceView.cypherpunk =>
            'public address ≠ redistribute permission — publicReference '
                'is a source pointer, not a licence grant.',
        },
      );

  String get viewingStyle => _l('viewingStyle', 'Viewing style');

  String get adoptionPromise => _l('adoptionPromise', kAdoptionPromise);

  String get cypherpunkVerifyNote =>
      'GET /public/{address} · map verify + cache · no Autonomi write';

  /// Technical import paragraph — Cypherpunk only. New bee never sees it.
  String? get fileDoorTechnical => isCypherpunk
      ? 'Add to library takes any mix of: .datamap files made by uploading '
          'a video with the ant app, .watch-list bundles exported from W@tch, '
          'and a bundle’s own .watch-list.datamap when the bundle is stored '
          'on Autonomi. The app works out which is which.'
      : null;

  String get libraryRowsHint => switch (view) {
        ExperienceView.newBee =>
          'These rows are your home wall. Drag to reorder, untick to hide.',
        ExperienceView.raver =>
          'Home order — drag to reorder, untick to hide. Lighter rows fill themselves.',
        ExperienceView.cypherpunk =>
          'Rows appear on your home screen in this order — drag the handle '
              'to reorder, untick to hide. The lighter rows are built-in '
              '(they fill themselves); tap a list to edit its entries.',
      };

  String get emptyListsHint => switch (view) {
        ExperienceView.newBee =>
          'Nothing here yet. Receive a piece, or add from a file.',
        ExperienceView.raver =>
          'Empty library. Receive or add a file to start a list.',
        ExperienceView.cypherpunk =>
          'No lists yet. Use “Add to library” above — it creates lists '
              'as part of the import.',
      };

  String get badgeLabel => _l(
        'badgeLabel.${view.name}',
        switch (view) {
          ExperienceView.newBee => 'Shared',
          ExperienceView.raver => 'Public · kept',
          ExperienceView.cypherpunk => 'public XOR',
        },
      );

  String get badgeTooltip => switch (view) {
        ExperienceView.newBee =>
          'A piece someone shared. It stays on Autonomi with its maker.',
        ExperienceView.raver =>
          'Public reference — fetched on demand, no licence grant.',
        ExperienceView.cypherpunk =>
          'publicReference — streamed via GET /public/{address}, hash-verified.',
      };

  String get detailLine => switch (view) {
        ExperienceView.newBee =>
          'You’re keeping a shared piece. The maker still holds it.',
        ExperienceView.raver =>
          'Public piece — kept here, lives on Autonomi.',
        ExperienceView.cypherpunk =>
          'Public reference. Playback uses /public and never re-uploads.',
      };

  String get playerChip => switch (view) {
        ExperienceView.newBee => 'Shared piece',
        ExperienceView.raver => 'Public · kept',
        ExperienceView.cypherpunk => 'public XOR',
      };

  String get emptyLibraryTitle => _l(
        'emptyLibraryTitle.${view.name}',
        switch (view) {
          ExperienceView.newBee => 'Make something beautiful.',
          ExperienceView.raver => 'Your wall is waiting.',
          ExperienceView.cypherpunk => 'Your library is empty',
        },
      );

  String get emptyLibraryHint => _l(
        'emptyLibraryHint.${view.name}',
        switch (view) {
          ExperienceView.newBee =>
            'Give someone a piece of it. Stay connected to its maker.',
          ExperienceView.raver =>
            'Receive a piece, or add a file you already hold.',
          ExperienceView.cypherpunk =>
            'Use “Add to library” in Settings → My Media to get started.',
        },
      );

  /// Quiet line kept so existing empty-library tests and the hidden-lists
  /// variant still have a stable hook. New bee shows it under the promise.
  String get emptyLibraryQuiet => 'Your library is empty';

  String get allHiddenTitle => 'All your lists are hidden';
  String get allHiddenHint =>
      'Enable a list in Settings → My Media to show it here.';

  String listSharedSubtitle(int sharedCount, int total) {
    if (sharedCount <= 0) return '';
    return switch (view) {
      ExperienceView.newBee =>
        sharedCount == 1 ? ' · 1 shared piece' : ' · $sharedCount shared pieces',
      ExperienceView.raver => ' · $sharedCount public',
      ExperienceView.cypherpunk => ' · $sharedCount publicReference',
    };
  }
}

ExperienceCopy experienceCopyOf({Locale? locale}) =>
    ExperienceCopy(wiExperienceView.value, locale: locale);
