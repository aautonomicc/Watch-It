# Creator credits and original sources

Open an item's detail page → **Credits & source**. Music tracks use the same
page through the album track's info button. View and copy the credit block,
open the original source or licence in a browser, or explicitly edit it.
Kid profiles can read credits but cannot edit them.

Fields: source title, creator/performers, original source URL, licence name,
licence URL, attribution/copyright notice, and changes to the original.
Unknown details stay blank. A credit record is supplied information, not an
identity check or a licence grant. Browsing it never automatically opens URLs.
Save and Cancel remain available below the scrolling form.

## Storage and interchange

- Database schema 14 adds `media_credit_records` (address + validated JSON).
  The identity is the exact file's derived address. Same-title performances
  do not share credit records; renaming/moving an entry keeps its credits.
- `.watch-list` export adds optional `credits.json`, version 1, with an
  `entries` array. Each row has `member` (the datamap basename) and the fields
  above in camelCase: `title`, `creator`, `sourceUrl`, `licenseName`,
  `licenseUrl`, `attribution`, `changes`.
- Only successfully exported datamaps carry credits. No unrelated library
  records, local file paths, or watch history are added to this member.
- Import resolves members through the actual imported datamaps. Missing or
  invalid datamaps cannot attach credits to an arbitrary library item.
- Import fills missing records only. Local edits, including an intentionally
  cleared record, win. Existing records do not change on channel refresh;
  this follows the bundle's existing gap-fill metadata behaviour.
- Channel manifests use the same build/parse/seed paths, including delta
  fetches. Older clients ignore the optional member. Clients that do not
  understand credits will not preserve it when they re-export a collection.
- My W@tch's live device synchronization has not been extended to this new
  table. Use a `.watch-list` bundle to transfer credits in this first slice.
- Optional member size: 5 MiB before decompression; individual fields are
  bounded. Malformed rows are skipped independently. Unknown versions are
  ignored. Source/licence links allow HTTP(S), without embedded credentials.

No YouTube downloader, automatic transcription, payment, public publishing,
training-data collection or BNR identity assertion is added to the app.
This general attribution record can describe films, performances, DJ sets,
yoga classes and dance lessons without introducing festival-specific fields.

## Next caption interaction

The founder selected YouTube's synchronized transcript as a useful interaction
reference: highlight the active cue, follow playback, select a timestamp to
seek, and keep original/translated text and review status distinguishable.
This is a subsequent player feature, not shipped by the credits change.
