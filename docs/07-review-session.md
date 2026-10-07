# 07 — Review session and submitting

Status: implemented on macOS (`HS2-CRJDJ8`), with Submit Review from the editor
(`HS2-6HA14G`) and browsing, reopening, and discarding older drafts (§7.9–7.10, `HS2-WE30PY`).
Opening the ticket in Hot Sheet itself is `HS2-ZEF6XD`.

A review session is the last step of a review: the captures of the current draft
([04-capture.md](04-capture.md) §4.6), annotated in the editor
([06-annotation-editor.md](06-annotation-editor.md)), get a title and summary and are filed as
one Hot Sheet intake ticket ([03-hotsheet-integration.md](03-hotsheet-integration.md)).

## 7.1 Opening

The menu bar menu's **Submit Current Review…** (⌘↩ while the menu is open; disabled with no
draft) opens the **Submit Review** window on the current draft. In the annotation editor,
**Submit Review…** in the tool bar (⌘↩, `HS2-6HA14G`) saves the editor and opens the window on
*that editor's* draft, which need not be the current one (a file dropped on an editor after
Start New Review goes to the editor's draft, docs/04 §4.12.2). **Open Session** in the Draft
Reviews window (§7.9) opens it on any other draft.

- Each draft gets one window. Choosing the item again brings it forward and re-reads the draft.
- With no draft, an alert says "Nothing to submit yet".
- Closing the window saves the title and summary into the draft. Nothing else changes.

## 7.2 The window

| Area | Contents |
| --- | --- |
| Review | **Title** (required) and **Summary** (Markdown, optional). Typing is saved into the draft's `review.json` half a second after it stops. "Give the review a title." shows under a blank title |
| Captures (N) | One row per capture in review order: thumbnail (a movie's first frame, with a play badge), file name, pixel size, duration (videos), annotation count, and source app. A capture with a problem shows it in orange under its details (§7.3). **Annotate** opens the editor on that capture; **Annotate…** in the header opens it on the first. The trash button removes the capture after a confirmation |
| Hot Sheet project | The target project's name and the store it files into, or the problem (§7.6). **Change** lists recent projects and **Choose Folder…** |
| Before submitting | Only when the review has a problem that belongs to no field or capture (an unsupported format, duplicate ids) |
| Footer | **Discard Review…** (§7.9; disabled while submitting), the counts ("3 captures · 4 annotations"), the only remaining problem, or "N things to fix before submitting"; progress while submitting; the failure (§7.5); and **Submit to Hot Sheet** (default button, Return), which reads **Try Again** after a failure |

New captures and editor saves appear while the window is open: it follows the draft-changed
notification the capture pipeline and the editor already post.

**Removing a capture** deletes its file, every annotation on it, and its kept original under
`originals/` with its crop/trim record. An open editor on the draft stays open and drops that
capture, its annotations, and its undo history (docs/06 §6.7); its unsaved edits to other
captures are kept. Numbering of later
captures continues (a removed `capture-2.png` leaves a gap).

After a successful submission the window shows **Filed as HS-…**, the title, what was attached,
and **Copy Slug**, **Show Ticket File** (the ticket's Markdown file in the store, revealed in
Finder), and **Done**.

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

Issues about one capture (a missing file, an annotation problem) show on that capture's row;
the title issue under the title; the Hot Sheet problem under the project.

## 7.4 Session states

`ReviewSession` (UXReviewKit) is a pure state machine; the window and `--submit` drive it.

```
editing ⇄ failed                        edits, removals, refreshes, project changes
editing|failed → submitting(creatingTicket → attachingMedia) → submitted   (terminal)
                                                             ↘ failed
```

- **Submit** starts only from `editing` or `failed`, and only with no issues.
- While submitting, everything else is ignored: a second Submit, edits, removals, draft
  refreshes, and project changes. The fields, the capture list, and the project are disabled,
  so what is shown is what is filed.
- `submitted` accepts nothing more; the window only offers its result actions.
- A refresh from disk keeps the title and summary being typed.

## 7.5 Staging and clean-up

The draft folder **is** the staging area: the captured files, `review.json`, and `originals/`
live in `Drafts/<id>/` from the first capture on. `DraftSubmitter` (UXReviewKit) files it:

1. Saves the title (trimmed) and summary into the draft, under the store's lock.
2. Submits with `ReviewSubmitter` ([03-hotsheet-integration.md](03-hotsheet-integration.md) §3.2):
   validate, write `review.json`, `new`, then one `attach` batch of the media plus `review.json`.
   `originals/` and `submission.json` are never attached.
3. **On success** it deletes the draft folder. When it was the current draft, the `current`
   pointer goes too, so the next capture starts a new review. If the folder can't be deleted,
   the result says so (`draftRemoved: false`); it is no longer current either way.
4. **When the ticket was created but the attach failed**, the draft is kept and
   `Drafts/<id>/submission.json` records the ticket (`storePath`, `ticket {slug, file}`,
   `createdAt`). The failure names the ticket, and **Try Again** attaches to it instead of
   creating a second one. A retry into a different store ignores the record and starts over.
5. **Any other failure** (validation, a missing file, `hotsheet-cli new` failing) keeps the
   draft unchanged apart from the saved title and summary.

Deleting a draft that isn't directly inside the drafts folder (the folder itself, `current`, a
hidden name, a nested folder) is refused.

