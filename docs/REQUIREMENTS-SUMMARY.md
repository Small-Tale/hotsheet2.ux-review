# Requirements summary

A short status view of each requirements doc. If this summary disagrees with a doc or with the
code, the doc and the code win. Open work is tracked in [README.md](README.md#roadmap).

| Doc | Status |
| --- | --- |
| [00 Vision and principles](00-vision-and-principles.md) | Shipped: the macOS target workflow (capture, annotate, file) works end to end. |
| [01 Architecture](01-architecture.md) | Shipped for macOS. Linux (`HS2-DXWATE`) and Windows (`HS2-DEP1TW`) are deferred. |
| [02 Review bundle](02-review-bundle.md) | Shipped: `uxreview/bundle/v1`. `context.url` is defined but never filled (`HS2-KBGYWD`). |
| [03 Hot Sheet integration](03-hotsheet-integration.md) | Shipped: CLI transport with independent pipe draining (`HS2-P7M4PE`), adding to an existing ticket, native gallery regions. |
| [04 Capture](04-capture.md) | Shipped: screenshots, video, context, drafts, capture links. |
| [05 Start and settings](05-start-and-settings.md) | Shipped. Bundle/menu version follows the declared marketing version (`HS2-DPP2RY`). Fresh capture/video shortcut defaults are ⌥⇧⌘4/5; saved bindings are preserved (`HS2-NJEEAZ`). Permission onboarding is deferred (`HS2-418QY0`). |
| [06 Annotation editor](06-annotation-editor.md) | Shipped. Some refinements are tracked as open tickets in the roadmap. |
| [07 Review session](07-review-session.md) | Shipped: Submit Review, drafts, opening the filed ticket in Hot Sheet, and a selected-project recent-ticket popup (`HS2-19XFD1`). |
| [09 Live UI testing](09-ui-testing.md) | Shipped XCUITest target/runner with verified Settings, import/editor and new/existing submission flows plus inspected screenshots (`HS2-HA9TW3`). Runner failure diagnostics and exit-code handling have isolated shell regressions (`HS2-ZACZ72`). Menu readiness retains bounded lock/focus/geometry diagnostics and dismissed/reopened coverage (`HS2-K0JZP2`). Shared settings/project fixtures use writable temporary plist preferences (`HS2-7HJNAC`); the sidebar AppStorage bridge remains in `HS2-NN2QC0`. Real capture is opt-in and its permitted run remains in `HS2-EP2VQR`; hardware/permission combinations have a manual matrix. |
| [08 Public feedback](08-public-feedback.md) | Design only (`HS2-C9A8PD`). Phases: `HS2-AG38J7`, `HS2-VGC3DQ`, `HS2-3FD90F`, `HS2-41DFZN`, `HS2-KBGYWD`, `HS2-NH7D94`. |

Arrow export (`HS2-5X8QFP`): implemented and CLI-tested; reviewer accepted the result on 2026-10-20. Agent-run gallery/editor visual verification was unavailable. Native projection preserves all six start/end styles, point order, and head-derived default intent; older transports retain the rectangle fallback (docs/03 §3.4).

Submit destination order (`HS2-0166DH`): controls now follow project selection before Review; app build, affected tests, and wide/narrow native previews verified; reviewer accepted the result on 2026-10-20. Interactive browser verification was unavailable to the agent.
