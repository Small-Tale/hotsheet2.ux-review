# 07 — Review session and submitting

Status: implemented on macOS (`HS2-CRJDJ8`). Opening the ticket in Hot Sheet itself is
`HS2-ZEF6XD`; a Submit button in the editor is `HS2-6HA14G`; browsing and discarding older
drafts is `HS2-WE30PY`.

A review session is the last step of a review: the captures of the current draft
([04-capture.md](04-capture.md) §4.6), annotated in the editor
([06-annotation-editor.md](06-annotation-editor.md)), get a title and summary and are filed as
one Hot Sheet intake ticket ([03-hotsheet-integration.md](03-hotsheet-integration.md)).

## 7.1 Opening

The menu bar menu's **Submit Current Review…** (⌘↩ while the menu is open; disabled with no
draft) opens the **Submit Review** window on the current draft.

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
| Footer | The counts ("3 captures · 4 annotations"), the only remaining problem, or "N things to fix before submitting"; progress while submitting; the failure (§7.5); and **Submit to Hot Sheet** (default button, Return), which reads **Try Again** after a failure |

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
- A Submit Review button in the editor: `HS2-6HA14G`.
- Reopen, submit, or discard older drafts: `HS2-WE30PY`.

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