## 7.6 Target project

The session files into the project chosen in the menu (**Choose Project Folder…**) or in the
window (**Change**). Both save it as `projectDirectory` in the app's defaults
([05-start-and-settings.md](05-start-and-settings.md) §5.3) and add it to `recentProjects`:

- JSON `{"paths": [...]}`, most recent first, at most 5, deduplicated after standardizing
  (`/a/b/` and `/a/b` are one entry).
- **Change** lists the recent projects that still exist, except the current one.
- A successful submission also records its project.
- An unreadable value counts as an empty list.

Changing the project in one place refreshes the menu's Hot Sheet status and every open session
window.

## 7.7 Not yet

- Open the ticket in Hot Sheet (web UI or app) when it is running: `HS2-ZEF6XD`.
- Deleting a draft outright when the Trash refuses it (§7.9): `HS2-N10RZS`.

## 7.8 Headless submit

```
UXReview --submit [--drafts-dir DIR] [--draft NAME] [--project DIR] [--title T] [--summary S]
```

Files the current draft (or the draft named by `--draft`) through the same `ReviewSession`
rules and `DraftSubmitter` as the window, and prints one JSON object. `--title` and `--summary`
replace the draft's own before checking.

- On success: `status: "submitted"`, `slug`, `ticketFile`, `storePath`, `title`, `mediaCount`,
  `annotationCount`, `draftDirectory`, `draftRemoved`.
- On failure: `status: "error"`, `error`, `message`, plus `issues` (messages, for
  `invalidReview`), `createdTicket` (when the ticket exists but the attach failed), and
  `draftDirectory`.

| Exit code | `error` | Meaning |
| --- | --- | --- |
| 0 | | Submitted; the draft is deleted |
| 2 | `invalidArguments`, `noDraft`, `invalidReview` | Bad arguments, no such draft, or the review has issues (§7.3). Nothing is written to Hot Sheet |
| 3 | `hotSheetUnavailable` | No CLI, project, or store |
| 5 | `submitFailed` | Hot Sheet refused; the draft is kept (§7.5) |

`scripts/app-e2e.sh` uses it to file a two-capture session into a throwaway store, including an
attach failure (a wrapper CLI that fails the first `attach`) followed by a retry that reuses the
created ticket.

## 7.9 Draft reviews

The menu bar menu's **Draft Reviews…** opens one **Draft Reviews** window listing every draft
review on disk ([04-capture.md](04-capture.md) §4.6): the current one, the ones set aside with
**Start New Review**, one whose ticket was created but whose media wasn't attached (§7.5), and
one whose folder could not be deleted after submitting (`draftRemoved: false`).

- **Order:** most recently edited first (review.json's modification date, or the folder's when
  review.json is missing). Equal dates sort by folder name in reverse (draft ids start with their date).
- **Each row:** the title, a **Current** badge for the draft new captures go to, the capture and
  annotation counts, and when it was last edited. In orange: "HS-… was created; its media isn't
  attached yet" for a pending submission, or "Can't be opened: review.json is missing." /
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
4. If the Trash refuses (for example, a volume without one), an alert says so and the draft is
   kept as it was. UX Review never deletes a draft outright instead.

Only a folder directly inside the drafts folder can be discarded. The drafts folder itself,
`current`, hidden names, nested folders, symbolic links, and paths outside are refused
(`outsideDrafts`). A folder that is already gone is `noSuchDraft`. A submitted draft is deleted
rather than trashed (§7.5): its media now lives in Hot Sheet.

`UXREVIEW_TRASH_DIR`, when set, makes discarded drafts move into that folder instead of the
Trash. Tests and `scripts/app-e2e.sh` use it so they never fill the real Trash.

## 7.10 Headless drafts

```
UXReview --drafts [--drafts-dir DIR]
UXReview --discard-draft NAME|PATH [--drafts-dir DIR]
```

`--drafts` prints `{"status": "listed", "draftsDirectory", "drafts": [...]}`. The drafts are in
§7.9's order, and each has `name`, `directory`, `title`, `captureCount`, `annotationCount`,
`createdAt`, `modifiedAt`, `isCurrent`, plus `pendingTicket` or `issue` when they apply. A
missing drafts folder lists nothing.

`--discard-draft` discards one draft as in §7.9. The value is a folder name in the drafts
folder, or a path when it contains a `/`. On success it prints `status: "discarded"`,
`draftDirectory`, `trashedTo`, and `wasCurrent`.

| Exit code | `error` | Meaning |
| --- | --- | --- |
| 0 | | Listed, or discarded |
| 2 | `invalidArguments`, `noDraft` | A missing value, or no such draft folder |
| 5 | `listFailed`, `discardFailed` | The drafts folder couldn't be read, or the Trash refused; the draft is kept |
| 6 | `outsideDrafts` | Not a draft folder directly inside the drafts folder (§7.9); nothing moves |

`scripts/app-e2e.sh` lists four drafts (two set aside with `--new-review`, a broken one, and
clutter that must not be listed), discards an older draft and then the current one into
`UXREVIEW_TRASH_DIR`, checks that the next capture starts a new draft, and checks that paths
outside the drafts folder, links, `current`, and hidden names exit 6 with nothing moved.
