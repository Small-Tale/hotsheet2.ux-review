# 08 — Public feedback (testers and end users)

Status: **design only** (`HS2-C9A8PD`). Nothing here is built yet. Each phase is a follow-up
ticket (§8.8).

## 8.1 Goal

Today UX Review files into a Hot Sheet 2 store through `hotsheet-cli`
([03-hotsheet-integration.md](03-hotsheet-integration.md)). That suits a project's own
developers. Beta testers and end users are a different audience:

- they don't have Hot Sheet 2 or a store;
- they aren't developers;
- they report into a project's **public** tracker, such as GitHub Issues, not its internal one.

Many projects have both: an internal Hot Sheet store for development work, and a public repository
for bug reports and feature requests. Hot Sheet 2 is one of them: its GitHub provider treats
GitHub Issues as an authoritative ticket source (Hot Sheet 2 docs/16).

This feature lets a running app or site tell UX Review two things: that it accepts UX Review
feedback, and where that feedback goes. A tester can then capture, annotate, and report without
knowing how the project tracks its work.

**Feasible?** Yes. It splits into two independent problems:

- **Advertisement** (§8.2–8.4): how UX Review learns about a destination. This is solvable today
  with mechanisms UX Review already has.
- **Transport** (§8.5): how the report and its media get to the destination. Text is easy. Media
  is the hard part, because GitHub has no issue-attachment API for tokens: its `user-attachments`
  upload works only in the browser. Hot Sheet 2 works around this with an assets repository that
  needs Contents write access, and testers won't have that access.

## 8.2 The feedback-target manifest

A project describes where its feedback goes in a small JSON manifest
(`uxreview/feedback-target/v1`, to be added as `spec/feedback-target.schema.json`):

```jsonc
{
  "schema": "uxreview/feedback-target/v1",
  "name": "Hot Sheet 2",                       // shown as "Report to Hot Sheet 2"
  "homepage": "https://github.com/Small-Tale/hotsheet2",
  "visibility": "public",                      // public | private: drives the consent step (§8.6)
  "destinations": [                            // in preference order; UX Review uses the first it supports
    { "kind": "relay", "url": "https://feedback.example.com/ux-review" },
    { "kind": "github-issues", "repository": "Small-Tale/hotsheet2", "labels": ["ux-review"] }
  ],
  "policy": "https://example.com/feedback-privacy"   // optional, linked from the consent step
}
```

- `github-issues` also takes an optional `host` for GitHub Enterprise (default `github.com`).
- More kinds can come later, such as `gitlab-issues` or `email`. UX Review ignores kinds it
  doesn't know, and treats a manifest with no supported destination as absent.
- Manifest URLs must be `https`. Plain `http` is allowed only on a loopback host, which covers a
  locally running web app such as Hot Sheet 2's.

## 8.3 How an app or site advertises it

There are four sources, in order of preference. Each has its own trade-offs, so supporting more
than one is deliberate.

1. **Capture link parameter (explicit).** A site or app shows a "Report a problem" button that opens
   an existing capture link ([04-capture.md](04-capture.md) §4.13) with `feedback=<manifest URL>`.
   - Because the tester clicks it, nothing has to match the capture to an app.
   - It works for websites, web apps, Electron apps, and native apps that can open a URL.
   - The target is stored with the review's launch presets (`DraftLaunch`), like `project=`.
   - Shorthand: `github=<owner>/<repo>` stands for a one-destination manifest.
   - This is the main mechanism. It mostly builds on the shipped link handling.
