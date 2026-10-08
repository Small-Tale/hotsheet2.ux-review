# 07 — Review session and submitting

Status: implemented on macOS (`HS2-CRJDJ8`), with Submit Review from the editor
(`HS2-6HA14G`), browsing, reopening, and discarding older drafts (§7.9–7.10, `HS2-WE30PY`), and
adding a review to an existing ticket (§7.2.1, `HS2-E3001H`).
Opening the ticket in Hot Sheet itself is `HS2-ZEF6XD`.

A review session is the last step of a review: the captures of the current draft
([04-capture.md](04-capture.md) §4.6), annotated in the editor
([06-annotation-editor.md](06-annotation-editor.md)), get a title and summary and are filed as
one Hot Sheet intake ticket ([03-hotsheet-integration.md](03-hotsheet-integration.md)), or added
to a ticket that already exists.

## 7.1 Opening

In the UX Review (annotation editor) window, **Submit Review…** in the tool bar or the File menu
(⌘↩, `HS2-6HA14G`) saves the editor and opens the **Submit Review** window on *that editor's*
draft, which need not be the current one (each draft has its own window, docs/05 §5.1.1). With
no review window in front, File › Submit Review… opens it on the current draft (`HS2-80CTK8`). **Open Session** in the Draft
Reviews window (§7.9) opens it on any other draft.

- Each draft gets one window. Choosing the item again brings it forward and re-reads the draft.
- With no draft, an alert says "Nothing to submit yet".
- Closing the window saves the title and summary into the draft. Nothing else changes.

## 7.2 The window

