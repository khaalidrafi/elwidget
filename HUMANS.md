# HUMANS.md

A guide for human developers who did not write this code. Written
from a fresh read of the sources on 2026-11-18, per the Owner's
order that agents explain AI-developed codebases.

## What this is

elwidget is a small pure-Elisp package (two source files, about 800
lines total) that lets you define Android home-screen widgets in
Emacs Lisp. A widget is a name plus a `:render` function that
returns a tree of simple nodes; elwidget serializes that tree to a
JSON spec file. The companion Android app "emacshell" (a separate
repo, one APK containing GNU Emacs) watches those files and draws
them as native AppWidgets. Taps flow back as JSON-line events that
Emacs drains and dispatches to per-widget handlers.

The contract with Android is entirely file-based, so the package
also runs unchanged on desktop Emacs: specs are just files nobody
reads. That property is repo law (see AGENTS.md) and the tests
depend on it.

A second file, `elwidget-org.el`, ships five built-in widgets that
render Org data (agenda, tasks, habits, clock, table) by offline
`org-element` parsing of your agenda files.

## Mental model

Two layers, both in this repo:

- `elwidget.el`: the engine. Registry of widget definitions,
  node-tree to JSON rendering, the file protocol (spec files,
  state, events, cursor, bindings), timers, and dispatch.
- `elwidget-org.el`: five concrete widgets built on the engine,
  plus registration. Optional at runtime; the engine does not
  require it.

The lifecycle of a widget:

1. You call `elwidget-define` with a name, `:size [W H]` (home
   screen cells), a `:render` function (node tree or list of
   nodes), and optionally `:on-event (action arg)` and `:state`.
   The definition is stored in the `elwidget-registry` alist;
   redefining a name replaces the old entry.
2. `elwidget-refresh` (or `elwidget-render` for one widget) calls
   each `:render`, converts the tree, and writes
   `specs/NAME.json` atomically (write to `.tmp`, rename). It also
   rewrites `state.json`, the instant-toggle shadow described
   below.
3. The Android app picks up the spec through a FileObserver and
   draws it. The user binds a home-screen widget slot to a spec
   (either through the app's picker or `elwidget-bind`, which
   writes `bindings.json`).
4. Taps append `{"id":N, "spec":"NAME", "action":A, "arg":G}`
   lines to `events.jsonl`. `elwidget-read-events` scans the whole
   file, skips events with an id not greater than the persisted
   cursor, updates the cursor, and calls the widget's `:on-event`.
   A handler returning non-nil (or a "toggle" event with no
   handler) triggers a full `elwidget-refresh`.
5. `elwidget-start` runs that drain on a 15 s timer and the refresh
   on a 15 min timer; `elwidget-sync` does both at once and is
   meant for `focus-in-hook` on a phone, where Emacs is frozen in
   the background most of the time.

The `:state` function supports the "instant-toggle" trick: it
returns an alist `((arg . value) ...)` which `elwidget-write-state`
serializes to `state.json`. The app flips the value the moment the
user taps a check node, so the check mark moves immediately even
while Emacs is frozen; the next Emacs-side render overwrites the
file with authoritative values.

Everything lives under `elwidget-dir` (default
`~/.emacs.d/elwidget/`). The README documents the five files:
`specs/NAME.json`, `bindings.json`, `state.json`, `events.jsonl`,
`cursor.json`.

## Code map

| File / symbol | Role |
|---|---|
| `elwidget.el` | The engine (493 lines). |
| `elwidget-spec` struct + `elwidget-define` (line 88 / 101) | Widget definition and registry (`elwidget-registry` alist, newest first). |
| `elwidget--tree-to-json` (285) | The node dispatcher: `pcase` on the leading keyword, one render function per node type. |
| `elwidget--text-node` / `--check-node` / `--button-node` / `--progress-node` / `--bar-node` / `--gap-node` / `--container-node` | Per-node validation and conversion to JSON-ready alists. |
| `elwidget--opt` (193) | Optional-attribute helper: type-checks one key and emits a one-element alist; keywords become JSON keys by dropping the colon. |
| `elwidget-render` / `elwidget-refresh` (300 / 326) | Render one / all widgets to spec files, then rewrite `state.json`. |
| `elwidget-write-state` / `elwidget--state-value` (332 / 348) | Shadow-state serialization (booleans become 1/0, `skip` stays a string). |
| `elwidget-read-events` (379) | Drain loop: parse each line of `events.jsonl`, skip ids <= cursor, dispatch, save cursor, refresh if any handler asked. |
| `elwidget--dispatch` (414) | Finds the widget by the event's `spec` field, calls `:on-event`; default "toggle" semantics otherwise. |
| `elwidget-start` / `elwidget-stop` / `elwidget-sync` (437 / 450 / 457) | Timer management and the manual full round. |
| `elwidget-bind` (466) | Interactive binding of an Android widget id to a spec name in `bindings.json`. |
| `elwidget--write-json` (156) | Atomic JSON writer (temp file + rename, pretty-printed, UTF-8). |
| `elwidget-org.el` | The five Org widgets (315 lines). |
| `elwidget-org--entries-for-today` (73) | Agenda widget: per-file `org-element` scan for scheduled/deadline timestamps that start today, active only, sorted by time string. |
| `elwidget-org--ensure-id` (137) | Tasks widget: regexp-locate a heading by title, read or create its org-id (saves the file only when creating). |
| `elwidget-org--tasks-on-event` (187) | Tap handler: `org-id-find` the tapped heading, run `org-todo` on it. |
| `elwidget-org--habits-render` (202) | Habits widget: delegates to the loophabits package if present, else renders an install hint. |
| `elwidget-org--clock-render` (217) | Clock widget: reads `org-clock-hd-marker` / `org-clock-start-time` and formats the duration. |
| `elwidget-org--table-rows` (239) | Table widget: hand-rolled line scanner for a `#+NAME:` table (not org-element). |
| `elwidget-org-register-widgets` (289) | Defines all five widgets. |
| `tests/run.el` | Batch runner: loads every `tests/test-*.el`, runs all ERT tests, exits 0/1. |
| `tests/test-elwidget.el`, `tests/test-elwidget-org.el` | 8 + 6 ERT tests; the `with-elwidget-sandbox` macro points `elwidget-dir` at a temp directory. |

