# Plan: list picker (checkboxes) for .datamap import — replaces the typed "Add to which list?" box

Status: IMPLEMENTED 2026-08-01 (ships in alpha.42).

## Problem
Media Lists → Import → "Add .datamap files": after picking files, the app shows
`promptForText('Add to which list?')` — a free-typed text box prefilled
"Imported". Typing an existing list's name works but is error-prone and then
routes through the merge/new/skip clash dialog. The user wants to *pick* the
target from the lists that already exist.

## Desired UX (per user)
A dialog listing the existing media lists with a **checkbox** per list; check
one (or more) and confirm to add the imported entries to the selected list(s).
Below the list: a **"Create new list"** button.

## Design

### New dialog: `pickTargetLists` (media_lists_screen.dart, or widgets/list_picker_dialog.dart)
- `Future<List<String>?> pickTargetLists(BuildContext, List<MediaList> lists)`
  → returns the chosen list **titles** (existing and/or newly created), or
  null on cancel.
- Body: scrollable `CheckboxListTile` per list, in current library order,
  including hidden (disabled) lists — hidden ≠ deleted. Show entry count as
  subtitle (`12 entries`). WiTokens styling like `_resolveNameClash`
  (ink2 background, bone/boneDim text, accent checkbox).
- Multi-select is allowed: checking N lists adds the same entries to each
  (entries are per-list rows keyed by derived address; downloads/history/
  metadata are address-keyed globally, so cross-list duplication is safe and
  already possible via bundle import).
- Footer button **"Create new list"** (OutlinedButton, full-width, below the
  checklist): opens the existing `promptForText('New media list')`; on a
  non-empty title, append it to the dialog's local list as a checked
  pseudo-entry (0 entries subtitle) — it is NOT saved to the store until
  import confirms, so cancel costs nothing. Duplicate title (case-insensitive
  vs existing + already-added) → reuse/check that row instead of adding twice.
- Actions: Cancel / **Add** (accent). Add disabled while nothing is checked.
- Empty library edge case: no lists yet → skip the checklist entirely and
  fall straight into the "Create new list" prompt (behaviour ≈ today's
  prefilled "Imported" box, keep `initial: 'Imported'` there).

### Call-site changes (media_lists_screen.dart)
Both loose-.datamap prompts switch from `promptForText` to `pickTargetLists`:
1. `_importDatamapFiles()` (~line 122) — the flow the user described.
2. `_finishImportBytes()` loose-.datamap branch (~line 211) — same prompt,
   reached when a .datamap is picked via the bundle/file path; keep the two
   flows identical.

`_importDatamaps` gains `required List<String> listTitles` (was single
`listTitle`) and builds one `ParsedMediaList` per title sharing the same
entries list.

Unchanged: the network-fetched-bundle default-title prompt (~line 248) — that
names a *new* list for unclaimed bundle members, different semantics; and the
bundle clash dialog.

### Clash dialog skipped for checked existing lists
Today `_applyImportedLists` fires the merge/new/skip dialog whenever the title
matches an existing list. When the user explicitly checked that list, the
question is already answered → merge silently (duplicate addresses skipped,
counted in the existing snackbar). Implement as a
`mergeExisting: Set<String>` (lowercased titles) parameter on
`_applyImportedLists`: titles in the set take the `action == 'merge'` branch
directly. Titles NOT in the set (bundle imports) keep today's dialog. New
titles created in the dialog fall through to the "create" branch as now.

## Files touched
- `app/lib/screens/media_lists_screen.dart` — dialog + 2 call sites +
  `_importDatamaps`/`_applyImportedLists` signatures (~120 lines).
- (optional) `app/lib/widgets/list_picker_dialog.dart` if extracted.

## Tests (app/, `flutter test`)
- Update `test/list_import_flow_test.dart` "Add .datamap files" group
  (~line 290): dialog now shows checkboxes — cover:
  1. check an existing list → entries merged, NO clash dialog, snackbar
     reports merge; duplicates skipped.
  2. "Create new list" → type title → new list created with entries
     (replaces today's prefilled-"Imported" assertions).
  3. multi-select two lists → entries in both.
  4. cancel → library unchanged.
  5. empty-library path → straight to the new-list prompt.
- Existing bundle-import tests must stay green (clash dialog unchanged there).

## Estimate
~half a day incl. tests. No Rust, no schema, no release needed on its own —
fold into the next alpha (.42).