| Area | Contents |
| --- | --- |
| Review | **Title** (required) and **Summary** (Markdown, optional). Typing is saved into the draft's `review.json` half a second after it stops. "Give the review a title." shows under a blank title |
| Captures (N) | One row per capture in review order, **as it will be filed** (`SubmissionPreview`, `HS2-64P9DT`): thumbnail (the cropped part of a cropped image; a movie's frame at its trim start, cut to its crop, with a play badge), file name, pixel size as filed ("cropped" after a crop of an image or movie; "scaled for Claude" when it is downscaled for AI, as in "2576×1449 scaled for Claude", §7.5.1), duration ("trimmed" after a trim), the number of annotations filed with it, and source app. When a crop or trim leaves annotations out, a line says so, such as "2 annotations outside the crop will be left out" ("the crop or trim" for a movie with both). Nothing is cropped or trimmed until submitting (§7.5); the preview reads `edits.json`. A capture with a problem shows it in orange under its details (§7.3). **Annotate** opens the editor on that capture; **Annotate…** in the header opens it on the first. The trash button removes the capture after a confirmation |
| Hot Sheet project | The target project's name and the store it files into, or the problem (§7.6). **Change** lists recent projects and **Choose Folder…** |
| Ticket | **Submit as** **New ticket** (the default) or **Add to existing ticket**, and for the latter the ticket field and its lookup (§7.2.1) |
| Before submitting | Only when the review has a problem that belongs to no field or capture (an unsupported format, duplicate ids) |
| Footer | **Discard Review…** (§7.9; disabled while submitting), the counts as filed ("3 captures · 4 annotations", plus "(2 left out)" when a crop or trim leaves some out), the only remaining problem, or "N things to fix before submitting"; progress while submitting; the failure (§7.5); and **Submit to Hot Sheet** (default button, Return), which reads **Try Again** after a failure |

New captures and editor saves appear while the window is open: it follows the draft-changed
notification the capture pipeline and the editor already post.

**Removing a capture** deletes its file, every annotation on it, its crop or trim in
`edits.json`, and any kept original under `originals/` from an older draft. An open editor on the draft stays open and drops that
capture, its annotations, and its undo history (docs/06 §6.7); its unsaved edits to other
captures are kept. Numbering of later
captures continues: a removed `capture-2.png` leaves a gap, and removing the *last* capture
does not free its file name or media id either. The draft's `numbering.json` records the highest
`capture-N` and `mN` used once a capture is removed (`DraftNumbering`, `HS2-44ZXNE`); drafts that
never removed one have no such file.

After a successful submission the window shows **Filed as HS-…**, the title, what was attached,
and **Copy Slug**, **Show Ticket File** (the ticket's Markdown file in the store, revealed in
Finder), and **Done**. After adding to an existing ticket it shows **Added to HS-…**, that
ticket's title, and that the review is a note on it, with the same buttons.

### 7.2.1 Adding to an existing ticket

Sometimes a review is feedback on, or extra information for, a ticket that already exists
(`HS2-E3001H`). **Add to existing ticket** files the draft into that ticket instead of a new
intake ticket: all of it, or the part chosen under **Add** (§7.2.2).

- **The field** takes a slug (`HS2-ABC123`, any case) or a pasted ticket reference: a line from
  `hotsheet-cli ls`, a ticket file path, a link, or a ULID
  ([03-hotsheet-integration.md](03-hotsheet-integration.md) §3.5).
- **The lookup** runs `hotsheet-cli show` in the project's store 0.3 s after typing stops, and
  again when the project changes. Under the field it shows "Looking up HS-…", the found ticket's
  slug, “title”, and status, or the problem (§7.3). A result for text that has since changed, or
  for another store, is ignored.
- **Switching** to New ticket and back keeps the typed ticket and its lookup.
- **Submitting** reads **Add to HS-…**. It attaches the media plus `review.json` as one batch,
  then adds one note to the ticket (§7.5, docs/03 §3.5). The progress reads "Attaching N files to
  HS-…", then "Adding the review note to HS-…".
- **Reopening** the window on a draft whose media is already attached to a ticket but whose note
  is missing (§7.5) starts on **Add to existing ticket** with that ticket filled in.

### 7.2.2 Adding only part of a review

Under the ticket field, **Add** summarizes what goes to the ticket ("Everything: 3 captures, 4
annotations", or "2 of 3 captures · 2 of 4 annotations") and opens a checklist (`HS2-00TXV6`):

- Each capture has a checkbox, with one per annotation under it. Unchecking a capture leaves its
  annotations out too. Checking an annotation of an unchecked capture checks the capture with
  only that annotation. **Add Everything** puts everything back.
- Checked annotations show the number the note gives them: the sent part is numbered #1, #2, …
  in review order, in the note and in the `review.json` attached with it. Unchecked ones read
  "Not added".
- The choice lists what is left out (`ReviewSelection`), so captures added later are included.
  Ids that leave the draft are forgotten. It applies only to an existing ticket; a new ticket
  always gets the whole review.
- Leaving every capture out is an issue: "Choose at least one capture to add." The footer
  counts only what will be sent.
- Only the chosen part is staged, always in the hidden `.submission/` folder, so the draft's
  own `review.json` is never changed by submitting (§7.5).
- **Afterwards the draft keeps the rest.** Every annotation that was sent is removed from the
  draft. So is every sent capture with no annotation left; a sent capture that still has an
  unsent annotation stays, so it can be sent with it later. When nothing is left, the draft is
  deleted as usual. The result says "The draft keeps what wasn't added (N captures) for later."
- A half-finished submission (§7.5) records its part in `submission.json` (`selection`), and
  Try Again sends that same part. The checklist shows it, disabled, until the submission
  finishes.

## 7.3 What blocks submitting

`SessionIssue.all` lists every problem in a stable order. Submit is enabled only when there
are none.

1. No captures: "Add at least one capture."
2. Blank title (whitespace only counts as blank).
3. A capture whose file is gone from the draft folder: "… is missing from the draft folder.
   Remove it from the review."
4. Every `ReviewBundle.validate()` issue ([02-review-bundle.md](02-review-bundle.md) §2.7), in its
   order, except "no media" (item 1 covers it). Annotations are named by their review number,
   as in the editor and the ticket, for example "Annotation #2 runs past the end of its video."
5. Hot Sheet can't take the review: no `hotsheet-cli`, no project, or no store
   (`HotSheetStatus`, [03-hotsheet-integration.md](03-hotsheet-integration.md) §3.1).
6. Adding to an existing ticket (§7.2.1), until a found, open ticket is confirmed:
   - "Enter the ticket to add this review to."
   - "“…” isn't a ticket. Enter a slug such as HS-ABC123."
   - "Looking up HS-…"
   - "No ticket HS-… in <store>."
   - "HS-… is deleted." (or moved) "Choose an open ticket."
   - "Couldn't look up HS-…: <reason>"

   With no store to look in, only item 5 shows.

Issues about one capture (a missing file, an annotation problem) show on that capture's row;
the title issue under the title; the Hot Sheet problem under the project; the ticket issue under
the ticket field.

## 7.4 Session states

`ReviewSession` (UXReviewKit) is a pure state machine; the window and `--submit` drive it.

```
editing ⇄ failed                        edits, removals, refreshes, project and ticket changes
editing|failed → submitting(creatingTicket → attachingMedia) → submitted   (terminal)
                 submitting(attachingMedia → addingNote)     ↘ failed      (existing ticket)
```

The destination is part of the same machine (`ReviewSession+Destination.swift`): New ticket or
existing ticket, the typed text, and its lookup:

```
empty ⇄ unrecognized ⇄ looking(ref, store) → found | notFound | failed
                       noStore(ref)  (no store to look in)
```

- Typing recomputes the state. Text that parses to the reference already looked up (or being
  looked up) in the same store keeps its state, so `hs-1abc` after `HS-1ABC` doesn't look up
  again.
- A project change looks the reference up in the new store (or `noStore`).
- A lookup result applies only while the session is still `looking` for that reference in that
  store.
- Destination changes, typing, and results are ignored while submitting and after.

- **Submit** starts only from `editing` or `failed`, and only with no issues.
- While submitting, everything else is ignored: a second Submit, edits, removals, draft
  refreshes, and project changes. The fields, the capture list, and the project are disabled,
  so what is shown is what is filed.
- `submitted` accepts nothing more; the window only offers its result actions.
- A refresh from disk keeps the title and summary being typed.

## 7.5 Staging and clean-up

The draft folder holds everything from the first capture on: the captured files (never
rewritten while drafting), `review.json`, and `edits.json` with each crop and trim (docs/06 §6.6,
§6.10). `DraftSubmitter` (UXReviewKit) files it:

1. Saves the title (trimmed) and summary into the draft, under the store's lock.
2. **Applies crops and trims** (`SubmissionStaging`, `HS2-71SSJG`). With none, the draft folder
   itself is filed. Otherwise a hidden `Drafts/<id>/.submission/` folder gets a cropped PNG for
   each cropped image, a movie trimmed and cropped in one export pass for each trimmed or
   cropped one (`VideoTrim.export(_:range:crop:size:to:)`, `HS2-M03YP2`), and copies of the rest. The bundle
   gets the cropped sizes and trimmed lengths, annotations clipped to them, and those entirely
   outside left out. With **Downscale for AI** on (the default), each capture is then scaled
   down for the project's AI tool (§7.5.1). The folder is removed afterwards, whatever happens.
   A missing or unreadable file fails here, before anything is created. Drafts from before this
   convert first (docs/06 §6.6).
3. Submits with `ReviewSubmitter` ([03-hotsheet-integration.md](03-hotsheet-integration.md) §3.2):
   validate, write `review.json`, `new`, then one `attach` batch of the media plus `review.json`.
   `edits.json`, `numbering.json`, `originals/`, and `submission.json` are never attached.
4. **On success** it deletes the draft folder. When it was the current draft, the `current`
   pointer goes too, so the next capture starts a new review. If the folder can't be deleted,
   the result says so (`draftRemoved: false`); it is no longer current either way.
5. **When the ticket was created but the attach failed**, the draft is kept and
   `Drafts/<id>/submission.json` records the ticket (`storePath`, `ticket {slug, file}`,
   `createdAt`). The failure names the ticket, and **Try Again** attaches to it instead of
   creating a second one. A retry into a different store ignores the record and starts over.
   When the attach stopped part-way (`hotsheet-cli attach` is not atomic, docs/03 §3.2), the
   record also has `partialAttach` (`batchID` and `storedNames`, draft file name → stored name),
   and Try Again attaches only the files not yet attached, into the same batch, so none is
   attached twice (`HS2-QNWMKF`). A retry that again stops part-way adds to the record; one that
   attaches nothing leaves it as it was.
6. **Any other failure** (validation, a missing file, `hotsheet-cli new` failing) keeps the
   draft unchanged apart from the saved title and summary.

### 7.5.1 Downscaling for AI

Most AI tools can't use a full Mac desktop capture: they shrink it themselves, so small text
gets lost and the coordinates they report don't match the file. With Settings › Submitting ›
**Downscale images and videos for AI** on (the default, docs/05 §5.3), submitting files each
capture at the size the target project's default AI tool reads well (`HS2-PT8PM6`).

- **Only the filed copies change.** The draft keeps its full-size files. Scaling happens in
  `SubmissionStaging` after the crop or trim. The aspect ratio is kept, and a capture is never
  scaled up. A capture that needs no crop, trim, or scaling is filed as it is.
- **Images** are re-encoded as PNG at the new size.
- **Movies** are exported once, with the trim, the crop, and the scale together
  (`VideoTrim.export(_:range:crop:size:to:)`): one video composition cuts out the crop, then
  scales it to the filed size.
  They keep the recorded frame rate, else the movie's nominal one.
- **Annotations stay as they are.** Their coordinates are normalized to the media
  ([02-review-bundle.md](02-review-bundle.md) §2.3), so only the bundle's `pixelWidth` and
  `pixelHeight` change, and they match the filed files.
- **The tool** comes from `hotsheet-cli -C <store> ai-settings get --json`
  ([03-hotsheet-integration.md](03-hotsheet-integration.md) §3.6). The Submit Review window
  detects it when it opens and again when the project changes. `--submit` detects it at submit
  time.

| Tool (model) | Filed size (`MediaScaleTarget`) |
| --- | --- |
| `claude`, high-resolution tier: Claude 4.7 and later. The aliases `opus`, `sonnet`, `fable`, and `mythos` name current models, as do ids like `claude-opus-4-7` and `claude-sonnet-5-5` | The largest aspect-preserving size whose sides, rounded up to a multiple of 28, are at most **2576 px**, and whose visual tokens ⌈w/28⌉ × ⌈h/28⌉ are at most **4784** (3840×2160 → 2576×1449) |
| `claude`, standard tier: `haiku` (Haiku 4.5), older ids such as `claude-opus-4-6` and `claude-3-5-sonnet-…`, and no or an unknown model | The same rule with **1568 px** and **1568** tokens (1920×1080 → 1456×819; a 1075×1520 portrait page → 924×1307) |
| `codex` | Fits within **2048 × 2048** |
| Any other tool, an old CLI without `ai-settings`, or any failure | **2048 px** on the longest side |

- **The Claude rule** is Claude's own resize, from the Vision docs ("Resolution and token
  cost" for the tiers, "How Claude resizes and pads images" for the reference implementation):
  a binary search along the long edge, with the short edge rounded half to even. A file of
  exactly that size reaches Claude unresized, so the pixel coordinates it returns map 1:1 onto
  the attachment.
- **A movie's frames** follow the same rule as an image (for Claude, the token budget applies to
  each frame an AI extracts). The sides are then rounded down to even numbers for H.264, so a
  3840×2160 recording becomes 2576×1448 on the high-resolution tier.
- **Where it shows.** The Submit Review list shows the filed size ("2048×1280 scaled for Codex",
  or "… cropped, scaled for Claude"). `--submit` reports `scaledCaptures` (draft file names) and
  `scaledFor` (`Claude`, `Codex`, or `AI`), and `--downscale on|off` overrides the setting for
  one run (§7.8).

**Adding to an existing ticket** (§7.2.1) uses the same steps with the writes of docs/03 §3.5:
one `attach` batch of the media plus `review.json`, then one note.

- **On success** the draft is deleted as in item 3.
- **When the attach worked but the note failed**, the draft is kept and `submission.json`
  records the ticket plus `attachedNames` (each draft file name → the name Hot Sheet stored it
  under). The failure says the media is attached, and **Try Again** adds only the note, citing
  those names. The batch is never attached twice and the note is never added twice.
- **When the attach failed before any file**, nothing is recorded and Try Again starts over.
- **When the attach stopped part-way**, the draft is kept and `submission.json` records the
  ticket, `toExistingTicket: true`, and `partialAttach`. The failure says some media is attached,
  and Try Again attaches only the rest into the same batch, then adds the note.
- A record is reused only for the same kind of submission, ticket, and store. A note-pending
  record is never treated as a created ticket, and a created-ticket record is never reused for an
  existing ticket. A ticket created by an earlier failed New ticket submission stays in Hot Sheet,
  without (all of) its media, if the review then goes to an existing ticket. The result names it
  (`abandonedTicket`, `HS2-3SVGZ3`): "HS-… was created by an earlier try that failed, and doesn't
  have this review." **Move HS-… to Hot Sheet's Trash…** asks first, then sets its status to
  `deleted` (`hotsheet-cli edit --status=deleted`; Hot Sheet can restore it). Nothing is deleted
  without that click; `--submit` only reports it.
- The Draft Reviews row reads "Media attached to HS-…; the review note isn't added yet" (or,
  part-way, "Some media attached to HS-…; the rest and the review note aren't added yet"), and
  Discard says the media stays attached. Opening the session on such a draft selects **Add to
  existing ticket** with that ticket.
- Re-submitting with the same media but changed crops or trims after a partial attach keeps the
  files already attached: the retry only sends the rest.

Deleting a draft that isn't directly inside the drafts folder (the folder itself, `current`, a
hidden name, a nested folder) is refused.

