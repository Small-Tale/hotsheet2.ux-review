# 03 — Hot Sheet integration

Status: CLI transport implemented and tested end to end against the real `hotsheet-cli`
(`HS2-3ZSBZ9`). The service transport and native annotation projection are tracked in
`HS2-K1XT5V`.

## 3.1 Discovery

**CLI.** The client looks for `hotsheet-cli` in this order:

1. `$HOTSHEET_CLI`
2. each `$PATH` entry
3. `/opt/homebrew/bin`
4. `/usr/local/bin`
5. `~/.cargo/bin`
6. `~/.local/bin`

The extra locations matter because GUI apps launched from Finder get a minimal `PATH`.

**Store.** This follows Hot Sheet 2's own order:

1. `$HOTSHEET_STORE` (it must be a real store)
2. walking up from the project directory, the first directory that either is a store
   (`hotsheet-store.json`) or has a `.hotsheet2/store` pointer file to one
3. a sibling `<dir>.hs2` store next to any directory on that walk

`HotSheetStatus.detect` turns these lookups into a single ready/problem state for the UI and for
`UXReview --status`.

## 3.2 Submission (CLI transport)

`ReviewSubmitter.submit(bundle, mediaDirectory:)` does the following:

1. Validates the bundle and checks that every media file exists. Nothing is written if either
   check fails.
2. Writes `review.json` into the media directory.
3. Runs `hotsheet-cli -C <store> new --actor-role=human --actor-id=ux-review --title=… --category=task --details=… --tag=ux-review`,
   then parses `Created <SLUG>` from its output.
4. Runs `hotsheet-cli -C <store> attach --actor-role=human --actor-id=ux-review <SLUG> --batch-label=UX review capture --purpose=problem_evidence -- <media…> review.json`.
   This attaches everything as **one durable batch**.

`ReviewSubmitter.file(…)` is the same submission with two additions the review session uses
([07-review-session.md](07-review-session.md) §7.5):

- It reports each step as it starts (`creatingTicket`, `attachingMedia`) and returns the
  `CreatedTicket`: the slug plus the ticket file that `new` prints as `Created <SLUG> (<path>)`.
- Given `existingTicket`, it skips `new` and only attaches. If `attach` fails after `new`
  succeeded, it throws `attachFailed(ticket, reason)`, so the caller can retry without creating
  a duplicate ticket.

Arguments are always passed bound with `=`, and file lists follow `--`, so values that begin
with `-` are never parsed as flags. The client removes `HOTSHEET_ACTOR_ROLE` and
`HOTSHEET_ACTOR_ID` from the child environment, so a review never inherits an AI session's
identity.

The CLI cannot set Hot Sheet attachment annotations, so this transport does not show regions in
Hot Sheet's gallery. The regions are fully described in the ticket body and in `review.json`.

## 3.3 Intake ticket body

The ticket is titled `UX review: <title>`, has category `task`, and carries the tag `ux-review`.
`TicketComposer` builds the Markdown body:

1. **Instructions for the AI processing this ticket**. Don't implement the ticket directly. Read
   every annotation, with `attachment:review.json` as the canonical record. Create one ticket per
   distinct actionable change, grouping only true duplicates and never dropping an annotation.
   Cite annotation numbers, intents, regions, and time ranges. Reference and re-attach the same
   media by `attachment:<filename>`. Map intents to categories: `bug` → bug; `insert` → feature;
   `comment`/`change`/`remove`/`move` → issue; `question` → investigation. Finally, note the
   created slugs and complete the intake ticket.
2. **Reviewer summary**, if the review has one.
3. **Capture context**: app (and bundle id), window, URL, and OS, for whichever are known.
4. **Media**: one line per file, giving kind, pixel size, and duration, plus `, from <App> “<Window>”`
   when the capture recorded its own context ([04-capture.md](04-capture.md) §4.5).
5. **Annotations**: one section per annotation, `### #N · <intents> · attachment:<file>`. Each
   gives the shape, the projected region in 0–10000 units, the time range as `m:ss.mmm`, and the
   note (or `_No note._`).

## 3.4 Hot Sheet annotation projection

`TicketComposer.compose(...).hotSheetAnnotations` maps each media id to a list of Hot Sheet
`MediaAnnotation` values:

- `{id, x, y, width, height, start_ms, end_ms, text}`, with `text` set to
  `#N [intents] note`.
- The service transport (`HS2-K1XT5V`) will `PUT` these lists so Hot Sheet's gallery shows the
  regions.
