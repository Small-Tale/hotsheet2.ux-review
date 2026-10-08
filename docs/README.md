# Hot Sheet 2 UX Review docs

These docs are the requirements source of truth. Update the relevant doc in the same commit as
any behavior change.

| Doc | Covers |
| --- | --- |
| [00-vision-and-principles.md](00-vision-and-principles.md) | What UX Review is for, the target workflow, principles |
| [01-architecture.md](01-architecture.md) | Repo layout, the cross-platform contract, macOS structure, gates |
| [02-review-bundle.md](02-review-bundle.md) | The review bundle format: media, shapes, intents, time ranges, validation |
| [03-hotsheet-integration.md](03-hotsheet-integration.md) | How reviews become Hot Sheet 2 tickets |
| [04-capture.md](04-capture.md) | Screenshot capture: targets, delay, context, draft reviews, permission, headless modes |
| [05-start-and-settings.md](05-start-and-settings.md) | Menu bar menu, global hotkey, Settings window, persistence |
| [06-annotation-editor.md](06-annotation-editor.md) | Annotation editor: shapes, notes, intents, crop, undo/redo, saving, `--annotate` |
| [07-review-session.md](07-review-session.md) | Review session: capture list, title/summary, blocking issues, target project, submit, staging clean-up, `--submit`, draft reviews (list, reopen, discard), `--drafts` / `--discard-draft` |
| [CODEBASE-MAP.md](CODEBASE-MAP.md) | File-by-file orientation |
| [TEST-COVERAGE.md](TEST-COVERAGE.md) | Which tests cover which behavior |

## Roadmap

Repository foundation: `HS2-3ZSBZ9`. The following are tracked as Hot Sheet tickets:

| Area | Ticket |
| --- | --- |
| Menu bar actions + global hotkey | `HS2-DR107C` |
| Separate capture and record-video hotkeys | `HS2-SPFXPW` |
| Open existing images/movies for annotation | `HS2-6A13WZ` |
| Screenshot capture (screen/window/region, delay, context) | `HS2-E89PQR` |
| Video recording | `HS2-W68HWK` |
| Annotation editor (shapes, notes, intents, crop) | `HS2-9H7WZ8` (done) |
| Editor zoom/pan · restore originals · canvas accessibility | `HS2-9Y9DDY` · `HS2-6PV1N3` · `HS2-M8ZFS0` |
| Freehand smoothing | `HS2-5N1GFW` |
| Video trim + annotation time ranges | `HS2-GBM8JN` |
| Review session flow + submit | `HS2-CRJDJ8` |
| Open in Hot Sheet · Submit from the editor (done) · editor drops removed captures (done) | `HS2-ZEF6XD` · `HS2-6HA14G` · `HS2-2QP0GM` |
| Browse, reopen, and discard older drafts | `HS2-WE30PY` (done) |
| Hot Sheet service transport + native annotation projection | `HS2-K1XT5V` |
| App UI end-to-end tests + visual QA | `HS2-HA9TW3` |
| Git remote + CI | `HS2-MWKQEP` |
| Signing, notarization, distribution | `HS2-418QY0` |
| Linux variant | `HS2-DXWATE` |
| Windows variant | `HS2-DEP1TW` |