## 7.6 Target project

The session files into the project chosen in this window (**Change**), which starts on the last
project used: project selection happens when submitting (`HS2-80CTK8`; the menu bar menu no
longer has a project chooser). `UXReview --project <dir>` overrides it for one run. **Change** saves it as `projectDirectory` in the app's defaults
([05-start-and-settings.md](05-start-and-settings.md) §5.3) and add it to `recentProjects`:

- JSON `{"paths": [...]}`, most recent first, at most 5, deduplicated after standardizing
  (`/a/b/` and `/a/b` are one entry).
- **Change** lists the recent projects that still exist, except the current one.
- A successful submission also records its project.
- An unreadable value counts as an empty list.

Changing the project in one session window refreshes every open session window.

## 7.7 Not yet

- Open the ticket in Hot Sheet (web UI or app) when it is running: `HS2-ZEF6XD`.
- Downscaling for AI (§7.5.1):
  - Tell the AI a capture was scaled (its original size in the ticket and `review.json`): `HS2-KMB528`.
  - Codex's patch budget beyond 2048 × 2048: `HS2-Q0R78W`.
  - Claude's rule for Claude models run by other tools: `HS2-8G9F3R`.

## 7.8 Headless submit

```
UXReview --submit [--drafts-dir DIR] [--draft NAME] [--project DIR] [--title T] [--summary S] [--to-ticket REF [--exclude IDS]]
                  [--downscale on|off]
```