## Core algorithms

Node rendering. A node is a plist whose first element is a keyword
naming the type. `elwidget--tree-to-json` dispatches on that
keyword; each per-type function validates positional arguments
(`nth 1` for text/label/state, everything after is the property
plist via `cddr`) and emits an alist with a `type` string.
Container nodes (`:column`, `:row`) map `elwidget--tree-to-json`
over their children recursively. Validation is eager and strict:
wrong types raise errors immediately, which is what the
`elwidget-bad-nodes-error` test pins down. The root of a widget is
implicitly a column: `elwidget-render` wraps a single node in a
list and passes the list as the spec's `children`.

Event draining. `elwidget-read-events` inserts the whole
`events.jsonl` into a temp buffer and walks it line by line. For
each line it parses JSON, and accepts the event only if its
numeric `id` is strictly greater than the in-memory cursor. The
cursor is the maximum id seen and is persisted to `cursor.json`
after the drain (only when something was processed), so restarts
resume where they left off. This is O(file) per drain rather than
O(new events); the file is small (taps) and the app owns pruning,
so no compaction exists in this package.

Agenda scan. `elwidget-org--entries-for-today` opens each agenda
file in a temp buffer, parses with `org-element`, and keeps
headlines whose scheduled-or-deadline timestamp is active and
starts today (comparing year/month/day against `decode-time`).
Entries sort by the formatted "HH:MM" time string, so untimed
entries ("----") sort first, before timed ones. That ordering is
string sort, not chronological for the dash case; it is stable and
tested as-is.

Id minting. `elwidget-org--ensure-id` searches the file for
`^*+ KEYWORD Title` first, then plain `^*+ Title` (both
regexp-quoted, end-of-line anchored), reads the heading's `ID`
property, and only calls `org-id-get-create` (plus `save-buffer`)
when absent. This keeps taps working across restarts because the
check node's `:arg` is the heading's org-id.

## Invariants and gotchas

- Registry order is definition order, newest definition first
  (`cons` onto `assq-delete-all`). Anything sensitive to ordering
  (the picker list, `elwidget-refresh` order) sees redefinitions
  jump to the front.
- `elwidget-undefine` leaves the spec file on disk; the app may
  still show a widget bound to it until pruned. The docstring says
  so explicitly.
- The event drain re-reads the entire `events.jsonl` every poll
  (default every 15 s). If the file grows without bound, each poll
  costs more; the Elisp side never truncates it.
- Cursor persistence only happens when at least one event was
  processed. A drained-but-empty run does not rewrite `cursor.json`
  (harmless, but do not "fix" it without checking the tests).
- The shadow state file is rewritten on every render with values
  from the `:state` functions only. Any state the app wrote in the
  meantime is discarded by design: Emacs is authoritative after a
  sync.
- `elwidget-org--ensure-id` matches headings by title regexp, not
  by position. Two identical titles in one file mean the first
  match wins for both. TODO keyword changes also change the
  heading text, which is why it tries the keyword-prefixed pattern
  first.
- `org-table` rows are parsed with a hand-rolled line scanner, not
  org-element. Separator rows (`|---|`) are skipped by the
  `[-:]` lookahead; anything else org-ish inside tables is not
  understood.
- The habits widget is a soft dependency on the loophabits package
  (same org): missing, it renders an install hint instead of
  failing. The two functions it calls (`loophabits-toggle`,
  `loophabits-elwidget-tree`) are only `declare-function`ed here.
- `elwidget-dir` must live under `user-emacs-directory` for the
  Android FileObserver to see it (per the `defcustom` docstring).
  On desktop that constraint does not apply, but keep it if you
  want the same config to work on a phone.
- Node set changes need a matching layout in the emacshell app
  module first, or a documented degradation. That rule is in
  AGENTS.md and exists because the nodes map onto Android
  RemoteViews, which has no arbitrary layout.

## Developing

Commands (Makefile):

- `make compile` - byte-compile both files with warnings treated
  as errors (`byte-compile-error-on-warn t`).
- `make test` - offline ERT suite: `emacs --batch -l tests/run.el`;
  loads every `tests/test-*.el` and exits nonzero on failure.
- `make clean` - remove `.elc` files.

Requirements: Emacs 27.1+ only; no external packages (json.el and
org are built in). The test suite stubs the Android side by simply
pointing `elwidget-dir` at a temp directory and writing real files,
so it runs on any machine with nothing installed.

Branch law (AGENTS.md): never commit directly to `main`. Work lands
on `ai/main`; use `ai/<topic>--<member-contraction>` branches for
long work. Commit identity and trailers follow the global AGENTS.md
rules.
