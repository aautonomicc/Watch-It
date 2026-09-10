# Android TV interaction

Android's UI mode selects the TV interface through `watchit/device`.
Large phones and tablets keep their existing interface. A missing capability
channel falls back to the ordinary interface.

## Remote navigation

- Home has labelled Library, Search and Settings actions. Library receives
  initial focus. Right, Right, Select opens Settings even with the TMDB banner
  dismissed. The page's shortcut Focus node is excluded from TV traversal.
- A foreground focus outline remains visible over posters, buttons and tiles.
  Scroll events reposition the outline; it does not run a continuous animation.
- The device-name dialog initially focuses Continue on TV. Up moves toward
  the name field; Left reaches Cancel. Phone keyboard Done also submits a
  nonempty name. The dialog owns and disposes its text controller.
- The video transport initially appears, then hides after six seconds while
  playing. Select or a direction reveals it and focuses Play/Pause; when
  visible, arrows move among actions and Select activates. Paused controls stay
  visible. Dedicated play/pause and seek keys also work with the overlay hidden.
- Seek actions move ten seconds, clamped to known duration. Next appears only
  when the existing episode flow supplies an adjacent item. Back hides the
  visible transport first; another Back leaves playback. The on-screen Back
  action leaves directly. Existing resume-point and playback code is retained.

## Screen fit and colour

Settings starts with TV display on televisions. Device-local margins default
to 5% on each edge and can be adjusted from 0–10% using buttons. The entire
Navigator, dialogs and playback sit within this area. This intentionally
reduces the picture area to avoid cropping on overscanning displays.

TV text scaling is at least 1.15; larger accessibility text scaling is retained.
The optional Grove palette uses soft green surfaces and retains W@tch blue,
its wordmark and the separate amber identity for public channels. It applies
in dark mode and is off by default; phone/profile appearance is unchanged.
The palette was developed with feedback from the BNR/skaists independent
validator, rather than replacing the upstream product identity.

## Verification

`flutter test test/tv_experience_test.dart test/home_layout_test.dart`
exercises native TV/phone detection and missing-channel fallback, screen margins,
remote activation and cancellation of the name dialog, whitespace validation,
phone keyboard submission, media keys, bounded seeking, overlay visibility,
Back behavior, conditional Next, and reaching Settings without the TMDB banner.
Several cases explicitly use Flutter's Android target platform.

The tests caught an invisible page-sized focus target that trapped directional
navigation, and an overflowing transport row when Next was present. The page
focus target is now excluded from traversal; the transport actions can wrap.

Use `scripts/build_android.sh --abis armeabi-v7a --test-app` for a separately
installed Google TV Streamer validation build. Real remote navigation, playback
and overscan checks belong to the device receipt, not the widget-test result.
No networking, VPN policy, wallet, account or sync protocol is changed here.