Files the current draft (or the draft named by `--draft`) through the same `ReviewSession`
rules and `DraftSubmitter` as the window, and prints one JSON object. `--title` and `--summary`
replace the draft's own before checking. `--to-ticket` adds the review to that existing ticket
(§7.2.1). It takes the same slugs and references as the window's field, and runs the same lookup
before checking, so an unknown ticket is an `invalidReview` issue. `--exclude m2,a3` (with
`--to-ticket` only) leaves those captures and annotations out (§7.2.2); an id that is neither is
`invalidArguments`, and excluding every capture is an `invalidReview` issue. `--downscale on|off`
replaces the Downscale for AI setting for this submission (§7.5.1).

- On success: `status: "submitted"`, `slug`, `ticketFile`, `storePath`, `title`, `mediaCount`,
  `annotationCount`, `draftDirectory`, `draftRemoved`, `addedToExistingTicket`, and `ticketTitle`
  (the existing ticket's title, with `--to-ticket`), plus `remainingCaptures` when part of the
  review was added and the draft keeps the rest, and `abandonedTicket` when an earlier failed New
  ticket try left a ticket behind (§7.5; it is not deleted), plus `scaledCaptures` and `scaledFor`
  when captures were scaled down for AI (§7.5.1).
- On failure: `status: "error"`, `error`, `message`, plus `issues` (messages, for
  `invalidReview`), `createdTicket` (when the ticket exists but the attach failed), `attachedTo`
  (when the media is attached to the existing ticket but the note failed, or some of it before
  the attach failed), `partlyAttached: true` (some files were attached before the attach failed;
  the retry attaches the rest), and `draftDirectory`.

`--drafts` (§7.10) adds `pendingNoteOnly: true` to a draft whose pending ticket is such an
existing ticket, `pendingToExisting: true` when the pending ticket is an existing one, and
`pendingPartlyAttached: true` when only some files are attached.

| Exit code | `error` | Meaning |
| --- | --- | --- |
| 0 | | Submitted; the draft is deleted |
| 2 | `invalidArguments`, `noDraft`, `invalidReview` | Bad arguments (including a `--to-ticket` with no slug), no such draft, or the review has issues (§7.3, including no such ticket). Nothing is written to Hot Sheet |
| 3 | `hotSheetUnavailable` | No CLI, project, or store |
| 5 | `submitFailed` | Hot Sheet refused; the draft is kept (§7.5) |

`scripts/app-e2e.sh` uses it to file a two-capture session into a throwaway store, including an
attach failure (a wrapper CLI that fails the first `attach`) followed by a retry that reuses the
created ticket. It then adds a draft to an existing ticket that already has a `capture-1.png`:
a reference with no slug and an unknown ticket exit 2; a wrapper CLI failing the first `edit`
exits 5 with `attachedTo`; and the retry adds exactly one note citing `capture-1 (2).png`, with one
batch and no new ticket. For AI downscaling (§7.5.1), it imports a 3840×2400 image (and, for
Claude, a large recording) into fresh drafts. These are filed through a wrapper CLI that reports
the project's AI tool: Claude Haiku (standard tier: the image and the recording at the docs'
sizes, with even sides for the movie), Codex (2048×1280), and a CLI without `ai-settings`
(2048×1280). Each check confirms that the filed PNG, the movie (with `ffprobe`), and the filed
`review.json` sizes match, and that the annotations are the draft's. With `--downscale off`, or
the setting off, the full 3840×2400 file is filed.

