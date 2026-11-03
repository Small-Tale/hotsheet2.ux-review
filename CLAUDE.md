<!-- BEGIN hotsheet:claude -->
<!-- hotsheet-instructions-version: 64 -->

@AGENTS.md
<!-- END hotsheet:claude -->

<!-- hotsheet:begin section=ticket-driven-work v=6 -->

## Ticket-Driven Work

Create a Hot Sheet ticket before substantial work described directly by a user, including features, bugs, refactors, and multi-step code changes. Claim it before editing, keep its phase and ETA current, and release the claim whenever work stops. A claim is the live activity signal; `claim_count` records past attempts and must not be used to infer current activity.

- Create follow-up tickets immediately for unfinished steps, open decisions, known gaps, and designed but unbuilt behavior. Include their slugs in the current ticket's completion note.
- Use `FEEDBACK NEEDED` only when the current ticket cannot proceed without a user decision or unavailable external state. Leave it Started, describe the blocker, and release its claim. Status reports, release waits, and sandbox blockers are regular notes, not feedback requests; close tickets you created yourself; give a visual tradeoff captures and `CHOICE` options; check open tickets and the code before asking.
- Before completing, verify the scope, update tests, coverage and docs, scan for placeholders and incomplete behavior, and record the result, verification, and every follow-up.
- When a UI ticket has a problem or design image, capture and attach an after image of the matching component, state, and viewport. Explain any unavailable capture in the completion note.
- Name every addressed ticket slug in its commit message.
- Re-read the whole ticket, including notes added since your last read, before every action on it, and quote the note you are acting on in your result.
- Change only what the ticket asks and preserve neighboring appearance and behavior; propose collateral changes as separate tickets. When the ticket names an attachment, reference art, a prior implementation, or another project, open it before designing.
- Measure before restructuring: record the number that justifies a performance or architecture change, and close the ticket as not worth it when the number is small.
- Record `activity` notes when a meaningful subtask starts and finishes; keep repeated or reversed transitions as separate history entries. Put conclusions, decisions, and recommendations in `regular` Markdown notes, with a short activity entry pointing to them when useful.
- Give each AI-authored activity note a one-line, outcome-oriented `note_summary` in the same update as its Markdown body. Keep the summary plain text and preferably under 80 characters; put implementation and verification detail in the body.
- For multiline CLI Markdown, use `--note-file <path>` (or `--note-file -` for stdin) with real line breaks. Use `--allow-literal-backslash-n` only when literal backslash-n prose is intentional.

<!-- hotsheet:end section=ticket-driven-work -->

<!-- hotsheet:begin section=testing-philosophy v=6 -->

## Testing Philosophy

- Scale testing to risk. Declare a tier in the ticket's preliminary-thoughts note (in the claim note for trivial work); reviewers may raise it. **T0 trivial** (copy, docs, constants, one style token or config value): lint, typecheck, and directly related tests; check visuals only when something visibly changes. **T1 normal** (an ordinary feature or bug fix): the affected tests only; a fix adds one regression test at the most natural layer, and a new feature gets unit and end-to-end coverage. **T2 high-risk** (merge and sync logic, claims and leases, indexes, file formats and parsers, shared components, auth and credentials, data migrations, and any surface the project names as high-risk): everything below, plus the full affected suites.
- Cover each feature with unit tests of its logic and end-to-end tests through the real shipped flow. Mock external dependencies in unit tests; keep browser fixtures faithful to real server shapes, optional fields, and status codes. Exercise each newly composed API surface against a real server as well as mocked client tests.
- Aim to cover every documented feature and reach 100% line and branch coverage. Treat those numbers as a floor: executed lines do not prove behavior or sequences. For stateful modules, enumerate states and transitions, then test repeated, interleaved, out-of-order, reset, and empty-then-refill sequences.
- Test stateful controls in both directions: control to application state and rendered output, and programmatic state changes back to live controls. Verify resets and a further edit. For custom elements, assert live properties and relevant focus/events. Check every part of a selected presentation, including icons, badges, counts, and other derived decoration.
- Exercise child actions through each shipped parent composition. A demo or isolated preview is insufficient evidence that the real parent wires an enabled control; disable unsupported controls explicitly.
- Maintain a feature-by-feature record of unit, end-to-end, and manual coverage as behavior changes. Keep a manual test plan for behavior that cannot be reliably automated.
- Give every code package a working local lint command and configuration when it is added. Keep lint warning-free, fix lint and type errors before finishing, and document justified suppressions.
- When a reviewer corrects a convention, pin it in the same change as a source-level policy test or lint rule named with the ticket slug; prose alone does not hold.
- Verify on the rebuilt instance and reproduce the user's actual steps or command before claiming a fix; never test against the user's running host or a stale build. Isolation, build-once, and flake policy live in the `test-operations` rule when a project installs it.