2. **Running-app registration (passive, while the app runs).** This is the ticket's "while the Hot
   Sheet 2 web app is running" case. The app writes
   `~/Library/Application Support/UX Review/Feedback Targets/<id>.json` (Linux:
   `$XDG_DATA_HOME/ux-review/feedback-targets/`; Windows: `%APPDATA%\UX Review\Feedback Targets\`).
   - The file holds `pid` and `bundleIdentifier` (or `origins` for a web app on a loopback port),
     plus either the manifest or `manifestURL`.
   - The rule is the same as Hot Sheet's `client.json` (`HotSheetWebClient`): a record counts only
     while its process is alive.
   - On macOS, the declared bundle id must also match that pid's running application, so one app
     can't claim another's captures.
3. **Static app declaration.** The app ships a `UXReviewFeedback` entry in its `Info.plist` (a
   manifest dictionary or a `manifestURL`).
   - UX Review finds it through the capture's recorded `bundleIdentifier`
     ([04-capture.md](04-capture.md) §4.5) and reads it with `NSWorkspace`.
   - The equivalents on other platforms are an `X-UXReview-Feedback=` key in Linux `.desktop`
     files and a manifest next to the executable on Windows.
   - The app doesn't need to run any code for this.
4. **Website well-known file.** UX Review reads `<origin>/.well-known/ux-review.json` for the page
   that was captured.
   - This needs the page URL. The bundle schema has `context.url`, but capture doesn't fill it yet:
     reading a browser's front tab takes Apple Events and the Automation permission.
   - It is the lowest priority. The capture link covers most sites more simply.

## 8.4 Matching targets to a review

- A capture link's target applies to the whole review it starts. The reviewer can still change it.
- Otherwise, each capture's context is matched against live registrations, static declarations,
  and well-known files:
  - a registration matches by bundle id, or by `origins` for a browser capture with a known URL;
  - a static declaration matches by bundle id;
  - a well-known file matches by URL origin.
- The review's suggested target is the one matched by most captures, with ties going to the first
  capture.
- A target is only ever a **suggestion** in Submit Review. UX Review never files to a target just
  because it was advertised, the same as a capture link never submits by itself.
- Fetching a remote manifest happens only when Submit Review needs it. UX Review never contacts a
  site just because it was captured.

## 8.5 Transports

| | T0: Hot Sheet CLI (shipped) | T1: GitHub browser handoff | T2: Project relay |
| --- | --- | --- | --- |
| Who it suits | the project's developers | testers with a GitHub account | testers, with or without accounts |
| Needs | `hotsheet-cli` and a store | a browser signed in to GitHub | the project hosts an endpoint |
| Media | attached natively, with regions | the tester drags files into the issue | uploaded by UX Review |
| Credentials in UX Review | none | none | none (or a project-issued token) |

**T1: GitHub browser handoff.** This works with any public repository, and nobody has to register
or host anything.

1. UX Review opens `https://<host>/<repo>/issues/new?title=…&labels=…&body=…`. The body is a
   compact Markdown version of the intake body ([03-hotsheet-integration.md](03-hotsheet-integration.md)
   §3.3, items 2–5). It is kept within a safe URL length, and anything left out is marked as such.
2. UX Review writes the media to a folder and reveals it in Finder:
   - each annotated screenshot with its shapes and `#N` badges burned in, so people can read it
     without UX Review;
   - trimmed and cropped movies;
   - `review.zip`, which holds `review.json` and the original files.
3. The tester drags that folder's files into GitHub's editor, which uploads them through its
   browser-only flow, and submits the issue.

**T2: project relay.** UX Review POSTs `review.json` and the media to the manifest's `url`, as
multipart, with an idempotency key so a retry never files twice. The relay creates the issue
however the project likes and returns `{url, reference}`.

- **Why a relay:** it is the only way to get media in without the tester's own write access.
- **How a relay can store media:** with Hot Sheet 2's approach, a GitHub App that commits files
  to an assets repository and links them from the issue (Hot Sheet 2 docs/16, `HS2-HSA64D`).
- **The relay owns abuse controls:** size caps, rate limits, and whether anonymous reports are
  allowed.
- **Open decision:** who hosts the reference relay. It could be a Hot Sheet 2 component or a
  standalone worker.

**Rejected for now: the GitHub API as the tester** (OAuth device flow). It can create the issue,
but it still can't attach media. UX Review would also need to register and maintain a GitHub
OAuth app. T1 and T2 together cover the same cases.

## 8.6 Trust and privacy

Public feedback is posted somewhere the whole internet can read. Screenshots also catch more than
the app being reported: other windows, notifications, names, and tokens. So:

- **The reviewer always chooses.** Submit Review gains a destination choice: *Hot Sheet project*
  (today's flow), *Report to \<name\>* (an advertised target), or *Save review as file*.
- **The destination's origin is shown, not just its name.** For example "github.com/Small-Tale/hotsheet2"
  or the relay's host. A manifest's `name` is self-declared, and any page can open a capture link.
- **For a `public` target, a review step comes before sending.** It shows:
  - every file exactly as it will be posted;
  - the capture context fields (app, window titles, OS), which can be removed;
  - a plain "This will be public" line;
  - the manifest's `policy` link when there is one.
- **The tester's local details stay local.** Nothing about the tester's machine is sent beyond
  what the review step shows. In particular, UX Review never sends project paths, store paths, or
  usernames.

**Tester mode.** When no `hotsheet-cli` or store is found, that is not an error as long as a
feedback target or *Save review as file* is available. Today Hot Sheet status blocks Submit.

**Distribution prerequisite.** Testers won't build from source, so this depends on Developer ID
signing, notarization, and first-run permission onboarding (`HS2-418QY0`).

## 8.7 Hot Sheet 2's side

The example in `HS2-C9A8PD` is Hot Sheet 2 itself.

- **The product's tracker, not the user's.** Hot Sheet 2's feedback target is the Hot Sheet 2
  product's public tracker, `Small-Tale/hotsheet2` issues. It is not whatever project the user
  happens to have open. A Hot Sheet project could separately mark one of its connections as its
  public feedback destination, but that is a Hot Sheet 2 setting.
- **Advertising.** The web app can advertise through §8.3 source 1 (a *Report a problem with UX
  Review* menu entry) and source 2 (a registration file written next to its existing
  `client.json`, while it runs).
- **A marker on every report.** Each report carries a hidden `<!-- uxreview:bundle v1 … -->`
  marker. When the issue syncs into a Hot Sheet project through the GitHub provider, Hot Sheet
  (or the AI working its queue) can then recognize it as a UX review. It can absorb it like an
  intake ticket ([03-hotsheet-integration.md](03-hotsheet-integration.md) §3.3), splitting it into
  internal tickets with Hot Sheet's existing attachment copy.

## 8.8 Phases

| Phase | Ticket |
| --- | --- |
| Manifest schema and discovery (capture-link parameter, registration, `Info.plist`) | `HS2-AG38J7` |
| Submit Review destination, public-post review step, tester mode | `HS2-VGC3DQ` |
| T1 GitHub browser handoff with burned-in annotations and `review.zip` | `HS2-3FD90F` |
| T2 relay protocol and client transport (hosting decision open) | `HS2-41DFZN` |
| Browser page URL in capture context, plus `.well-known` lookup | `HS2-KBGYWD` |
| Hot Sheet 2 counterpart: advertise, recognize `uxreview` issues | `HS2-NH7D94` |
| Prerequisite: signing, notarization, onboarding | `HS2-418QY0` |

A useful first slice is `HS2-AG38J7` (capture-link parameter only), `HS2-VGC3DQ`, and
`HS2-3FD90F`. With those, Hot Sheet 2 or any site can add a "Report a problem" link that ends in a
prefilled GitHub issue, with no server, account registration, or relay.