## 7.9 Draft reviews

**Draft Reviews…** (File or Window menu, ⇧⌘O, docs/05 §5.1.1) opens one **Draft Reviews** window
listing every draft review on disk ([04-capture.md](04-capture.md) §4.6): the current one, the
ones set aside with **New Review** (⌘N), one whose ticket was created but whose media wasn't attached (§7.5), and
one whose folder could not be deleted after submitting (`draftRemoved: false`).

- **Order:** most recently edited first (review.json's modification date, or the folder's when
  review.json is missing). Equal dates sort by folder name in reverse (draft ids start with their date).
- **Each row:** the title, a **Current** badge for the draft new captures go to, the capture and
  annotation counts, and when it was last edited. In orange: "HS-… was created; its media isn't
  attached yet" (or "…; only some of its media is attached") for a pending submission, the
  existing-ticket texts of §7.5, or "Can't be opened: review.json is missing." /
  "… can't be read." for a broken draft. A broken draft is titled by its folder name.
- **Open Session:** the Submit Review window on that draft (one window per draft, §7.1).
  Submitting it never changes which draft is current unless it *was* current (§7.5).
- **Annotate:** the annotation editor on that draft. Disabled with no captures.
- **Show in Finder** (folder button) reveals the draft folder; **Show Drafts Folder** in the
  footer reveals the drafts folder.
