# Submit Review intake triage — HS2-A9KVNG

The original `review.json` (`uxreview/bundle/v1`, bundle
`20261020-002937-3E7D6E`) contains three annotations. All three captured images
were inspected. This intake changes no application behavior.

| Annotation | Original evidence | Interpretation and destination |
| --- | --- | --- |
| #1 / `a1` | `attachment:capture-3.png`, rect x 313, y 3160, w 8909, h 1101 | Empty note and intents; highlights the new-ticket destination area. `HS2-6KFE5H` awaits clarification. |
| #2 / `a2` | `attachment:capture-4.png`, rect x 466, y 4142, w 8990, h 1449 | Empty note and intents; highlights the existing-ticket destination area. `HS2-9H7BX2` awaits clarification. |
| #3 / `a3` | `attachment:capture-2.png`, insertion point x 762, y 2209 | Explicit `insert`, `move`: relocate Submit as and ticket number after project selection, before Review. `HS2-0166DH` is actionable. |

Coordinates use the bundle's 0–10000 space. These are still images with no time
ranges. The intake's presentation calls #1 and #2 comments, while the canonical
bundle stores empty intent lists; neither supplies a requested change.

Each child preserves its corresponding original image and a byte-identical copy
of `review.json`, attached as problem evidence. Each cites its annotation, region,
intents and absence of a time range. The two clarification tickets remain Started
with a feedback-needed note, an explicit blocked reason and no live claim.

Verification: compare source and copied attachment SHA-256 digests, inspect each
child's category and state, and confirm every canonical annotation maps exactly
once. The actionable UI ticket requires behavior tests and matching after
screenshots when implemented; intake screenshots are original problem evidence.
