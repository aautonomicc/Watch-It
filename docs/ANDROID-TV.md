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
- Up from Play/Pause reaches the timeline. Left/Right preview a destination
  ten seconds at a time, including held-key repeats, without seeking the player.
  Select commits the preview once. Back cancels it and keeps the controls open;
  moving off the timeline also abandons the preview. The controls stay visible
  while the timeline has focus. Pointer dragging previews until release, then
  commits one seek. The displayed preview is a timestamp, not a thumbnail.

## Screen fit and colour

Settings starts with TV display on televisions. Device-local margins default
to 5% on each edge and can be adjusted from 0–10% using buttons. The entire
Navigator, dialogs and playback sit within this area. This intentionally
reduces the picture area to avoid cropping on overscanning displays.

TV text scaling is at least 1.15; larger accessibility text scaling is retained.
The optional Grove palette uses soft green surfaces and retains W@tch blue,
its wordmark and the separate amber identity for public channels. It applies
in dark mode and is off by default; phone/profile appearance is unchanged.

## Audio and captions

The TV transport has an Audio & Captions button. The menu lists tracks actually
reported by the player, with their supplied title and language. Automatic audio
uses the file's default; Captions off explicitly disables subtitles. Metadata is
a label, not proof that a translation or dub was reviewed. An absent language is
not manufactured or silently replaced. Selection calls the existing player's
track API without reopening or seeking the movie.

Load caption file attaches a local UTF-8 SRT or WebVTT file, up to 2 MiB, through
the system file picker. The device must provide a compatible picker. Captions
are per playback, are not uploaded or synced, and unload with the media. A name
ending in `.lv.vtt` or `.en.srt`, for example, supplies a language label. Invalid
files produce a named error rather than a false successful selection.
Paste captions also accepts timed SRT/WebVTT text and explicitly reads the
clipboard only when Paste from clipboard is activated. It works without a
document picker. The Google TV Streamer reports a framework DocumentsStub, so
do not assume the file-picker action offers browsing on that device.

Captions sit above the transport while controls are visible, then return toward
the bottom of the picture when controls hide. Back closes the menu and returns
focus to Play/Pause. An existing next-episode countdown waits while the menu is
open so a picked file is not inadvertently attached to the next item.

## Voice search

The Search screen's app bar shows a microphone action on Android only —
phones, tablets and TV alike; other platforms are unchanged. Pressing it
starts the system speech recognizer (`RecognizerIntent` over the
`watchit/voice` channel). The app requests no microphone permission and
never records audio itself: the system dialog owns the microphone. On
Google TV devices the system recognizer is Google's, which may process
speech through Google's servers — that is a property of the device, not
of W@tch.

The single best transcription fills the query field and runs the search
immediately, skipping the usual typing debounce. Cancelling the dialog or
an empty result leaves any typed query untouched. A device with no
recognizer, or one that refuses to start, shows a snackbar pointing at
the keyboard; a second press while the dialog is already open is refused
rather than stacking recognizers. Recognized words only ever fill the
query — a result never opens media directly, so a misheard phrase costs
nothing. Keyboard Enter/Search likewise submits immediately and
unfocuses the field.

## Verification

`flutter test test/tv_experience_test.dart test/home_layout_test.dart test/tv_seek_test.dart`
exercises native TV/phone detection and missing-channel fallback, screen margins,
remote activation and cancellation of the name dialog, whitespace validation,
phone keyboard submission, media keys, bounded seeking, overlay visibility,
Back behavior, conditional Next, and reaching Settings without the TMDB banner.
Several cases explicitly use Flutter's Android target platform.
Timeline tests cover remote preview/commit, cancellation with Android Back,
focus departure, bounds, hidden-control timing, dragging and unknown duration.
`flutter test test/tv_tracks_test.dart` covers remote track selection, failure
state, menu return focus, bounded layout, caption placement and local-file input.
`flutter test test/search_screen_test.dart` covers voice search: a result fills
the query and searches without opening media, a cancelled dialog preserves the
typed query, and an unavailable recognizer leaves keyboard search usable.

The tests caught an invisible page-sized focus target that trapped directional
navigation, and an overflowing transport row when Next was present. The page
focus target is now excluded from traversal; the transport actions can wrap.

Use `scripts/build_android.sh --abis armeabi-v7a --test-app` for a separately
installed Google TV Streamer validation build. Real remote navigation, playback
and overscan checks belong to the device receipt, not the widget-test result.
No networking, VPN policy, wallet, account or sync protocol is changed here.