- **Discard** (trash button) asks first. Open Session and Annotate are disabled for a broken
  draft, but Show in Finder and Discard still work.
- Not listed: hidden entries, the `current` pointer, plain files, and symbolic links.
- The list re-reads when a draft changes (a capture, a removal, a submission, a discard, Start
  New Review) and whenever the window comes to the front.
- With no drafts, the window says "No Draft Reviews" and explains where drafts come from.

**Discarding** (the Draft Reviews window's trash button, or **Discard Review…** in the Submit
Review window):

1. A confirmation names the review and says its captures and annotations go to the Trash with
   the folder. When a ticket was already created (§7.5), it adds that discarding doesn't delete
   that ticket. For the current draft, it adds that the next capture starts a new review.
   **Move to Trash** is marked destructive; **Cancel** is the default button (Return), so a stray
   Return never discards.
2. An open editor on the draft is closed (saving first, docs/06 §6.7), then its Submit Review
   window (saving the title and summary). Nothing is written into the draft after it moves.
3. `ReviewDraftStore.discard` moves the folder to the Trash, where it can be put back from
   Finder. When it was the current draft, the `current` pointer goes too, so the next capture
   starts a new draft. Other drafts and the current pointer are untouched.
4. If the Trash refuses (for example, a drafts folder on a volume without one, set with
   `UXREVIEW_DRAFTS_DIR`), a second confirmation says why, names the review's captures and
   annotations, says they would be deleted for good and that this can't be undone, and names an
   already created ticket, which is not changed (`HS2-N10RZS`). **Keep Draft** is the default
   button (Return) and keeps the draft as it was. **Delete Immediately** is marked destructive
   and has no key equivalent; it deletes the folder outright (`discard(_:deleteImmediately:)`),
   with the same pointer handling as step 3. UX Review never deletes a draft without this
   second confirmation. If the deletion itself fails, an alert says so; whatever could not be
   removed stays in the drafts folder and is listed (as a broken draft once its review.json is
   gone), so it can be discarded again.

