# watchit-upload — the bulk-upload CLI

**Status: v1 implemented 2026-09-01** (the ten-part planning series is in
the repo history). Dart package at `cli/`; shares its file-name
parser/sanitizer/generator with the app via `packages/watchit_naming`, so
a name the CLI writes always parses back to the intended title/year/ids
in W@tch — parser drift is impossible by construction.

## What it does

Turns a messy folder of media into canonically named, paid, private
Autonomi uploads plus a `.watch-list` bundle, in two phases over a
persistent manifest:

```
watchit-upload prepare --list-name "My Films" ~/staging/films
# … interactive matching, sidecar edits, cost estimate …
watchit-upload upload --manifest watchit-manifest.yaml
# … walk away; Telegram ping when done …
```

- **`prepare`** (interactive, pays nothing): scans folders, sha256s each
  file once, dedupes against the global **content-hash ledger**
  (`~/.watchit-upload/ledger.jsonl` — a file already uploaded under any
  name/path is skipped by quote/pay/upload but still lands in the output
  bundle), classifies music vs video via ffprobe stream inspection,
  matches against the databases, **regenerates the canonical name from
  the database's own data** (never sanitizes the messy source name),
  fetches cover/poster art as match verification, writes pre-filled
  `.watchit.yaml` sidecar skeletons for anything it can't place, and
  finishes with a per-chunk-scaled cost estimate + wallet balance check
  so payment surprises can't kill an overnight run.
- **`upload`** (zero prompts, walk-away, needs ant's `SECRET_KEY`
  exported): uploads every `ready` entry under its final name via
  `ant file upload` (private — the datamap is the product), saves the
  manifest after every state change (crash/network drop → re-run resumes,
  uploaded entries skip), appends the ledger line the moment an entry
  flips to `uploaded`, retries failures once at the end, optionally
  proves retrievability with a real network `get_range` through a running
  watchit_core devserver, then emits `<list name>.watch-list` and pings
  Telegram (`~/telegram-bot/.env` credentials).
- **`ledger list` / `ledger export`**: inspect the ledger; rebuild a
  bundle offline from ledger rows — disaster recovery for a lost list.

## Matching

- **Music** (match order): embedded MusicBrainz release id from Picard
  tags → AcoustID/chromaprint fingerprint (`fpcalc` + free
  `acoustid_key`, optional) → MusicBrainz Lucene search from tags/name
  guess. Names: `Artist - Album (Year) - NN Title {mbid-<release>}.ext`,
  `D-NN` track prefix only when the release has multiple discs,
  compilations as the MB artist-credit verbatim ("Various Artists"),
  square CAA front cover as-is. A `.cue` beside a lone audio file is
  skipped with a "split first" warning.
- **Video**: name parse (shared parser) → TMDB exact `/find` by embedded
  IMDb id, else title/year search scored by similarity + year. Names per
  docs/NAMING.md with the real probed resolution tag.
- **Confidence**: id-backed matches auto-accept; search matches always
  get a one-keystroke confirm (uploads are paid + immutable). The confirm
  prompt also offers manual search pick-lists, paste-an-id (MBID/IMDb
  URL/`tv:123`), music↔video toggle, and skip. `--yes` runs
  non-interactively (unconfirmed matches become sidecar skeletons).
- **Case B — not in any database** (home video, unreleased music): fill
  the sidecar's manual fields. The name gets **no id tag** (the app rule:
  no id tag → no metadata APIs, baked-in data wins) and the description +
  artwork ride the bundle as a `userEdited` metadata row + poster —
  exactly the shape the app's Edit-details exports, so recipients render
  it offline and later TMDB matches never overwrite it.

## Config — `~/.watchit-upload/config.yaml`

```yaml
tmdb_key: …        # v3 key or v4 read token; video matching
acoustid_key: …    # free, acoustid.org; enables fingerprinting
server_base: http://127.0.0.1:PORT   # watchit_core devserver for the
                                     # post-upload get_range check
```

Env overrides: `TMDB_API_KEY`, `ACOUSTID_API_KEY`, `WATCHIT_SERVER`.
API keys are CLI-side by design — the app needs none of this.
MusicBrainz/CAA need no key (1 req/s throttle + disk cache built in).

## Running

```
cd cli && dart pub get
dart run watchit_upload:watchit_upload --help
# or compile once:
dart compile exe bin/watchit_upload.dart -o ~/.local/bin/watchit-upload
```

Tests: `dart test` in `cli/` and in `packages/watchit_naming/`
(the golden corpus pins generate→parse round-trips).

## Not yet done

- Real paid upload not yet exercised (needs a funded `SECRET_KEY`); the
  whole loop is tested against a fake `ant` shim + the live quote path.
- Dogfood task from the plan: regenerate the shipped public-domain
  bundle + NOTLD bundle through the CLI (needs the source media + funded
  wallet; chunk-level dedup makes re-uploads of held content free).
- App-side music support (`type: music`, square album grid, MBID
  runtime metadata) is a separate future task — music uploads today
  render as generic entries with their baked-in bundle metadata.
