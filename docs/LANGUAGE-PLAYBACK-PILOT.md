# Language and playback pilot

## Big Buck Bunny: repeatable player baseline

Use the existing starter-library item on each device. It exercises animation,
sound, startup, seeking and resume without adding another network upload. Its
limited speech does not make it a Latvian recognition benchmark.

The files under `fixtures/captions/` are authored engineering test cues. They
are **not dialogue transcripts, translations of the film, or human-reviewed
Latvian corpus data**. They are intended to exercise text rendering and track
switching. Keep TEST in the filename and visible cue text.

1. Start the existing film; record time to first moving frame and audible sound.
2. Open Audio & Captions using only the remote. Record the actual track list.
3. If the device has a document picker, select `bbb-TEST.en.vtt`, then select
   `bbb-TEST.lv.vtt`. Both files can be copied to its Download folder for this
   test. A picker missing on a TV is a capability limitation to report.
4. Verify the expected labelled cue appears, including Latvian diacritics.
   Seek into each cue and pause: captions must remain above the transport.
5. Turn captions off, close with Back, and resume using Select. Record any
   position discontinuity, unresponsive focus or audible interruption.
6. Test actual alternate audio on media that contains it. A single-audio file
   cannot validate dub switching, language correctness or alternate-track sync.

## Samsung A16 startup report

The independent validator reports a long wait or apparent stall before playback
on the official mobile alpha.95 app. The same starter film plays well on the
Google TV Streamer validation build. The VPN was off during the reported mobile
comparison. This is a user report, not a reproduced root cause or a phone fix.

Record app build, Wi-Fi, network state, time to first retrieved bytes, time to
first frame, whether the retrieved-byte display changes, and any exact error.
Compare first use and immediate replay separately: a warm TV cache and a cold
phone are different conditions. A peer count alone does not prove the needed
chunks are reachable. Avoid wiping app data or unlinking devices to benchmark.

Source points for diagnostics: `PlayerScreen.initState` opens the player after
lifting an idle network pause, sets a 300-second native network timeout, and
polls `EmbeddedClient.health` while buffering. The byte counter is client-wide;
it is not a per-movie progress total. The native engine has chunk caching and
adaptive prefetch. Capture evidence before changing transport or buffer policy.

## Latvian speech pilot

Use a short source video/audio file supplied for the pilot. YouTube's offline
Download feature is not an ordinary importable media file. Preserve source,
language, source time range and permission/provenance alongside the work.

The intended sequence is timed Latvian ASR draft, native-speaker correction,
held-out error and blind meaning review, translated caption draft and review,
then TV playback and timing checks. The original recording remains available.
BNR's existing text corpus may guide terminology; it is not an aligned speech
reference or proof of recognition accuracy. No WER or meaning score is claimed
until a reference and independent assessment exist.

Generated dubbing, persistent sidecar bundles, caption delivery over device
sync/Channels, and BNR public channel cards remain subsequent work. This player
change selects existing tracks and explicitly attached caption files; it does
not generate speech, attest translations, publish videos or train on libraries.
