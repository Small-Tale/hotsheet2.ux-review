# 03 — Hot Sheet integration

Status: CLI transport implemented and tested end to end against the real `hotsheet-cli`
(`HS2-3ZSBZ9`), including adding a review to an existing ticket (§3.5, `HS2-E3001H`). The
service transport and native annotation projection are tracked in `HS2-K1XT5V`.

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
4. Runs `hotsheet-cli -C <store> attach --actor-role=human --actor-id=ux-review <SLUG> --batch-id=batch-uxreview-<uuid> --batch-label=UX review capture --purpose=problem_evidence -- <media…> review.json`.
   This attaches everything as **one durable batch**. UX Review picks the batch id, so a resumed
   attach can join the same batch (below).

**`attach` is not atomic.** It writes file by file and prints `Attached …` plus `Durable attachment
id: <ULID> (<stored path>)` for each. When a file fails part-way (missing, unreadable), the files
before it stay attached and it exits non-zero. `HotSheetCLIClient` then reads the stored names it
printed and throws `attachIncomplete(storedNames:…)` instead of `commandFailed`. The submitter
records those files with the batch id (`PartialAttach`), and a retry attaches only the others,
with the same `--batch-id`, so no file is attached twice and the review stays one batch
(`HS2-QNWMKF`, [07-review-session.md](07-review-session.md) §7.5).

`ReviewSubmitter.file(…)` is the same submission with two additions the review session uses
([07-review-session.md](07-review-session.md) §7.5):

- It reports each step as it starts (`creatingTicket`, `attachingMedia`) and returns the
  `CreatedTicket`: the slug plus the ticket file that `new` prints as `Created <SLUG> (<path>)`.
- Given `existingTicket`, it skips `new` and only attaches. If `attach` fails after `new`
  succeeded, it throws `attachFailed(ticket, reason, partial)`, so the caller can retry without
  creating a duplicate ticket. `partial` lists what got attached; given back as `resume`, only
  the rest is attached.

`ReviewSubmitter.add(…)` adds a review to an existing ticket instead (§3.5).

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
   created slugs and complete the intake ticket. This block is the **new-ticket preamble**: the
   reviewer can edit it for one review in Submit Review ([07-review-session.md](07-review-session.md)
   §7.2.3), or clear it. Items 2–5 are always generated.
2. **Reviewer summary**, if the review has one.
3. **Capture context**: app (and bundle id), window, URL, and OS, for whichever are known.
4. **Media**: one line per file, giving kind, pixel size, and duration, plus `, from <App> “<Window>”`
   when the capture recorded its own context ([04-capture.md](04-capture.md) §4.5). A video with
   `hasAudio` ([02-review-bundle.md](02-review-bundle.md) §2.2) adds `, with audio` inside the
   parentheses, and the list is then followed by a note that such videos have a sound track,
   usually the reviewer's spoken narration, to listen to or transcribe, since it can explain the
   annotations or ask for changes they don't show (`HS2-EZN3NG`).
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

## 3.5 Adding to an existing ticket

A review can go into a ticket that already exists instead of a new intake ticket
(`HS2-E3001H`; the window side is [07-review-session.md](07-review-session.md) §7.2.1).

**Finding the ticket.** `TicketReference.parse` reads what the reviewer typed or pasted: a slug
in any case (`hs2-e3001h` → `HS2-E3001H`), a ULID, a ticket file path ending in `<ULID>.md`, or
text around a slug (a `hotsheet-cli ls` line, `HS-ABC123: title`, a link). Inside other text, a
slug counts only when it is uppercase or has a digit, so words like `ux-review` don't. Then
`HotSheetCLIClient.findTicket` runs `hotsheet-cli -C <store> show <ref>` and reads `id`, `slug`,
`title`, and `status` from its YAML front matter. Exit 1 with `no ticket matching` means there is
no such ticket. The ticket file is `<store>/tickets/<last two ULID characters>/<ULID>.md`, reported
only when it exists. A `deleted` or `moved` ticket doesn't take reviews.

**Writing.** `ReviewSubmitter.add(…)` validates and writes `review.json` exactly like §3.2, then:

1. `hotsheet-cli -C <store> attach --actor-role=human --actor-id=ux-review <SLUG> --batch-id=… --batch-label=UX review capture --purpose=problem_evidence -- <media…> review.json`:
   the same single batch as §3.2. An attach that stops part-way throws `attachFailed` with what
   got in, and a retry given it as `resume` attaches only the rest (§3.2).
2. `hotsheet-cli -C <store> edit --actor-role=human --actor-id=ux-review <SLUG> --note-file=<tmp>.md`:
   one note, from a temporary file that is removed afterwards.

**Trashing a left-behind ticket** (`HotSheetClient.moveToTrash`, docs/07 §7.5): `hotsheet-cli -C
<store> edit --actor-role=human --actor-id=ux-review <SLUG> --status=deleted`, only when the
reviewer confirms it in the Submit Review result.

The attach goes first because Hot Sheet renames a file whose name the ticket already has
(`review.json` → `review (2).json`, `capture-1.png` → `capture-1 (2).png`). That is common on a
ticket that came from an earlier review. `attach` prints `Durable attachment id: <ULID> (<stored
path>)` for each file in order, and the note cites each file by its stored name.

If the note fails after the attach, the error is `noteFailed(ticket, attached, reason)`, and the
retry passes the stored names back so that only the note is written. A failed attach leaves
nothing to resume. Note that the CLI's `attach` is not atomic: a later file can fail after an
earlier one was stored, in this flow and in §3.2.

**The note.** `TicketComposer.note(for:storedNames:)` writes:

1. `## UX review: <title>` and one paragraph: this is feedback on this ticket, how many captures
   and annotations there are, that they and `attachment:review.json` (by its stored name) are
   attached in the batch “UX review capture”, that `review.json` is the canonical record, and to
   cite annotation numbers when acting on them. There are no splitting instructions. This is the
   **existing-ticket preamble**, editable for one review like the intake one (docs/07 §7.2.3).
2. The intake body's sections (§3.3 items 2–5) one heading level deeper: `### Reviewer summary`,
   `### Capture context`, `### Media`, `### Annotations` with `#### #N · <intents> ·
   attachment:<stored name>`. A renamed media line adds `; stored under this name, review.json
   calls it <draft name>`.

## 3.6 The project's default AI tool

To scale filed captures for the AI that will read them (`HS2-PT8PM6`,
[07-review-session.md](07-review-session.md) §7.5.1), `HotSheetCLIClient.aiSettings()` runs
`hotsheet-cli -C <store> ai-settings --actor-role=human --actor-id=ux-review get --json`. The
command prints the project's default tool, model, and effort, or the machine-wide fallback when
the project has none, for example `{"tool":"claude","model":"sonnet","effort":"medium"}`
(`AIToolSettings`; `provider` is also accepted for `tool`). The command only reads.

- A non-zero exit throws `commandFailed`. An older CLI without `ai-settings` exits 2 with
  "unrecognized subcommand".
- Output without a tool throws `unexpectedOutput`.
- `MediaScaleTarget.detect` turns either error into the 2048 px fallback. Transports that can't
  tell (the protocol's default) return nil, which gets the same fallback.