<!-- hotsheet:end section=testing-philosophy -->

<!-- hotsheet:begin section=requirements-documentation v=4 -->

## Requirements Documentation

Keep human-readable requirements as the source of truth for product behavior. Update them in the same change that adds, removes, or changes behavior. Create and cross-link documents for major new functional areas.

Maintain two concise AI-readable synthesis documents at project-specific, repository-relative locations:

- A codebase map of directory structure, entry points, schema, settings, build and test paths, and where to find important behavior. Update it when structure or contracts change.
- A requirements summary covering each requirements document and marking what is shipped, partial, design-only, or deferred. Update it when requirements or implementation status change.

If either document is absent, create a minimal, truthful version in the same change that first needs it; link it from the project's documentation index and record its relative path in local `hotsheet:specifics` guidance. Setup and refresh install these instructions but do not invent a map or product status. Preserve any existing document locations and prefer targeted updates over rewrites. Source requirements documents and code win if a summary conflicts with them.

Any project with a rendered interface keeps a UI conventions document. It points at the design system's own guidance for philosophy and interaction conventions and records only the project's deviations and project-specific decisions. Cite ticket slugs for decisions in prose and code comments; use one name per concept and keep a glossary once terms accumulate; render diagrams rather than drawing them in text; record performance baselines and audits as dated documents.

<!-- hotsheet:end section=requirements-documentation -->

<!-- hotsheet:begin section=visual-qa v=2 -->

## Visual QA

For any change that can affect a rendered interface, inspect the real application (not a demo route) on the rebuilt instance in a browser at representative wide, medium, and narrow sizes, including the wide-to-narrow-to-wide transition, before completing the ticket. Exercise the affected states and transitions, then review readability, clipping and overflow, alignment, spacing, typography, contrast, icons, responsive behavior, and consistency with adjacent components. Fix defects, rerun affected behavioral checks, and inspect the corrected result. DOM, accessibility, style, and geometry assertions support this review but do not replace looking at the rendered page. A capture that shows a visible defect is never correctness evidence; fix, rerun, and recapture before attaching.

If the ticket has a problem or design image, capture the corresponding after state at the same component and viewport as closely as practical. Attach the image to the ticket and name it in the completion note. Screenshots supplement behavioral tests. If browser capture or attachment is unavailable after practical attempts, describe the exact blocker and leave the visual ticket open for review rather than claiming visual validation.

<!-- hotsheet:end section=visual-qa -->

<!-- hotsheet:begin section=sandbox-recovery v=1 -->

## Launched-session sandbox recovery

When a Hot Sheet-launched session's `hotsheet-cli` command fails while
opening the ticket store with `Operation not permitted (os error 1)`, use
the configured `hotsheet_*` MCP tools for that store operation. A sibling
`<repo>.hs2` store may be outside the command sandbox. Keep the same claim,
actor, note, and completion workflow through MCP; do not infer store corruption
from this error alone.

If a Chromium or WebKit browser gate fails to launch with EPERM or a mach-port
denial, rerun that gate through approved unsandboxed execution. If approval or
a browser is unavailable, record the gate as blocked; do not count it as
passed (HS2-DVZXSD).

<!-- hotsheet:end section=sandbox-recovery -->