Only a folder directly inside the drafts folder can be discarded. The drafts folder itself,
`current`, hidden names, nested folders, symbolic links, and paths outside are refused
(`outsideDrafts`). A folder that is already gone is `noSuchDraft`. A submitted draft is deleted
rather than trashed (§7.5): its media now lives in Hot Sheet.

`UXREVIEW_TRASH_DIR`, when set, makes discarded drafts move into that folder instead of the
Trash. Tests and `scripts/app-e2e.sh` use it so they never fill the real Trash.

## 7.10 Headless drafts

```
UXReview --drafts [--drafts-dir DIR]
UXReview --discard-draft NAME|PATH [--delete] [--drafts-dir DIR]
```

`--drafts` prints `{"status": "listed", "draftsDirectory", "drafts": [...]}`. The drafts are in
§7.9's order, and each has `name`, `directory`, `title`, `captureCount`, `annotationCount`,
`createdAt`, `modifiedAt`, `isCurrent`, plus `pendingTicket` (and `pendingNoteOnly`,
`pendingToExisting`, `pendingPartlyAttached`, §7.5, §7.8) or
`issue` when they apply. A missing drafts folder lists nothing.

`--discard-draft` discards one draft as in §7.9. The value is a folder name in the drafts
folder, or a path when it contains a `/`. On success it prints `status: "discarded"`,
`draftDirectory`, `trashedTo`, and `wasCurrent`. With `--delete`, it deletes the draft
immediately instead of trying the Trash, which can't be undone, and prints `status: "deleted"`
without `trashedTo`; the same folders are refused. `--delete` without `--discard-draft` is
`invalidArguments`.

| Exit code | `error` | Meaning |
| --- | --- | --- |
| 0 | | Listed, or discarded |
| 2 | `invalidArguments`, `noDraft` | A missing value, or no such draft folder |
| 5 | `listFailed`, `discardFailed` | The drafts folder couldn't be read, or the Trash refused (or, with `--delete`, the deletion failed); the draft is kept |
| 6 | `outsideDrafts` | Not a draft folder directly inside the drafts folder (§7.9); nothing moves |

`scripts/app-e2e.sh` lists four drafts (two set aside with `--new-review`, a broken one, and
clutter that must not be listed), discards an older draft and then the current one into
`UXREVIEW_TRASH_DIR`, checks that the next capture starts a new draft, and checks that paths
outside the drafts folder, links, `current`, and hidden names exit 6 with nothing moved. It then
makes the Trash refuse (exit 5, the draft is kept), deletes that draft with `--delete` (nothing
reaches the trash folder), and checks that `--delete` still refuses a folder outside the drafts
folder.
